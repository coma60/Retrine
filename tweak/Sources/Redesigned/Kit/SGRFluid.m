#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRFluid.h"
#import "SGRFluidGPU.h"
#import "SGRTokens.h"

// Each copy: its side as a share of the visible rect's longer side, its center as shares of that rect, and
// one turn's length in seconds (negative turns the other way).
static const struct { CGFloat side, x, y; CFTimeInterval turn; } kCopy[] = {
    {2.2, 0.25, 0.20, 46},
    {2.0, 0.80, 0.35, -61},
    {2.4, 0.30, 0.75, 73},
    {1.8, 0.70, 0.85, -54},
};
enum { kCopies = sizeof(kCopy) / sizeof(kCopy[0]) };
// The blurred cover is small: it is drawn several times the screen's size, so detail is lost anyway. The Blur
// setting is its radius in steps of 1.25 px, so the standard 24 is 30 px (see kBaseGain). No brightness
// offset: Core Image works in linear light, where even -0.08 turned every channel under about 30% to black
// (issue #100), leaving dark covers black and the rest a single saturated channel. The ceiling below darkens.
static const CGFloat kBlurSide = 128, kBlurPerStep = 1.25;
// The upper three copies' opacity at full Warp.
static const float kOverOpacity = 0.7;
// The shade over the bottom of the visible rect, where the controls are. It was flat and light, because the ceiling
// below kept the whole cover dark (and 0.55 left the lower half of a dark cover black, issue #100). The Music app's
// player instead keeps the cover's own colors and brightness down to the title and the bar and goes dark only toward
// its foot (measured over the Mr. Blue Sky cover: ochre at the title, olive at the controls, near black at the foot),
// so the ceiling is higher and the shade does the darkening: none down to kShadeFrom of the visible rect, then along
// x^kShadeEase (x the way from there to the bottom) to its peak. The peak follows how light the lower part of the
// blurred cover is: kShadeLeast over a dark cover (nothing to hold back), kShadeMost over one at the ceiling, so the
// text's contrast holds whatever the cover (4.5:1 at the title and the times, more below).
static const CGFloat kShadeFrom = 0.40, kShadeEase = 1.75, kShadeLeast = 0.30, kShadeMost = 0.62;
enum { kShadeSteps = 6 };
// The share of the blurred cover (from its top) that counts as its lower part, for the shade's peak.
static const CGFloat kLowerFrom = 0.5;
// Each blurred pixel's linear luminance is capped here (kCeilingContrast with Increase Contrast): 0.17 keeps white
// text at 4.7:1 on the brightest pixel before any shade, where 0.07 held every cover far darker than the Music app's.
static const CGFloat kCeiling = 0.17, kCeilingContrast = 0.04;
// The Music app's player behind a still cover: the cover blurred until only its broad colors are left, at its own
// saturation, about a third as light (linear) as the cover's mean. Measured over a black cover with a red and gold
// emblem and a blue and teal painting (3x, 874 pt), its background above the title stood at 44,34,32 and 55,75,88
// of 255, where the 10 px blur and 150% saturation stood at 96,79,70 (the emblem's gold, drawn twice the screen's
// size) and 52,96,108 (the waves' teal). Modelled from the same covers: a 30 px blur (Blur 24), 110% saturation and
// this gain on linear light, times the Brightness setting, give 42,32,27 and 56,70,84.
static const CGFloat kBaseGain = 0.35;
// A dark cover is not darkened with the rest: the Music app's player lifts it. Over a near-black cover (mean 22 of
// 255) its background stood at 31,33,33 above the title, where the gain left 10. Its background is about 0.55 of the
// cover's encoded value with a floor near 30 of 255: the shown luminance is kept at least this much (linear, 30 of
// 255) by a soft maximum, (shown^kFloorSoft + kFloor^kFloorSoft)^(1/kFloorSoft), which leaves the lighter covers
// within a few levels (the red and gold emblem's 37 comes to 38), in the cover's own hue, a black pixel taking gray.
static const CGFloat kFloor = 0.0127, kFloorSoft = 4;
// The Music app holds its background near one saturation whatever the cover: measured in its lower half (HLS, encoded
// values) over a painting of blue, teal, beige and green it stood at 0.31 to 0.41, where the blur averaged the colors to a
// gray of 0.13 to 0.18, and over an almost wholly red cover at 0.39 to 0.43, where the field stood at 0.60 to 0.73. Each
// pixel's saturation is drawn toward kSatTarget along s' = kSatTarget * (s / kSatTarget)^kSatPull (0.13 to 0.30, 0.65 to
// 0.45), its hue and lightness kept; a gray pixel stays gray. kSatTarget is the Saturation slider's standard: the slider
// scales the target with it (0% gray, 250% about 0.9), so it still makes the field grayer or more vivid.
static const CGFloat kSatTarget = 0.4, kSatPull = 0.25;

// HLS saturation of the encoded color `e` (0 to 1) drawn toward `target`, lightness and hue kept.
static void pullSaturation(CGFloat e[3], CGFloat target) {
    CGFloat most = MAX(e[0], MAX(e[1], e[2])), least = MIN(e[0], MIN(e[1], e[2]));
    CGFloat light = (most + least) / 2, spread = most - least;
    if (spread < 1e-4 || light <= 0 || light >= 1) return;
    CGFloat sat = light <= 0.5 ? spread / (most + least) : spread / (2 - most - least);
    CGFloat want = target <= 0 ? 0 : MIN(1, target * pow(sat / target, kSatPull));
    // The same hue at the new saturation: each channel keeps its place between the least and the most.
    CGFloat newSpread = want * (light <= 0.5 ? 2 * light : 2 - 2 * light);
    CGFloat newLeast = light - newSpread / 2;
    for (int c = 0; c < 3; c++) e[c] = MIN(1, MAX(0, newLeast + (e[c] - least) / spread * newSpread));
}

NSNotificationName const SGRFluidSettingsDidChangeNotification = @"spotifyglass.redesign.fluidSettingsDidChange";

// In SGRFluidSetting's order.
static const struct { __unsafe_unretained NSString *key; SGRFluidLimits limits; } kSetting[] = {
    {@"spotifyglass.redesign.fluid.speed", {25, 300, 25, 100}},
    {@"spotifyglass.redesign.fluid.warp", {0, 100, 5, 100}},
    {@"spotifyglass.redesign.fluid.blur", {2, 32, 1, 24}},
    {@"spotifyglass.redesign.fluid.saturation", {0, 250, 10, 110}},
    {@"spotifyglass.redesign.fluid.brightness", {40, 150, 5, 100}},
    {@"spotifyglass.redesign.fluid.grain", {0, 200, 10, 100}},
};

SGRFluidLimits SGRFluidLimitsOf(SGRFluidSetting setting) {
    return kSetting[setting].limits;
}

NSInteger SGRFluidValue(SGRFluidSetting setting) {
    SGRFluidLimits l = kSetting[setting].limits;
    return MIN(l.most, MAX(l.least, SGInt(kSetting[setting].key, l.standard)));
}

void SGRSetFluidValue(SGRFluidSetting setting, NSInteger value) {
    SGSetInt(kSetting[setting].key, value);
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFluidSettingsDidChangeNotification object:nil];
}

void SGRResetFluidSettings(void) {
    for (NSInteger i = 0; i < SGRFluidSettingCount; i++) [NSUserDefaults.standardUserDefaults removeObjectForKey:kSetting[i].key];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFluidSettingsDidChangeNotification object:nil];
}

static NSString *const kRendererKey = @"spotifyglass.redesign.fluid.renderer";

SGRFluidRenderer SGRFluidRendererChosen(void) {
    return SGInt(kRendererKey, SGRFluidRendererLight) == SGRFluidRendererSmooth ? SGRFluidRendererSmooth : SGRFluidRendererLight;
}

void SGRSetFluidRenderer(SGRFluidRenderer renderer) {
    SGSetInt(kRendererKey, renderer);
    [NSNotificationCenter.defaultCenter postNotificationName:SGRFluidSettingsDidChangeNotification object:nil];
}

NSArray<NSString *> *SGRFluidRendererNames(void) {
    return @[SGL(@"settings.player.fluid.renderer.light", @"Light"), SGL(@"settings.player.fluid.renderer.smooth", @"Smooth")];
}

// `gain` is the Brightness setting as a factor on linear light, applied under the ceiling below.
static UIImage *blurred(UIImage *image, BOOL contrast, CGFloat radius, CGFloat saturation, CGFloat gain, CGFloat *lowerLight) {
    CGImageRef source = image.CGImage;
    if (!source) return nil;
    CIImage *input = [CIImage imageWithCGImage:source];
    CGFloat scale = kBlurSide / MAX(input.extent.size.width, input.extent.size.height);
    input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = input.extent;
    CIImage *output = [[[input imageByClampingToExtent]
        imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(radius)}]
        imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey: @(saturation)}];
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [context createCGImage:[output imageByCroppingToRect:extent] fromRect:extent];
    if (!cg) return nil;
    // Each blurred pixel is capped at a linear luminance (0.04 with Increase Contrast) that keeps the player's
    // white text at about 8.8:1 and its 65% white at about 4.7:1 on the brightest; an average alone would leave
    // a bright patch of a cover behind the text. The Brightness gain scales the capped pixel, so below 100 it
    // darkens every cover alike (applied before the cap, a bright cover stayed at the ceiling whatever the
    // setting); above 100 it lifts the darker pixels, and the ceiling still holds the bright ones.
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) { CGImageRelease(cg); return nil; }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cg);
    CGImageRelease(cg);
    unsigned char *pixels = CGBitmapContextGetData(bitmap);
    CGFloat ceiling = contrast ? kCeilingContrast : kCeiling, lowerSum = 0;
    // The Saturation slider against its standard moves the saturation the field is held near (kSatTarget).
    CGFloat satTarget = kSatTarget * saturation / (SGRFluidLimitsOf(SGRFluidSaturation).standard / 100.0);
    size_t lowerCount = 0, lowerRow = (size_t)floor(height * kLowerFrom);
    for (size_t i = 0; i < width * height; i++) {
        unsigned char *p = pixels + i * 4;
        CGFloat rgb[3];
        for (int c = 0; c < 3; c++) {
            CGFloat v = p[c] / 255.0;
            rgb[c] = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
        }
        CGFloat light = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        CGFloat cap = MIN(gain * (light > ceiling ? ceiling / light : 1), ceiling / light);
        // The floor (kFloor), never over the ceiling; a pixel with no light to scale takes the floor's gray.
        CGFloat shown = MIN(ceiling, light * cap), floored = MIN(ceiling, pow(pow(shown, kFloorSoft) + pow(kFloor, kFloorSoft), 1 / kFloorSoft));
        BOOL gray = light < 1e-5;
        if (!gray) cap = floored / light;
        if (i / width >= lowerRow) { lowerSum += floored; lowerCount++; }
        CGFloat encoded[3];
        for (int c = 0; c < 3; c++) {
            CGFloat v = MIN(1, gray ? floored : rgb[c] * cap);
            encoded[c] = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055;
        }
        pullSaturation(encoded, satTarget);
        for (int c = 0; c < 3; c++) p[c] = floor(255 * encoded[c]);
        p[3] = 255;
    }
    // 0 for a black lower part, 1 for one at the ceiling.
    if (lowerLight) *lowerLight = lowerCount ? MIN(1, lowerSum / lowerCount / ceiling) : 0;
    cg = CGBitmapContextCreateImage(bitmap);
    UIImage *result = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    CGContextRelease(bitmap);
    return result;
}

@implementation SGRFluidLayer {
    CALayer *_copies[kCopies];
    CAGradientLayer *_shade;
    CGFloat _lowerLight;   // how light the shown cover's lower part is, 0 to 1 (blurred())
    UIImage *_source;
    UIImage *_blur;   // the last blurred cover shown, handed to Smooth when it comes
    NSUInteger _generation;
    BOOL _moving;
    BOOL _turning;   // the copies' turns are running (moving, and Smooth is not showing)
    CFTimeInterval _since, _elapsed;   // _elapsed in turns at the standard speed
    CGFloat _rate, _warp;              // Speed and Warp as factors, read when the copies are laid out or started
    CGRect _laidOutFor;
    SGRFluidGPULayer *_gpu;   // Smooth, under the copies; nil while Light is chosen
    BOOL _gpuShown;           // its first frame is on screen and the copies are hidden
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.masksToBounds = YES;
    self.backgroundColor = UIColor.blackColor.CGColor;
    for (int i = 0; i < kCopies; i++) {
        _copies[i] = [CALayer layer];
        _copies[i].contentsGravity = kCAGravityResizeAspectFill;
        [self addSublayer:_copies[i]];
    }
    [self applyWarp];
    _shade = [CAGradientLayer layer];
    [self updateShadeColors];
    [self addSublayer:_shade];
    [self applyRenderer];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(contrastChanged)
        name:UIAccessibilityDarkerSystemColorsStatusDidChangeNotification object:nil];
    // Posted on the main thread by the Player page's sliders, so the change applies at once.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged)
        name:SGRFluidSettingsDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)contrastChanged {
    dispatch_async(dispatch_get_main_queue(), ^{ [self reblur]; });
}

// The same cover blurred again, for a new Blur, Saturation, Brightness or contrast.
- (void)reblur {
    UIImage *source = _source;
    _source = nil;
    [self setArtwork:source animated:NO];
}

// Warp is how far from the visible rect's middle the copies turn, and how much the upper three show: at none,
// one copy turns about the middle, a still picture turning, with nothing to flow through it.
- (void)applyWarp {
    _warp = SGRFluidValue(SGRFluidWarp) / 100.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 1; i < kCopies; i++) _copies[i].opacity = kOverOpacity * (float)_warp;
    [CATransaction commit];
}

- (void)settingsChanged {
    // Restarted at the new speed from the angle each copy is at, and laid out again for the new warp.
    if (_turning) [self stop];
    [self applyWarp];
    _laidOutFor = CGRectNull;
    [self setNeedsLayout];
    [self applyRenderer];
    [self updateCopies];
    [self reblur];
}

#pragma mark - the renderer

// Smooth made and laid under the copies, or taken away and the copies shown again, as chosen.
- (void)applyRenderer {
    BOOL smooth = SGRFluidRendererChosen() == SGRFluidRendererSmooth && SGRFluidGPUAvailable();
    if (smooth && !_gpu) {
        _gpu = [SGRFluidGPULayer layer];
        [self insertSublayer:_gpu atIndex:0];
        __weak SGRFluidLayer *weakSelf = self;
        __weak SGRFluidGPULayer *weakGPU = _gpu;
        _gpu.drawn = ^{ [weakSelf gpuDrew:weakGPU]; };
        _gpu.held = self.hidden;
        _gpu.moving = _moving;
        [self setNeedsLayout];
        if (_blur) [_gpu setPicture:_blur.CGImage animated:NO];
    } else if (!smooth && _gpu) {
        _gpu.moving = NO;
        [_gpu removeFromSuperlayer];
        _gpu = nil;
        _gpuShown = NO;
        [self showCopies];
    }
    _gpu.rate = (float)(SGRFluidValue(SGRFluidSpeed) / 100.0);
    _gpu.warp = (float)_warp;
    _gpu.grain = (float)(SGRFluidValue(SGRFluidGrain) / 100.0);
}

- (void)gpuDrew:(SGRFluidGPULayer *)gpu {
    if (!gpu || gpu != _gpu || _gpuShown) return;
    _gpuShown = YES;
    [self showCopies];
}

// The copies shown and turning while Smooth is not on screen, hidden and still while it is.
- (void)showCopies {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) _copies[i].hidden = _gpuShown;
    [CATransaction commit];
    [self updateCopies];
}

- (void)updateCopies {
    BOOL turn = _moving && !_gpuShown;
    if (turn && !_turning) [self start];
    else if (!turn && _turning) [self stop];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    _gpu.held = hidden;
}

- (BOOL)moving {
    return _moving;
}

- (void)setVisibleRect:(CGRect)rect {
    if (CGRectEqualToRect(rect, _visibleRect)) return;
    _visibleRect = rect;
    [self setNeedsLayout];
}

// The shade's stops: nothing at the top, then x^kShadeEase of the peak down to the bottom, the peak following how light
// the cover's lower part is.
- (void)updateShadeColors {
    CGFloat peak = kShadeLeast + (kShadeMost - kShadeLeast) * MAX(0, MIN(1, _lowerLight));
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:kShadeSteps + 1];
    for (int i = 0; i <= kShadeSteps; i++) {
        [colors addObject:(__bridge id)[UIColor colorWithWhite:0 alpha:peak * pow((CGFloat)i / kShadeSteps, kShadeEase)].CGColor];
    }
    _shade.colors = colors;
}

- (void)layoutSublayers {
    [super layoutSublayers];
    CGRect bounds = self.bounds;
    CGRect visible = CGRectIsEmpty(_visibleRect) ? bounds : _visibleRect;
    CGFloat total = MAX(1, bounds.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shade.frame = bounds;
    CGFloat shadeTop = MIN(1, (CGRectGetMinY(visible) + visible.size.height * kShadeFrom) / total), shadeBottom = MIN(1, CGRectGetMaxY(visible) / total);
    NSMutableArray *at = [NSMutableArray arrayWithCapacity:kShadeSteps + 1];
    for (int i = 0; i <= kShadeSteps; i++) [at addObject:@(shadeTop + (shadeBottom - shadeTop) * i / kShadeSteps)];
    _shade.locations = at;
    _gpu.frame = bounds;
    _gpu.visibleRect = visible;
    if (!CGRectEqualToRect(visible, _laidOutFor) && visible.size.width >= 1) {
        _laidOutFor = visible;
        if (_turning) [self stop];
        CGFloat longer = MAX(visible.size.width, visible.size.height);
        for (int i = 0; i < kCopies; i++) {
            CGFloat side = round(longer * kCopy[i].side);
            _copies[i].bounds = CGRectMake(0, 0, side, side);
            _copies[i].position = CGPointMake(CGRectGetMidX(visible) + visible.size.width * (kCopy[i].x - 0.5) * _warp,
                                              CGRectGetMidY(visible) + visible.size.height * (kCopy[i].y - 0.5) * _warp);
        }
        [self updateCopies];
    }
    [CATransaction commit];
}

- (void)setArtwork:(UIImage *)image animated:(BOOL)animated {
    if (!image || image == _source) return;
    _source = image;
    NSUInteger generation = ++_generation;
    BOOL contrast = SGRIncreaseContrast();
    CGFloat radius = kBlurPerStep * SGRFluidValue(SGRFluidBlur), saturation = SGRFluidValue(SGRFluidSaturation) / 100.0;
    CGFloat gain = kBaseGain * SGRFluidValue(SGRFluidBrightness) / 100.0;
    __weak SGRFluidLayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGFloat lowerLight = 0;
        UIImage *blur = blurred(image, contrast, radius, saturation, gain, &lowerLight);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRFluidLayer *layer = weakSelf;
            if (!blur || !layer || generation != layer->_generation) return;
            [layer show:blur lowerLight:lowerLight animated:animated];
        });
    });
}

- (void)show:(UIImage *)blur lowerLight:(CGFloat)lowerLight animated:(BOOL)animated {
    _blur = blur;
    _lowerLight = lowerLight;
    // The shade's peak follows the new cover's lower part, crossfading with the cover.
    [CATransaction begin];
    [CATransaction setDisableActions:!animated];
    [CATransaction setAnimationDuration:SGRCrossfade];
    [self updateShadeColors];
    [CATransaction commit];
    [_gpu setPicture:blur.CGImage animated:animated];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        if (animated) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = SGRCrossfade;
            [_copies[i] addAnimation:fade forKey:@"contents"];
        }
        _copies[i].contents = (__bridge id)blur.CGImage;
    }
    [CATransaction commit];
}

#pragma mark - moving

- (void)setMoving:(BOOL)moving {
    if (moving == _moving) return;
    _moving = moving;
    _gpu.moving = moving;
    [self updateCopies];
}

- (void)start {
    if (self.bounds.size.width < 1) return;
    _turning = YES;
    _since = CACurrentMediaTime();
    _rate = SGRFluidValue(SGRFluidSpeed) / 100.0;
    CAFrameRateRange rate = CAFrameRateRangeMake(15, 60, 30);
    for (int i = 0; i < kCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        // The turn's offset carries the angle it stopped at, so the resting angle goes back to none.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _copies[i].transform = CATransform3DIdentity;
        [CATransaction commit];
        CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        turn.byValue = @(kCopy[i].turn > 0 ? 2 * M_PI : -2 * M_PI);
        turn.duration = length / _rate;
        turn.repeatCount = HUGE_VALF;
        turn.additive = YES;
        turn.timeOffset = fmod(_elapsed, length) / _rate;
        turn.preferredFrameRateRange = rate;
        [_copies[i] addAnimation:turn forKey:@"turn"];
    }
}

// Every copy held at the angle it is drawn at now.
- (void)stop {
    if (!_turning) return;
    _turning = NO;
    if (_since > 0) _elapsed += (CACurrentMediaTime() - _since) * _rate;
    _since = 0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        CFTimeInterval length = fabs(kCopy[i].turn);
        CGFloat angle = (kCopy[i].turn > 0 ? 1 : -1) * 2 * M_PI * fmod(_elapsed, length) / length;
        [_copies[i] removeAnimationForKey:@"turn"];
        _copies[i].transform = CATransform3DMakeRotation(angle, 0, 0, 1);
    }
    [CATransaction commit];
}

@end
