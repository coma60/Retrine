#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <simd/simd.h>
#import "Core/SGCore.h"
#import "SGRFluid.h"
#import "SGRFluidGPU.h"
#import "SGRTokens.h"
#import "SGRBridges.h"

// How long a new cover takes to run in. Under Reduce Motion it fades over SGRCrossfade instead.
static const CFTimeInterval kRunIn = 1.4;
static const double kDrawFramesPerSecond = 30;

// In the shader's order and layout (a float4 first, so both sides pad the same way).
typedef struct {
    simd_float4 visible;   // the visible rect as shares of the layer: x, y, width, height
    simd_float4 seed;      // the phases of this layer's own bend (kBend), picked once when it is made
    simd_float2 aspect;    // the visible rect's sides as shares of its longer side
    float time;            // the flow's clock, in seconds at the standard speed
    float warp;            // the Warp setting as a factor
    float progress;        // how far the new cover has run in, 0 to 1
    float flows;           // 1 while it runs in flowing, 0 while it fades
    float grain;           // the noise's spread, peak to peak, in eight-bit steps (grainSteps)
    float playing;         // 0 held still (the picture shown a quarter larger, flat), 1 flowing (bent and breathing)
} Uniforms;

// How long the picture takes to go from held to flowing and back (eased in and out), as the Music app's does.
static const CFTimeInterval kSettle = 0.8;

// The noise's spread at the standard Grain, the dither against banding the shader always had (half a step either
// way), and at the setting's most, a grain that shows over the blurred cover. Between none and the standard it
// scales to the setting, and on from there to the most.
static const float kGrainStandardSteps = 1, kGrainMostSteps = 24;

static float grainSteps(float factor) {
    SGRFluidLimits limits = SGRFluidLimitsOf(SGRFluidGrain);
    float most = (float)limits.most / (float)limits.standard;
    if (factor <= 1) return factor * kGrainStandardSteps;
    return kGrainStandardSteps + (MIN(factor, most) - 1) / (most - 1) * (kGrainMostSteps - kGrainStandardSteps);
}

// The Music app's backdrop, worked out from what its player draws: three copies of the blurred cover, the turns and
// places of SGRFluid.m's kCopy (unit: half the visible rect's longer side, y down; clockwise), each opaque and laid over
// the last with a feathered edge where the Music app blurs the whole; then the picture shown through a bend. Flowing,
// the bend breathes between none and its full reach once in 2 pi * 3.5 s; held still, the picture is flat and a
// quarter larger. The bend is Retrine's own: a push out from the middle and two slow waves, at phases picked per layer.
static NSString *const kShader = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"#define TAU 6.2831853\n"
"#define FEATHER 0.44\n"
"struct U { float4 visible; float4 seed; float2 aspect; float time; float warp; float progress; float flows; float grain; float playing; };\n"
"struct V { float4 position [[position]]; float2 uv; };\n"
// One triangle past the corners covers the drawable; uv runs 0 to 1 down and across it.
"vertex V fluidVertex(uint id [[vertex_id]]) {\n"
"    float2 p = float2((id << 1) & 2, id & 2);\n"
"    V v;\n"
"    v.position = float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
"    v.uv = float2(p.x, 1.0 - p.y);\n"
"    return v;\n"
"}\n"
// A cubic B-spline from four bilinear reads: no grid of texels shows on a 128 px picture blown up to the screen.
"static float4 smoothRead(texture2d<float> t, sampler s, float2 uv) {\n"
"    float2 size = float2(t.get_width(), t.get_height());\n"
"    float2 st = uv * size - 0.5;\n"
"    float2 i = floor(st), f = st - i, f2 = f * f, f3 = f2 * f;\n"
"    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;\n"
"    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;\n"
"    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;\n"
"    float2 w3 = f3 / 6.0;\n"
"    float2 g0 = w0 + w1, g1 = w2 + w3;\n"
"    float2 h0 = (i - 0.5 + w1 / g0) / size, h1 = (i + 1.5 + w3 / g1) / size;\n"
"    return g0.y * (g0.x * t.sample(s, float2(h0.x, h0.y)) + g1.x * t.sample(s, float2(h1.x, h0.y)))\n"
"         + g1.y * (g0.x * t.sample(s, float2(h0.x, h1.y)) + g1.x * t.sample(s, float2(h1.x, h1.y)));\n"
"}\n"
"static float2 turned(float2 v, float a) {\n"
"    float c = cos(a), s = sin(a);\n"
"    return float2(c * v.x - s * v.y, s * v.x + c * v.y);\n"
"}\n"
// How far the bend carries a point of the screen at its full reach.
"static float2 bendAt(float2 q, float4 seed) {\n"
"    return (q - 0.5) * 0.25\n"
"         + 0.07 * float2(sin(q.y * 2.3 + seed.x), sin(q.x * 2.1 + seed.y))\n"
"         + 0.04 * float2(sin((q.x + q.y) * 3.7 + seed.z), sin((q.x - q.y) * 3.3 + seed.w));\n"
"}\n"
// One copy: its color and how much of it covers the point c (1 inside, fading to 0 over FEATHER of its half side).
"static float4 copyAt(texture2d<float> t, sampler s, float2 c, float2 center, float angle, float reach) {\n"
"    float2 l = turned(c - center, -angle);\n"
"    float edge = max(abs(l.x), abs(l.y)) / reach;\n"
"    float3 rgb = smoothRead(t, s, l / (2.0 * reach) + 0.5).rgb;\n"
"    return float4(rgb, 1.0 - smoothstep(1.0 - FEATHER, 1.0, edge));\n"
"}\n"
"static float3 backdrop(texture2d<float> big, texture2d<float> small, sampler s, float2 c, constant U &u) {\n"
"    float a0 = TAU * u.time / 120.0, a1 = TAU * u.time / 70.0, a2 = TAU * u.time / 90.0;\n"
"    float3 rgb = smoothRead(big, s, turned(c, -a0) / 2.8 + 0.5).rgb;\n"
"    float4 one = copyAt(small, s, c, float2(-0.25, -0.15) * u.warp, a1, 0.7);\n"
"    rgb = mix(rgb, one.rgb, one.a * min(u.warp, 1.0));\n"
"    float4 two = copyAt(small, s, c, turned(float2(0.7, -0.7) * u.warp, a0), a2, 0.7);\n"
"    return mix(rgb, two.rgb, two.a * min(u.warp, 1.0));\n"
"}\n"
"fragment float4 fluidFragment(V in [[stage_in]], constant U &u [[buffer(0)]],\n"
"                              texture2d<float> fromBig [[texture(0)]], texture2d<float> fromSmall [[texture(1)]],\n"
"                              texture2d<float> toBig [[texture(2)]], texture2d<float> toSmall [[texture(3)]],\n"
"                              sampler s [[sampler(0)]]) {\n"
"    float2 p = (in.uv - u.visible.xy) / u.visible.zw;\n"
// Where the point reads the picture: flat and a quarter larger held, bent by the breath flowing (the bend's inverse,
// found in three steps).
"    float breath = 0.5 + 0.5 * sin(u.time / 3.5);\n"
"    float2 bent = p;\n"
"    for (int k = 0; k < 3; k++) bent = p - breath * u.warp * bendAt(bent, u.seed);\n"
"    float2 q = mix((p - 0.5) / 1.25 + 0.5, bent, u.playing);\n"
"    float2 c = (q - 0.5) * u.aspect * 2.0;\n"
"    float3 b = backdrop(toBig, toSmall, s, c, u);\n"
// The new cover reaches first where a slow wave is low.
"    if (u.progress < 1.0) {\n"
"        float2 r = (p - 0.5) * u.aspect;\n"
"        float wave = 0.5 + 0.5 * sin(r.x * 3.1 + r.y * 2.3 + sin(r.y * 4.0 + u.time * 0.5));\n"
"        float m = u.flows > 0.5 ? smoothstep(0.0, 1.0, saturate(u.progress * 1.5 - wave * 0.5)) : u.progress;\n"
"        b = mix(backdrop(fromBig, fromSmall, s, c, u), b, m);\n"
"    }\n"
// Noise against the banding a slow gradient shows in eight bits, spread over u.grain steps; past the standard's half
// step up it only darkens, so the brightness ceiling holds as it did.
"    uint2 ip = uint2(in.position.xy);\n"
"    uint h = ip.x * 1973u + ip.y * 9277u;\n"
"    h = (h ^ (h >> 13)) * 1274126177u;\n"
"    h ^= h >> 16;\n"
"    float noise = float(h & 0xffffu) / 65535.0 - 0.5;\n"
"    return float4(b + min(noise * u.grain, 0.5) / 255.0, 1.0);\n"
"}\n";

BOOL SGRFluidGPUAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ available = MTLCreateSystemDefaultDevice() != nil; });
    return available;
}

// What every layer shares, made once on the main thread; the shader compiles off it.
static id<MTLDevice> sDevice;
static id<MTLCommandQueue> sQueue;
static id<MTLRenderPipelineState> sPipeline;
static id<MTLSamplerState> sSampler;
static BOOL sFailed;
static NSMutableArray<void (^)(void)> *sWaiting;

static void finish(id<MTLRenderPipelineState> pipeline, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<void (^)(void)> *waiting = sWaiting;
        sWaiting = nil;
        if (!pipeline) {
            sFailed = YES;
            SGLog(@"redesign kit: the Smooth fluid shader failed, Light stays: %@", error.localizedDescription ?: @"no reason");
            return;
        }
        sPipeline = pipeline;
        for (void (^ready)(void) in waiting) ready();
    });
}

// Runs the block on the main thread once the pipeline exists: at once if it does, never if it failed.
static void whenReady(void (^ready)(void)) {
    if (sPipeline) { ready(); return; }
    if (sFailed) return;
    if (sWaiting) { [sWaiting addObject:ready]; return; }
    sWaiting = [NSMutableArray arrayWithObject:ready];
    sDevice = MTLCreateSystemDefaultDevice();
    sQueue = [sDevice newCommandQueue];
    if (!sDevice || !sQueue) { finish(nil, nil); return; }
    MTLSamplerDescriptor *sampling = [MTLSamplerDescriptor new];
    sampling.minFilter = MTLSamplerMinMagFilterLinear;
    sampling.magFilter = MTLSamplerMinMagFilterLinear;
    // Mirrored, so a bend that reads past the cover's edge finds more of the cover rather than a smear.
    sampling.sAddressMode = MTLSamplerAddressModeMirrorRepeat;
    sampling.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
    sSampler = [sDevice newSamplerStateWithDescriptor:sampling];
    id<MTLDevice> device = sDevice;
    [device newLibraryWithSource:kShader options:nil completionHandler:^(id<MTLLibrary> library, NSError *error) {
        if (!library) { finish(nil, error); return; }
        MTLRenderPipelineDescriptor *described = [MTLRenderPipelineDescriptor new];
        described.vertexFunction = [library newFunctionWithName:@"fluidVertex"];
        described.fragmentFunction = [library newFunctionWithName:@"fluidFragment"];
        described.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        [device newRenderPipelineStateWithDescriptor:described completionHandler:^(id<MTLRenderPipelineState> pipeline, NSError *failure) {
            finish(pipeline, failure);
        }];
    }];
}

// The picture as a texture, in sRGB's numbers as they are (the shader mixes them the way Core Animation's
// crossfade does).
static id<MTLTexture> textureOf(id picture) {
    CGImageRef image = (__bridge CGImageRef)picture;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (!sDevice || width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) return nil;
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), image);
    MTLTextureDescriptor *described = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:width height:height mipmapped:NO];
    described.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [sDevice newTextureWithDescriptor:described];
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
                 withBytes:CGBitmapContextGetData(bitmap) bytesPerRow:width * 4];
    CGContextRelease(bitmap);
    return texture;
}

@interface SGRFluidGPULayer ()
- (void)tick:(CADisplayLink *)link;
@end

// The display link's target, so the link (which retains it) does not keep the layer.
@interface SGRFluidTicker : NSObject
@property (nonatomic, weak) SGRFluidGPULayer *layer;
@end

@implementation SGRFluidTicker
- (void)tick:(CADisplayLink *)link {
    [self.layer tick:link];
}
@end

@implementation SGRFluidGPULayer {
    id _fromPicture, _toPicture;   // CGImages
    id _fromSmall, _toSmall;       // the same blurred for the smaller copies
    id<MTLTexture> _from, _to, _fromLess, _toLess;   // made from them when first drawn
    simd_float4 _seed;
    float _settle;                 // 0 held still, 1 flowing (kSettle, eased when drawn)
    float _progress;               // 1 when nothing runs in
    BOOL _flows;
    CFTimeInterval _length, _last;
    double _time;
    CADisplayLink *_link;
    BOOL _ready, _dirty, _drewOnce, _firstPending;
    BOOL _resigning;
    int _misses;   // ticks in a row whose frame could not be drawn, once nothing else keeps the link
    int _firstFailures;   // first frames the GPU failed; after three, Light stays and none is tried again
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _rate = 1;
    _warp = 1;
    _grain = 1;
    _progress = 1;
    for (int i = 0; i < 4; i++) _seed[i] = (float)(arc4random_uniform(62832) / 10000.0);
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.opaque = YES;
    self.contentsScale = 1;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    self.colorspace = space;
    CGColorSpaceRelease(space);
    NSNull *off = NSNull.null;
    self.actions = @{@"bounds": off, @"position": off, @"frame": off, @"contents": off, @"hidden": off};
    __weak SGRFluidGPULayer *weakSelf = self;
    whenReady(^{
        SGRFluidGPULayer *layer = weakSelf;
        if (!layer) return;
        layer.device = sDevice;
        layer->_ready = YES;
        [layer update];
    });
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigning)
        name:UIApplicationWillResignActiveNotification object:nil];
    // A cover running in keeps drawing even while moving is NO. Hold that work too while the player
    // opens or closes, and resume its clock only after the transition has finished.
    SGRObservePlayerTransition(self, ^(id owner) { [owner update]; });
    return self;
}

- (void)dealloc {
    [_link invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - what it shows

- (void)resigning {
    _resigning = YES;
    [self update];
}

- (void)becameActive {
    _resigning = NO;
    [self update];
}

- (BOOL)mayDraw {
    return !_held && !_resigning && UIApplication.sharedApplication.applicationState == UIApplicationStateActive
        && !SGRPlayerIsTransitioning();
}

- (void)setPicture:(CGImageRef)picture animated:(BOOL)animated {
    [self setPicture:picture small:picture animated:animated];
}

- (void)setPicture:(CGImageRef)picture small:(CGImageRef)small animated:(BOOL)animated {
    if (!picture) return;
    if (!small) small = picture;
    if (animated && _toPicture && _drewOnce && [self mayDraw]) {
        // One still running in is cut short: the new one runs in over the one it was bringing.
        _fromPicture = _toPicture;
        _from = _to;
        _fromSmall = _toSmall;
        _fromLess = _toLess;
        // Held still (paused, Low Power Mode, Reduce Motion) it fades over the Light renderer's time, a few
        // frames, rather than flowing for longer.
        _flows = _moving && !SGRReduceMotion();
        _length = _flows ? kRunIn : SGRCrossfade;
        _progress = 0;
    } else {
        _fromPicture = nil;
        _from = nil;
        _fromSmall = nil;
        _fromLess = nil;
        _progress = 1;
    }
    _toPicture = (__bridge id)picture;
    _to = nil;
    _toSmall = (__bridge id)small;
    _toLess = nil;
    _dirty = YES;
    [self update];
}

- (void)setMoving:(BOOL)moving {
    if (moving == _moving) return;
    _moving = moving;
    [self update];
}

- (void)setHeld:(BOOL)held {
    if (held == _held) return;
    _held = held;
    [self update];
}

- (void)setWarp:(float)warp {
    if (warp == _warp) return;
    _warp = warp;
    _dirty = YES;
    [self update];
}

- (void)setGrain:(float)grain {
    if (grain == _grain) return;
    _grain = grain;
    _dirty = YES;
    [self update];
}

- (void)setVisibleRect:(CGRect)rect {
    if (CGRectEqualToRect(rect, _visibleRect)) return;
    _visibleRect = rect;
    _dirty = YES;
    [self update];
}

- (void)setBounds:(CGRect)bounds {
    [super setBounds:bounds];
    [self fit];
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    [self fit];
}

- (void)layoutSublayers {
    [super layoutSublayers];
    [self fit];
}

- (void)fit {
    CGSize bounds = self.bounds.size;
    CGSize size = CGSizeMake(MAX(1, round(bounds.width * self.contentsScale)), MAX(1, round(bounds.height * self.contentsScale)));
    if (CGSizeEqualToSize(size, self.drawableSize)) return;
    self.drawableSize = size;
    _dirty = YES;
    [self update];
}

#pragma mark - drawing

// Ticks while it flows or a cover runs in; otherwise a change waiting to be seen is drawn once.
- (void)update {
    if ((_held || _resigning) && _progress < 1) {
        // Nobody can see the rest of this fade. Return on the destination, even if the track hasn't changed.
        _fromPicture = nil;
        _from = nil;
        _fromSmall = nil;
        _fromLess = nil;
        _progress = 1;
        _dirty = YES;
    }
    BOOL eligible = _ready && _toPicture && [self mayDraw] && _firstFailures < 3;
    BOOL wants = eligible && (_moving || _progress < 1 || [self settling]);
    if (eligible && !wants && _dirty && self.bounds.size.width >= 1 && self.bounds.size.height >= 1)
        wants = ![self draw] && _misses < 30;
    if (wants && !_link) {
        SGRFluidTicker *ticker = [SGRFluidTicker new];
        ticker.layer = self;
        _link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
        _link.preferredFrameRateRange = CAFrameRateRangeMake(15, 120, kDrawFramesPerSecond);
        _last = 0;
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!wants && _link) {
        [_link invalidate];
        _link = nil;
    }
}

// Going from held to flowing or back.
- (BOOL)settling {
    return _moving ? _settle < 1 : _settle > 0;
}

- (void)tick:(CADisplayLink *)link {
    if (![self mayDraw]) {
        [self update];
        return;
    }
    CFTimeInterval now = link.timestamp;
    // Accept the display's 120 Hz cadence without rendering a blurred cover more than 30 times a
    // second. Keep the elapsed time since the last rendered tick, not since a skipped callback.
    if (_last > 0 && floor(now * kDrawFramesPerSecond) == floor(_last * kDrawFramesPerSecond)) return;
    CFTimeInterval step = _last > 0 ? MIN(0.1, now - _last) : 0;
    _last = now;
    if (_moving) _time += step * _rate;
    _settle = (float)MAX(0.0, MIN(1.0, _settle + (_moving ? 1 : -1) * step / kSettle));
    if (_progress < 1) {
        _progress = (float)MIN(1.0, _progress + step / MAX(0.05, _length));
        if (_progress >= 1) {
            _fromPicture = nil;
            _from = nil;
            _fromSmall = nil;
            _fromLess = nil;
        }
    }
    _dirty = YES;
    BOOL drew = [self draw];
    if (_moving || _progress < 1 || [self settling]) return;
    // The last frame of a running-in is tried again for a moment if no drawable was free, rather than left half mixed.
    if (!drew && ++_misses < 30) return;
    [self update];
    _misses = 0;
}

- (BOOL)draw {
    CGRect bounds = self.bounds;
    if (bounds.size.width < 1 || bounds.size.height < 1) return NO;
    id<CAMetalDrawable> drawable = [self nextDrawable];
    if (!drawable) return NO;
    if (!_to) _to = textureOf(_toPicture);
    if (!_toLess) _toLess = textureOf(_toSmall) ?: _to;
    if (_fromPicture && !_from) _from = textureOf(_fromPicture);
    if (_from && !_fromLess) _fromLess = textureOf(_fromSmall) ?: _from;
    if (!_to) return NO;

    CGRect visible = CGRectIsEmpty(_visibleRect) ? bounds : _visibleRect;
    CGFloat longer = MAX(1, MAX(visible.size.width, visible.size.height));
    Uniforms uniforms = {
        .visible = simd_make_float4((float)((visible.origin.x - bounds.origin.x) / bounds.size.width),
                                    (float)((visible.origin.y - bounds.origin.y) / bounds.size.height),
                                    (float)(MAX(1, visible.size.width) / bounds.size.width),
                                    (float)(MAX(1, visible.size.height) / bounds.size.height)),
        .aspect = simd_make_float2((float)(visible.size.width / longer), (float)(visible.size.height / longer)),
        .time = (float)_time,
        .warp = _warp,
        .progress = _from ? _progress : 1,
        .flows = _flows ? 1 : 0,
        .grain = grainSteps(_grain),
        .seed = _seed,
        .playing = _settle * _settle * (3 - 2 * _settle),
    };

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> buffer = [sQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:sPipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:_from ?: _to atIndex:0];
    [encoder setFragmentTexture:_from ? _fromLess : _toLess atIndex:1];
    [encoder setFragmentTexture:_to atIndex:2];
    [encoder setFragmentTexture:_toLess atIndex:3];
    [encoder setFragmentSamplerState:sSampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    if (!_drewOnce && !_firstPending && _firstFailures < 3) {
        _firstPending = YES;
        // Settled once the GPU has finished it and a frame or so later, when it is on screen: the layer lies under
        // the copies, so going a little late shows nothing missing, and going early would show the black under
        // both. A frame the GPU failed leaves the copies, and the next frame tries again.
        __weak SGRFluidGPULayer *weakSelf = self;
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
            BOOL completed = done.status == MTLCommandBufferStatusCompleted;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((completed ? 0.1 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf firstFrameCompleted:completed];
            });
        }];
    }
    [buffer presentDrawable:drawable];
#ifdef SGR_FLUID_FRAME_PROBE
    extern void SGRProbeFluidFrame(CAMetalLayer *, id<CAMetalDrawable>, id<MTLCommandBuffer>);
    SGRProbeFluidFrame(self, drawable, buffer);
#endif
    [buffer commit];
    _dirty = NO;
    return YES;
}

- (void)firstFrameCompleted:(BOOL)completed {
    _firstPending = NO;
    if (_drewOnce) return;
    if (!completed) {
        SGLog(@"redesign kit: Smooth fluid's first frame failed on the GPU (%d), Light stays", ++_firstFailures);
        // Drawn again on the next tick or now; after the third failure update stops the link for good.
        _dirty = YES;
        [self update];
        return;
    }
    _drewOnce = YES;
    SGLog(@"redesign kit: Smooth fluid drew its first frame at %.0fx%.0f", self.drawableSize.width, self.drawableSize.height);
    void (^drawn)(void) = _drawn;
    _drawn = nil;
    if (drawn) drawn();
}

@end
