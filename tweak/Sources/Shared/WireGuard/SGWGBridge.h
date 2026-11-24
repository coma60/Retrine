// C ABI of the Go engine in WireGuard/bridge.go (built into libsgwg.a).
// Every returned string is malloc'ed by Go and must be freed with SGWGFree.
#ifndef SGWG_BRIDGE_H
#define SGWG_BRIDGE_H
#include <stdint.h>

// Shared with cgo: readiness is structural, never a verdict about one destination.
enum SGWGEngineEvent {
    SGWGEngineStopped = 0,
    SGWGEngineAvailable = 1,
    SGWGEngineUnavailable = 2,
    SGWGEngineDestinationFailed = 3,
};

#ifdef __cplusplus
extern "C" {
#endif

enum SGWGStartResult {
    SGWGStarted, SGWGStartNetworkUnavailable, SGWGStartRefused
};
char *SGWGInspect(char *text);
// Consumes a duplicate of the reserved, bound socket on every outcome.
enum SGWGStartResult SGWGStart(char *text, char *user, char *pass, int listenerFD);
void SGWGStop(void);
char *SGWGStatus(void);
void SGWGSetStateCallback(uintptr_t callback, uintptr_t admitted);
int SGWGRebind(void);
char *SGWGLookup(char *host);
char *SGWGResolve(char *host);
char *SGWGRedact(char *text);
void SGWGFree(char *p);

#ifdef __cplusplus
}
#endif

#endif
