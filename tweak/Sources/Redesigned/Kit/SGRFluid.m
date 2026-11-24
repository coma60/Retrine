#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRFluid.h"
#import "SGRFluidGPU.h"
#import "SGRTokens.h"

// The copies, laid out as the Music app's player lays its own: the unit is half the visible rect's longer side (its
// height on a phone), measured from its middle with y up. Each copy is a square of the cover `side` units across,
// centered `x`, `y` units from the middle, turning clockwise about its own center once in `turn` seconds; a copy with
// an `orbit` is also carried clockwise about the middle once in that many seconds (the third rides the first's turn).
// Each is opaque and drawn over the one before.
static const struct { CGFloat side, x, y; CFTimeInterval turn, orbit; } kCopy[] = {
    {1.4, 0, 0, 120, 0},
    {0.7, -0.25, 0.15, 70, 0},
    {0.7, 0.7, 0.7, 90, 120},
};
enum { kCopies = sizeof(kCopy) / sizeof(kCopy[0]) };
// The smaller copies' edges are feathered over this share of their side, so they run into the copy under them as the
// Music app's blur of the whole square runs them together.
static const CGFloat kCopyFeather = 0.22;
// Held still (paused), the Music app shows its backdrop flat and this much larger, going there and back over kSettle.
static const CGFloat kHeldZoom = 1.25;
static const CFTimeInterval kSettle = 0.8;
// Its blur's standard deviation, in points on screen. Core Image's radius is the standard deviation itself (measured,
// .github/workflows/ci-blur-probe.yml: 1.00 at 4 to 64 px). Fitted to a few screenshots, 1.8 times it looked nearer,
// but against a simulation of the Music app's own pipeline (the copies, blur and color table as read from it) over
// three covers at many moments of the turn, its own 160 pt came nearest, and 1.8 times washed out the red a mostly
// black cover's banner gives the top of the screen.
static const CGFloat kBackdropSigma = 160;
// The blurred cover is small: it is drawn larger than the screen, so detail is lost anyway. The Blur setting scales
// kBackdropSigma (the standard 24 is the Music app's), worked out as a radius on this cover in setArtwork:. Core
// Image works here on encoded values,
// as the Music app's shader does (in linear light even -0.08 turned every channel under about 30% to black, issue #100).
static const CGFloat kBlurSide = 128;
// The shade over the bottom of the visible rect, where the controls are. It was flat and light, because the ceiling
// below kept the whole cover dark (and 0.55 left the lower half of a dark cover black, issue #100). The Music app's
// player instead keeps the cover's own colors and brightness down to the title and the bar and goes dark only toward
// its foot (measured over the Mr. Blue Sky cover: ochre at the title, olive at the controls, near black at the foot),
// so the ceiling is higher and the shade does the darkening: none down to kShadeFrom of the visible rect, then along
// x^kShadeEase (x the way from there to the bottom) to its peak. The peak follows how light the lower part of the
// blurred cover is: kShadeLeast over a dark cover (nothing to hold back), kShadeMost over one at the ceiling, so the
// text's contrast holds whatever the cover (4.5:1 at the title and the times, more below). The peak over a light cover
// was 0.62; beside the Music app over Fuel's orange its foot stood at 45, 27, 17 where 0.62 took Retrine's to 28, 18,
// 16, so it is 0.48 (the player's ink brightens over a light backdrop, SGRBackdropInk.h).
static const CGFloat kShadeFrom = 0.40, kShadeEase = 1.75, kShadeLeast = 0.30, kShadeMost = 0.48;
enum { kShadeSteps = 6 };
// The share of the blurred cover (from its top) that counts as its lower part, for the shade's peak.
static const CGFloat kLowerFrom = 0.5;
// With Increase Contrast each blurred pixel's linear luminance is capped at kCeilingContrast, which keeps the player's
// white text at about 8.8:1 on the brightest. kCeiling is only the scale of the shade's peak (lowerLight): a lower part
// at this linear luminance takes kShadeMost.
static const CGFloat kCeiling = 0.17, kCeilingContrast = 0.04;
// Chosen to match the Music app's player behind a still cover, on encoded sRGB values: the cover is mixed toward black
// by kBackdropBlack, its saturation is scaled by kBackdropSaturation about its Rec. 709 luma, the result is
// blurred, mixed toward white by kBackdropWhite and passed through a color grade (backdropGrade),
// which leaves grays nearly as they are and pulls strong reds and blues in. The Saturation slider scales kBackdropSaturation against
// its standard; the Brightness slider scales the result's linear light.
static const CGFloat kBackdropBlack = 0.5, kBackdropSaturation = 2.4, kBackdropWhite = 0.1;
// The Music app also raises the contrast about middle gray (1 + 0.076 a) and the saturation (+ 0.166 a) by how loud the
// music is (a, 0 to 1). Retrine does not listen to it here and takes this steady level for music playing: measured
// against its player over three covers, Retrine's darkest channel stood 8 to 10 of 255 higher without it.
static const CGFloat kBackdropLoudness = 0.8, kBackdropContrastPerLoudness = 0.076, kBackdropSaturationPerLoudness = 0.166;

// Retrine's grade for the backdrop, on an encoded color `e` (0 to 1), made to look like the Music app's. What its color
// table does, read off its output: greens, yellows, cyans and magentas pass nearly untouched, while a color whose red
// (or blue) stands out above both other channels is pulled toward a neutral point, by up to 36% (33% for blue) as that
// channel stands further out; the other channels rise a little, and a slight contrast curve runs over everything (16
// of 255 goes to 12, 239 to 243). Here that is a dozen numbers: the pull per standing-out channel (kGradeRed,
// kGradeBlue: strength, then where the ease starts and ends, as the share of the channel above the next highest), the
// neutral point (a mix of luma, the lowest channel and the mean, raised with the pull), and the curve (gain, offset).
// Fitted to the look by least squares; it lands within 0.8 of 255 on average and 6.6 at worst (a pure red).
static const CGFloat kGradeRed[3] = {0.3633, 0.1641, 0.8199}, kGradeBlue[3] = {0.3336, 0.1497, 0.8128};
static const CGFloat kGradeLuma = 0.0821, kGradeFloor = 0.5891, kGradeRaise = 0.1736, kGradeLift = -0.0603;
static const CGFloat kGradeGain = 1.0292, kGradeOffset = -0.0152;

static CGFloat gradeEase(CGFloat from, CGFloat to, CGFloat v) {
    CGFloat t = MIN(1, MAX(0, (v - from) / (to - from)));
    return t * t * (3 - 2 * t);
}

static void backdropGrade(CGFloat e[3]) {
    CGFloat lo = MIN(e[0], MIN(e[1], e[2])), hi = MAX(e[0], MAX(e[1], e[2]));
    CGFloat c[3] = {e[0] - lo, e[1] - lo, e[2] - lo};
    CGFloat pull = 0;
    const CGFloat *curve[2] = {kGradeRed, kGradeBlue};
    const int channel[2] = {0, 2};
    for (int i = 0; i < 2; i++) {
        int ch = channel[i];
        CGFloat own = c[ch], other = MAX(c[(ch + 1) % 3], c[(ch + 2) % 3]);
        if (own > 1e-9) pull += curve[i][0] * gradeEase(curve[i][1], curve[i][2], (own - other) / own);
    }
    CGFloat luma = 0.2126 * e[0] + 0.7152 * e[1] + 0.0722 * e[2], mean = (e[0] + e[1] + e[2]) / 3;
    CGFloat neutral = kGradeLuma * luma + kGradeFloor * lo + (1 - kGradeLuma - kGradeFloor) * mean + kGradeRaise * pull * hi;
    for (int k = 0; k < 3; k++) {
        CGFloat y = neutral + (1 - pull) * (e[k] - neutral) + kGradeLift * pull * hi;
        e[k] = MIN(1, MAX(0, kGradeGain * y + kGradeOffset));
    }
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

// `saturation` is the Saturation setting as a factor (1.1 its standard), `gain` the Brightness setting's on linear light.
static UIImage *blurred(UIImage *image, BOOL contrast, CGFloat radius, CGFloat saturation, CGFloat gain, CGFloat *lowerLight) {
    CGImageRef source = image.CGImage;
    if (!source) return nil;
    CIImage *input = [CIImage imageWithCGImage:source];
    CGFloat scale = kBlurSide / MAX(input.extent.size.width, input.extent.size.height);
    input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = input.extent;
    // The Music app's copy treatment before its blur: toward black, contrast about middle gray, then saturation about
    // the luma, clamped as its 8-bit texture holds it. One matrix and a bias: each output channel is
    // spread * keep * (s * own + (1 - s) * luma) + (1 - spread) / 2, spread the contrast (the saturation leaves a gray
    // as it is).
    CGFloat s = (kBackdropSaturation + kBackdropSaturationPerLoudness * kBackdropLoudness) * saturation
              / (SGRFluidLimitsOf(SGRFluidSaturation).standard / 100.0);
    CGFloat spread = 1 + kBackdropContrastPerLoudness * kBackdropLoudness;
    CGFloat keep = 1 - kBackdropBlack, luma[3] = {0.2126, 0.7152, 0.0722}, bias = (1 - spread) / 2;
    CIVector *rows[3];
    for (int c = 0; c < 3; c++) {
        CGFloat m[3];
        for (int k = 0; k < 3; k++) m[k] = spread * keep * ((1 - s) * luma[k] + (c == k ? s : 0));
        rows[c] = [CIVector vectorWithX:m[0] Y:m[1] Z:m[2] W:0];
    }
    CIImage *output = [[[[input imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{
            @"inputRVector": rows[0], @"inputGVector": rows[1], @"inputBVector": rows[2],
            @"inputBiasVector": [CIVector vectorWithX:bias Y:bias Z:bias W:0]}]
        imageByApplyingFilter:@"CIColorClamp" withInputParameters:@{}] imageByClampingToExtent]
        imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(radius)}];
    static CIContext *context;
    static dispatch_once_t once;
    // Covers are prepared even offscreen; leave GPU submission to the visible renderer.
    dispatch_once(&once, ^{
        CGColorSpaceRef encoded = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: (__bridge id)encoded,
                                                  kCIContextUseSoftwareRenderer: @YES}];
        CGColorSpaceRelease(encoded);
    });
    CGImageRef cg = [context createCGImage:[output imageByCroppingToRect:extent] fromRect:extent];
    if (!cg) return nil;
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) { CGImageRelease(cg); return nil; }
    CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), cg);
    CGImageRelease(cg);
    unsigned char *pixels = CGBitmapContextGetData(bitmap);
    CGFloat lowerSum = 0;
    size_t lowerCount = 0, lowerRow = (size_t)floor(height * kLowerFrom);
    for (size_t i = 0; i < width * height; i++) {
        unsigned char *p = pixels + i * 4;
        // After the blur: toward white, then the grade.
        CGFloat e[3];
        for (int c = 0; c < 3; c++) e[c] = p[c] / 255.0 * (1 - kBackdropWhite) + kBackdropWhite;
        backdropGrade(e);
        // The Brightness setting on linear light, and with Increase Contrast the cap.
        CGFloat rgb[3];
        for (int c = 0; c < 3; c++) {
            CGFloat v = e[c];
            rgb[c] = (v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) * gain;
        }
        CGFloat light = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
        CGFloat cap = contrast && light > kCeilingContrast ? kCeilingContrast / light : 1;
        if (i / width >= lowerRow) { lowerSum += light * cap; lowerCount++; }
        for (int c = 0; c < 3; c++) {
            CGFloat v = MIN(1, rgb[c] * cap);
            p[c] = floor(255 * (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055));
        }
        p[3] = 255;
    }
    // 0 for a black lower part, 1 for one at kCeiling or lighter.
    if (lowerLight) *lowerLight = lowerCount ? MIN(1, lowerSum / lowerCount / kCeiling) : 0;
    cg = CGBitmapContextCreateImage(bitmap);
    UIImage *result = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    CGContextRelease(bitmap);
    return result;
}

// A square that is opaque in the middle and fades to clear over kCopyFeather of its side at each edge (smoothstep),
// the mask of the smaller copies.
static CGImageRef featherMask(void) {
    static CGImageRef mask;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        enum { kSide = 64 };
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef bitmap = CGBitmapContextCreate(NULL, kSide, kSide, 8, kSide, gray, (CGBitmapInfo)kCGImageAlphaOnly);
        CGColorSpaceRelease(gray);
        if (!bitmap) return;
        unsigned char *pixels = CGBitmapContextGetData(bitmap);
        for (int y = 0; y < kSide; y++) {
            for (int x = 0; x < kSide; x++) {
                CGFloat u = (x + 0.5) / kSide, v = (y + 0.5) / kSide;
                CGFloat edge = MIN(MIN(u, 1 - u), MIN(v, 1 - v)) / kCopyFeather;
                CGFloat t = MAX(0, MIN(1, edge));
                pixels[y * kSide + x] = (unsigned char)round(255 * t * t * (3 - 2 * t));
            }
        }
        mask = CGBitmapContextCreateImage(bitmap);
        CGContextRelease(bitmap);
    });
    return mask;
}

@implementation SGRFluidLayer {
    CALayer *_canvas;   // the copies, shown a quarter larger while held still (kHeldZoom)
    CALayer *_orbits[kCopies];   // each copy's journey about the middle, for those with an orbit
    CALayer *_copies[kCopies];
    CAGradientLayer *_shade;
    CGFloat _lowerLight;   // how light the shown cover's lower part is, 0 to 1 (blurred())
    UIImage *_source;
    UIImage *_blur;   // the last blurred cover shown, handed to Smooth when it comes
    UIImage *_blurSmall;   // the same blurred for the smaller copies
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
    _canvas = [CALayer layer];
    _canvas.transform = CATransform3DMakeScale(kHeldZoom, kHeldZoom, 1);
    [self addSublayer:_canvas];
    for (int i = 0; i < kCopies; i++) {
        _orbits[i] = [CALayer layer];
        _copies[i] = [CALayer layer];
        _copies[i].contentsGravity = kCAGravityResizeAspectFill;
        if (i > 0) {
            CALayer *mask = [CALayer layer];
            mask.contents = (__bridge id)featherMask();
            _copies[i].mask = mask;
        }
        [_orbits[i] addSublayer:_copies[i]];
        [_canvas addSublayer:_orbits[i]];
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

// Warp is how far from the middle the smaller copies sit, and how much they show (opaque at the standard 100 %): at
// none, the large copy turns alone, a still picture turning, with nothing to flow through it.
- (void)applyWarp {
    _warp = SGRFluidValue(SGRFluidWarp) / 100.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 1; i < kCopies; i++) _copies[i].opacity = (float)_warp;
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
        if (_blur) [_gpu setPicture:_blur.CGImage small:(_blurSmall ?: _blur).CGImage animated:NO];
    } else if (!smooth && _gpu) {
        _gpu.held = YES;
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
    _canvas.hidden = _gpuShown;
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
    // Grown about the visible rect's middle.
    if (bounds.size.width >= 1 && bounds.size.height >= 1) {
        _canvas.bounds = bounds;
        _canvas.anchorPoint = CGPointMake((CGRectGetMidX(visible) - bounds.origin.x) / bounds.size.width,
                                          (CGRectGetMidY(visible) - bounds.origin.y) / bounds.size.height);
        _canvas.position = CGPointMake(CGRectGetMidX(visible), CGRectGetMidY(visible));
    }
    if (!CGRectEqualToRect(visible, _laidOutFor) && visible.size.width >= 1) {
        _laidOutFor = visible;
        if (_turning) [self stop];
        CGFloat half = MAX(visible.size.width, visible.size.height) / 2;
        for (int i = 0; i < kCopies; i++) {
            CGFloat side = round(2 * half * kCopy[i].side);
            _orbits[i].bounds = CGRectMake(0, 0, 2 * half, 2 * half);
            _orbits[i].position = CGPointMake(CGRectGetMidX(visible), CGRectGetMidY(visible));
            _copies[i].bounds = CGRectMake(0, 0, side, side);
            _copies[i].position = CGPointMake(half * (1 + kCopy[i].x * _warp), half * (1 - kCopy[i].y * _warp));
            _copies[i].mask.frame = _copies[i].bounds;
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
    // The blur in points on screen, as the Music app's (kBackdropSigma at the standard Blur), as a radius on the large
    // copy's cover: it is kCopy[0].side units across, a unit half the visible rect's longer side.
    CGRect visible = CGRectIsEmpty(_visibleRect) ? self.bounds : _visibleRect;
    CGFloat longer = MAX(visible.size.width, visible.size.height);
    if (longer < 1) longer = MAX(UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height);
    CGFloat points = kBackdropSigma * SGRFluidValue(SGRFluidBlur) / SGRFluidLimitsOf(SGRFluidBlur).standard;
    CGFloat radius = points * kBlurSide / (kCopy[0].side * longer), saturation = SGRFluidValue(SGRFluidSaturation) / 100.0;
    CGFloat gain = SGRFluidValue(SGRFluidBrightness) / 100.0;
    __weak SGRFluidLayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGFloat lowerLight = 0, ignored = 0;
        UIImage *blur = blurred(image, contrast, radius, saturation, gain, &lowerLight);
        // The smaller copies are half the large one's size, so their cover is blurred twice as far for the same blur
        // on screen, as the Music app blurs the whole square at once.
        UIImage *small = blurred(image, contrast, radius * kCopy[0].side / kCopy[1].side, saturation, gain, &ignored);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRFluidLayer *layer = weakSelf;
            if (!blur || !layer || generation != layer->_generation) return;
            [layer show:blur small:small ?: blur lowerLight:lowerLight animated:animated];
        });
    });
}

- (void)show:(UIImage *)blur small:(UIImage *)small lowerLight:(CGFloat)lowerLight animated:(BOOL)animated {
    _blur = blur;
    _blurSmall = small;
    _lowerLight = lowerLight;
    // The shade's peak follows the new cover's lower part, crossfading with the cover.
    [CATransaction begin];
    [CATransaction setDisableActions:!animated];
    [CATransaction setAnimationDuration:SGRCrossfade];
    [self updateShadeColors];
    [CATransaction commit];
    [_gpu setPicture:blur.CGImage small:small.CGImage animated:animated];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < kCopies; i++) {
        if (animated) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = SGRCrossfade;
            [_copies[i] addAnimation:fade forKey:@"contents"];
        }
        _copies[i].contents = (__bridge id)(i == 0 ? blur : small).CGImage;
    }
    [CATransaction commit];
}

#pragma mark - moving

- (void)setMoving:(BOOL)moving {
    if (moving == _moving) return;
    _moving = moving;
    _gpu.moving = moving;
    [self updateCopies];
    // Flowing at its own size, held a quarter larger, eased over kSettle as the Music app's backdrop goes.
    CGFloat zoom = moving ? 1 : kHeldZoom;
    [CATransaction begin];
    [CATransaction setAnimationDuration:kSettle];
    [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithControlPoints:0.42 :0 :0.58 :1]];
    _canvas.transform = CATransform3DMakeScale(zoom, zoom, 1);
    [CATransaction commit];
}

- (void)start {
    if (self.bounds.size.width < 1) return;
    _turning = YES;
    _since = CACurrentMediaTime();
    _rate = SGRFluidValue(SGRFluidSpeed) / 100.0;
    CAFrameRateRange rate = CAFrameRateRangeMake(15, 60, 30);
    for (int i = 0; i < kCopies; i++) {
        CALayer *layers[2] = {_copies[i], _orbits[i]};
        CFTimeInterval lengths[2] = {kCopy[i].turn, kCopy[i].orbit};
        for (int k = 0; k < 2; k++) {
            if (lengths[k] <= 0) continue;
            // The turn's offset carries the angle it stopped at, so the resting angle goes back to none.
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            layers[k].transform = CATransform3DIdentity;
            [CATransaction commit];
            // Clockwise on screen, where y runs down.
            CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            turn.byValue = @(2 * M_PI);
            turn.duration = lengths[k] / _rate;
            turn.repeatCount = HUGE_VALF;
            turn.additive = YES;
            turn.timeOffset = fmod(_elapsed, lengths[k]) / _rate;
            turn.preferredFrameRateRange = rate;
            [layers[k] addAnimation:turn forKey:@"turn"];
        }
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
        CALayer *layers[2] = {_copies[i], _orbits[i]};
        CFTimeInterval lengths[2] = {kCopy[i].turn, kCopy[i].orbit};
        for (int k = 0; k < 2; k++) {
            if (lengths[k] <= 0) continue;
            CGFloat angle = 2 * M_PI * fmod(_elapsed, lengths[k]) / lengths[k];
            [layers[k] removeAnimationForKey:@"turn"];
            layers[k].transform = CATransform3DMakeRotation(angle, 0, 0, 1);
        }
    }
    [CATransaction commit];
}

@end
