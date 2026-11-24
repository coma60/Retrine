package main

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
	"time"
)

type fixtureStack struct {
	lookup func(context.Context) ([]string, error)
	dial   func(context.Context, string) (net.Conn, error)
}

type heldBind struct {
	rebindDevice
	once             sync.Once
	entered, release chan struct{}
	active, peak     atomic.Int32
}

func (d *heldBind) BindUpdate() error {
	active := d.active.Add(1)
	defer d.active.Add(-1)
	if active > d.peak.Load() {
		d.peak.Store(active)
	}
	d.once.Do(func() { close(d.entered); <-d.release })
	return d.rebindDevice.BindUpdate()
}

func TestConcurrentResumeReconcilesOnce(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("listener setup")
	}
	device := &heldBind{entered: make(chan struct{}), release: make(chan struct{})}
	e := &Engine{dev: device, listener: listener, port: listener.Addr().(*net.TCPAddr).Port}
	defer e.Close()
	e.Rebind()
	<-device.entered
	e.Rebind()
	e.mu.Lock()
	done := e.repairDone
	e.mu.Unlock()
	close(device.release)
	<-done
	if e.bindUpdates.Load() != 1 {
		t.Fatal("duplicate UDP update for in-flight reconciliation")
	}
}

func TestRebindRequestsDoNotWaitForRepair(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("listener setup")
	}
	device := &heldBind{entered: make(chan struct{}), release: make(chan struct{})}
	e := &Engine{dev: device, listener: listener, port: listener.Addr().(*net.TCPAddr).Port}
	release := sync.OnceFunc(func() { close(device.release) })
	defer func() { release(); e.Close() }()
	requested := make(chan struct{})
	go func() {
		e.Rebind()
		<-device.entered
		e.listenerFailed(listener) // accept loop discovers listener loss during BindUpdate
		e.Rebind()
		close(requested)
	}()
	select {
	case <-requested:
	case <-time.After(time.Second):
		t.Fatal("control request blocked behind repair")
	}
	// Stop while one repair is held and another request is pending.
	stopped := make(chan struct{})
	go func() { e.Close(); close(stopped) }()
	// The original listener closes before the worker is joined.
	c, err := listener.Accept()
	if err == nil {
		c.Close()
		t.Fatal("listener still accepting")
	}
	release()
	<-stopped
	if device.peak.Load() != 1 || e.relistens.Load() != 0 {
		t.Fatal("duplicate or resurrected listener repair")
	}
}

func TestListenerPressureCanRecoverAfterExhaustion(t *testing.T) {
	for _, fault := range []error{syscall.ENOMEM, syscall.ENOBUFS, syscall.ECONNABORTED, syscall.EINTR} {
		t.Run(fault.Error(), func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				l, err := net.Listen("tcp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal("listener setup")
				}
				anchor, err := l.(*net.TCPListener).File()
				if err != nil {
					t.Fatal("listener reservation")
				}
				var pressure atomic.Bool
				pressure.Store(true)
				var attempts atomic.Int32
				available := make(chan struct{}, 1)
				e := &Engine{dev: &rebindDevice{}, listener: l, anchor: anchor,
					rearm: func() (net.Listener, error) {
						attempts.Add(1)
						if pressure.Load() {
							return nil, &net.OpError{Op: "accept", Err: fault}
						}
						return listenReserved(anchor)
					}, stateChanged: func(s int) {
						if s == engineAvailable {
							available <- struct{}{}
						}
					},
				}
				defer e.Close()
				e.listenerFailed(l)
				time.Sleep(time.Minute)
				e.mu.Lock()
				parked := e.repairDone == nil
				e.mu.Unlock()
				if !parked || attempts.Load() < 2 || len(available) != 0 {
					t.Fatal("listener did not retry and park unavailable")
				}
				pressure.Store(false)
				e.Rebind()
				select {
				case <-available:
				case <-time.After(time.Second):
					t.Fatal("listener did not recover on a later path update")
				}
			})
		})
	}
}

func TestPathChangeAfterBindDuringListenerRetry(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("listener setup")
	}
	anchor, err := l.(*net.TCPListener).File()
	if err != nil {
		t.Fatal("listener reservation")
	}
	device := &heldBind{entered: make(chan struct{}), release: make(chan struct{})}
	listenerRetry, resume := make(chan struct{}), make(chan struct{})
	var attempts atomic.Int32
	e := &Engine{dev: device, listener: l, anchor: anchor, rearm: func() (net.Listener, error) {
		if attempts.Add(1) == 1 {
			close(listenerRetry)
			<-resume
			return nil, syscall.EMFILE
		}
		return listenReserved(anchor)
	}}
	defer e.Close()
	e.Rebind()
	<-device.entered
	e.listenerFailed(l)
	close(device.release)
	<-listenerRetry // first UDP update completed; listener is still unavailable
	e.Rebind()
	e.mu.Lock()
	done := e.repairDone
	e.mu.Unlock()
	close(resume)
	<-done
	if e.bindUpdates.Load() != 2 {
		t.Fatal("path change lost during listener retry")
	}
}

func (s fixtureStack) LookupContextHost(ctx context.Context, _ string) ([]string, error) {
	return s.lookup(ctx)
}
func (s fixtureStack) DialContext(ctx context.Context, _, dst string) (net.Conn, error) {
	return s.dial(ctx, dst)
}

func TestDialSharesBudgetAfterDNS(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		const budget = 15 * time.Second
		start := time.Now()
		e := Engine{dialTimeout: budget, stack: fixtureStack{
			lookup: func(context.Context) ([]string, error) {
				time.Sleep(5 * time.Second)
				return []string{"2606:4700:4700::1111", "1.1.1.1"}, nil
			},
			dial: func(ctx context.Context, dst string) (net.Conn, error) {
				deadline, _ := ctx.Deadline()
				if dst == "[2606:4700:4700::1111]:443" {
					<-ctx.Done()
					return nil, ctx.Err()
				}
				if dst != "1.1.1.1:443" || time.Until(deadline) != 5*time.Second || deadline.Sub(start) != budget {
					return nil, errors.New("working candidate lost its share of parent deadline")
				}
				a, b := net.Pipe()
				b.Close()
				return a, nil
			},
		}}
		c, err := e.dial("fixture.invalid", 443)
		if err != nil {
			t.Fatal("second candidate did not connect within shared budget")
		}
		c.Close()
	})
}

func TestMixedAnswerHasNoEgress(t *testing.T) {
	e := Engine{dialTimeout: time.Second, stack: fixtureStack{
		lookup: func(context.Context) ([]string, error) { return []string{"1.1.1.1", "::1"}, nil },
		dial:   func(context.Context, string) (net.Conn, error) { t.Fatal("mixed answer dialed"); return nil, nil },
	}}
	if _, err := e.dial("fixture.invalid", 443); err == nil {
		t.Fatal("accepted mixed answer")
	}
}

// Independent streams on each side, with TCP-like EOF in just one direction.
type halfConn struct {
	net.Conn
	reader net.Conn
}

func (c halfConn) Read(p []byte) (int, error) { return c.reader.Read(p) }
func (c halfConn) CloseWrite() error          { return c.Conn.Close() }
func (c halfConn) Close() error               { c.reader.Close(); return c.Conn.Close() }

func halfPair() (halfConn, halfConn) {
	a, b := net.Pipe()
	c, d := net.Pipe()
	return halfConn{a, c}, halfConn{d, b}
}

func TestPipeDrainsEitherDirection(t *testing.T) {
	for _, reverse := range []bool{false, true} {
		for _, mode := range []string{"silent", "blocked writer", "payload before FIN", "progress", "progress with upload open"} {
			t.Run(mode, func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					client, local := halfPair()
					remote, peer := halfPair()
					defer client.Close()
					defer peer.Close()
					e := Engine{clients: map[net.Conn]struct{}{}}
					done := make(chan struct{})
					go func() { e.pipe(local, bufio.NewReader(local), remote); local.Close(); close(done) }()
					if reverse {
						client, peer = peer, client
					}
					if mode == "payload before FIN" {
						if _, err := client.Write([]byte{1}); err != nil {
							t.Fatal("payload not consumed")
						}
					}
					if mode != "progress with upload open" {
						client.CloseWrite()
					}
					var b [1]byte
					if mode != "payload before FIN" && mode != "progress with upload open" {
						if _, err := peer.Read(b[:]); err != io.EOF {
							t.Fatal("FIN not forwarded")
						}
					}
					switch mode {
					case "progress", "progress with upload open":
						for i := 0; i < 4; i++ {
							time.Sleep(12 * time.Second)
							go peer.Write([]byte{byte(i)})
							if _, err := io.ReadFull(client, b[:]); err != nil || b[0] != byte(i) {
								t.Fatal("progressing stream truncated")
							}
						}
						peer.CloseWrite()
						if mode == "progress with upload open" {
							client.CloseWrite()
						}
					case "blocked writer":
						peer.Write([]byte{1}) // copied from peer, client never reads it
					}
					select {
					case <-done:
					case <-time.After(31 * time.Second):
						t.Fatal("stalled copies not joined")
					}
				})
			})
		}
	}
}
