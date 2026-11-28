// The player footer's disc of the control that is on (PlayerFooter.x, issue #83), the real PlayerFooter.x on Mac Catalyst:
//  - the disc is masked (disc.layer.mask), nothing is drawn with a compositing filter, and the button is no group of
//    its own: cut live with destOut the hole took the backdrop out with it and stood black;
//  - drawn over a blue and a gray backdrop, the glyph's hole shows the backdrop, never black;
//  - pressed, the hole fills back in to 0.4 of the disc, through a new reading of the backdrop too, and is clear again
//    on release;
//  - under Increase Contrast the disc is whole with the glyph black on it, and the hole comes back without it;
//  - off, the disc is gone and the glyph is in the rest ink;
//  - Spotify's Encore glyph (Music app icons off) cuts the same hole, a new icon in the same view a new hole, a press
//    through a new reading the same 0.4, the switch between the two glyphs the other's hole, and an unsized one none.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Headers/SPTEncoreIconView.h"
#import "Redesigned/Kit/SGRPress.h"
#import "Redesigned/Player/Player.h"
#import "Redesigned/Player/PlayerQueue.h"
#import "../harness-fail.h"

#pragma mark - what the footer reaches outside the file

static BOOL sg_contrast, sg_lyricsOpen, sg_musicIcons = YES;
static int checked, failed;

BOOL UIAccessibilityDarkerSystemColorsEnabled(void) { return sg_contrast; }
BOOL UIAccessibilityIsReduceMotionEnabled(void) { return YES; }

BOOL SGRedesignedUI(void) { return YES; }
BOOL SGEnabled(NSString *key) { return [key isEqualToString:SGRKeyPlayerMusicIcons] ? sg_musicIcons : NO; }
BOOL SGFlag(NSString *key, BOOL fallback) { return fallback; }
NSInteger SGInt(NSString *key, NSInteger fallback) { return fallback; }
void SGRequireClasses(NSArray<NSString *> *names) {}
NSString *SGL(NSString *key, NSString *english) { return english; }

// The backdrop's reading: none, so the inks are the plain whites they are with no reading.
NSNotificationName const SGRBackdropInkDidChangeNotification = @"spotifyglass.redesign.backdropInkDidChange";
UIColor *SGRInkPlainColor(UIView *view, CGFloat floorAlpha, CGFloat add) { return [UIColor colorWithWhite:1 alpha:floorAlpha]; }

void SGRPlayerMotionLyricsChanged(void) {}
void SGRPlayerVisualiserUpdate(void) {}
void SGRShownTitleRestyle(void) {}
BOOL SGRPlayerLyricsAvailable(void) { return YES; }
BOOL SGRPlayerLyricsOpen(void) { return sg_lyricsOpen; }
BOOL SGRPlayerIsTransitioning(void) { return YES; }
BOOL SGRPlayerQueueShown(void) { return NO; }
void SGRPlayerToggleLyrics(void) {}
void SGRPlayerWatchLook(UIView *host) {}
// The row's other parts, which only the footer unit's layout pass (not run here) reaches.
UIColor *SGRAccentColor(void) { return nil; }
void SGForEachView(UIView *view, void (^fn)(UIView *)) {}
BOOL SGIsRow(UIView *view) { return NO; }
UIView *SGFindRemembered(UIView *root, const void *key, BOOL (^match)(UIView *view)) { return nil; }
BOOL SGLogFirst(NSMutableSet<NSString *> *__strong *logged, NSString *key) { return NO; }
void SGRPressGlyph(UIView *control, UIView *glyph, UIView *platterHost, CGFloat diameter, SGRPressOptions options) {}
void SGRVanish(UIView *view) {}
BOOL SGRObserveImage(UIImageView *view, void (^changed)(UIImageView *view)) { return NO; }
UIView *SGRFindByIdentifier(UIView *root, NSString *identifier, const void *cacheKey) { return nil; }
void SGRPlayerStackWithoutVolume(UIView *player, BOOL without) {}
BOOL SGRPlayerTwoColumns(void) { return NO; }
void SGRPlayerToggleQueueSide(void) {}
SGRPlayerQueueStyleKind SGRPlayerQueueStyle(void) { return (SGRPlayerQueueStyleKind)0; }
void SGRPlayerToggleQueuePage(void) {}
BOOL SGRPlayerVolumeOn(void) { return NO; }
BOOL SGRPlayerPlaceVolume(UIView *stack, UIView *controls, UIView *row, CGFloat margin, BOOL rhythm) { return NO; }
void SGRPlayerPaintCover(UIView *stack) {}
BOOL SGRPlayerAccentLike(UIColor *color) { return NO; }
UIColor *SGRPlayerImageInk(UIImage *image) { return nil; }
void SGRPlayerShowQueue(UIView *from) {}

#pragma mark - Spotify's glyph view, a stand-in

// Draws a filled shape in its foreground color, as Spotify's draws its icon: a tall bar for the microphone, a wide one
// for any other icon, switched in place by -harnessSetIcon:.
@interface SPTEncoreIcon : NSObject
@end
@implementation SPTEncoreIcon
+ (id)microphone { return @"microphone"; }
+ (id)queue { return @"queue"; }
@end

@implementation SPTEncoreIconView {
    CAShapeLayer *_shape;
    NSString *_icon;
    BOOL _active;
}
- (instancetype)initWithIcon:(id)icon {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _shape = [CAShapeLayer layer];
    [self.layer addSublayer:_shape];
    _icon = icon;
    self.foregroundColor = UIColor.whiteColor;
    return self;
}
- (void)harnessSetIcon:(NSString *)icon {
    _icon = icon;
    [self setNeedsLayout];
    [self layoutIfNeeded];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shape.frame = self.bounds;
    CGRect bounds = self.bounds;
    CGRect bar = [_icon isEqualToString:@"microphone"] ? CGRectInset(bounds, 5, 1) : CGRectInset(bounds, 1, 5);
    _shape.path = [UIBezierPath bezierPathWithRect:bar].CGPath;
    [CATransaction commit];
}
- (void)setForegroundColor:(UIColor *)color {
    _foregroundColor = color;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shape.fillColor = color.CGColor;
    [CATransaction commit];
}
- (void)setIsActive:(BOOL)active { _active = active; }
- (BOOL)isActive { return _active; }
@end

@interface _TtC20NowPlaying_ModesImpl18FooterElementsUnit : UIViewController
@end
@implementation _TtC20NowPlaying_ModesImpl18FooterElementsUnit
@end

#pragma mark - pixels

static const CGFloat kScale = 2;

typedef struct {
    int width, height;
    uint8_t *bytes;   // RGBA, premultiplied, opaque where it matters
} Pixels;

static Pixels pixelsOf(CGSize size, void (^draw)(CGContextRef context)) {
    Pixels p = {(int)(size.width * kScale), (int)(size.height * kScale), NULL};
    p.bytes = calloc((size_t)p.width * p.height * 4, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(p.bytes, p.width, p.height, 8, p.width * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    CGContextTranslateCTM(context, 0, p.height);
    CGContextScaleCTM(context, kScale, -kScale);
    UIGraphicsPushContext(context);
    draw(context);
    UIGraphicsPopContext();
    CGContextRelease(context);
    return p;
}

static const uint8_t *at(Pixels p, CGPoint point) {
    int x = (int)floor(point.x * kScale), y = (int)floor(point.y * kScale);
    if (x < 0 || y < 0 || x >= p.width || y >= p.height) HARNESS_FAIL(@"pixel %@ outside %dx%d", NSStringFromCGPoint(point), p.width, p.height);
    return p.bytes + ((size_t)y * p.width + x) * 4;
}

// The whole scene as it is drawn: the backdrop, the host and the button over it, the disc's mask included.
static Pixels scene(UIView *root) {
    [root layoutIfNeeded];
    return pixelsOf(root.bounds.size, ^(CGContextRef context) { [root.layer renderInContext:context]; });
}

// Where `drawn` covers in `root`, drawn alone in opaque black: the glyph's shape.
static Pixels shapeOf(UIView *drawn, UIView *root) {
    UIColor *tint = drawn.tintColor;
    CGFloat alpha = drawn.alpha;
    BOOL encore = [drawn isKindOfClass:SPTEncoreIconView.class];
    UIColor *foreground = encore ? ((SPTEncoreIconView *)drawn).foregroundColor : nil;
    if (encore) ((SPTEncoreIconView *)drawn).foregroundColor = UIColor.blackColor;
    else drawn.tintColor = UIColor.blackColor;
    drawn.alpha = 1;
    CGPoint origin = [root convertPoint:drawn.bounds.origin fromView:drawn];
    Pixels p = pixelsOf(root.bounds.size, ^(CGContextRef context) {
        CGContextTranslateCTM(context, origin.x, origin.y);
        [drawn.layer renderInContext:context];
    });
    if (encore) ((SPTEncoreIconView *)drawn).foregroundColor = foreground;
    else drawn.tintColor = tint;
    drawn.alpha = alpha;
    return p;
}

static BOOL covered(Pixels shape, int x, int y) {
    return x >= 0 && y >= 0 && x < shape.width && y < shape.height && shape.bytes[((size_t)y * shape.width + x) * 4 + 3] == 255;
}

// Any of the shape there, its antialiased edge included.
static BOOL touched(Pixels shape, int x, int y) {
    return x >= 0 && y >= 0 && x < shape.width && y < shape.height && shape.bytes[((size_t)y * shape.width + x) * 4 + 3] > 0;
}

// The middle of the hole: of the glyph's pixels, the one deepest inside its shape (every pixel within `depth` of it the
// glyph's too), nearest the glyph's middle; `outside`, when given, must not touch any of them.
static CGPoint holeMiddle(Pixels shape, Pixels *outside, CGPoint middle) {
    CGPoint best = CGPointZero;
    for (int depth = 1; depth < 12; depth++) {
        CGFloat bestDistance = CGFLOAT_MAX;
        BOOL found = NO;
        for (int y = 0; y < shape.height; y++) {
            for (int x = 0; x < shape.width; x++) {
                BOOL deep = YES;
                for (int dy = -depth; dy <= depth && deep; dy++)
                    for (int dx = -depth; dx <= depth && deep; dx++) {
                        if (!covered(shape, x + dx, y + dy)) deep = NO;
                        if (outside && touched(*outside, x + dx, y + dy)) deep = NO;
                    }
                if (!deep) continue;
                CGPoint point = CGPointMake((x + 0.5) / kScale, (y + 0.5) / kScale);
                CGFloat distance = hypot(point.x - middle.x, point.y - middle.y);
                if (distance < bestDistance) {
                    bestDistance = distance;
                    best = point;
                    found = YES;
                }
            }
        }
        if (!found) {
            if (depth == 1) HARNESS_FAIL(@"the glyph has no inside to sample");
            return best;
        }
    }
    return best;
}

// A point of the disc the glyph does not cover, for the disc's own color.
static CGPoint discPoint(Pixels shape, UIView *disc, UIView *root) {
    CGPoint middle = [root convertPoint:CGPointMake(CGRectGetMidX(disc.bounds), CGRectGetMidY(disc.bounds)) fromView:disc];
    for (CGFloat r = 10; r < 17; r += 0.5) {
        for (int step = 0; step < 32; step++) {
            CGFloat angle = step * M_PI / 16;
            CGPoint point = CGPointMake(middle.x + r * cos(angle), middle.y + r * sin(angle));
            BOOL clear = YES;
            int x = (int)floor(point.x * kScale), y = (int)floor(point.y * kScale);
            for (int dy = -3; dy <= 3 && clear; dy++)
                for (int dx = -3; dx <= 3 && clear; dx++) clear = !covered(shape, x + dx, y + dy) && shape.bytes[((size_t)(y + dy) * shape.width + x + dx) * 4 + 3] == 0;
            if (clear) return point;
        }
    }
    HARNESS_FAIL(@"no point of the disc clear of the glyph");
}

static void rgbOf(UIColor *color, CGFloat out[3]) {
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    out[0] = r * 255; out[1] = g * 255; out[2] = b * 255;
}

static NSString *described(const uint8_t *pixel) {
    return [NSString stringWithFormat:@"(%d, %d, %d)", pixel[0], pixel[1], pixel[2]];
}

static BOOL near(const uint8_t *pixel, const CGFloat want[3], CGFloat tolerance) {
    for (int c = 0; c < 3; c++) if (fabs(pixel[c] - want[c]) > tolerance) return NO;
    return YES;
}

static BOOL isBlack(const uint8_t *pixel) {
    return pixel[0] < 8 && pixel[1] < 8 && pixel[2] < 8;
}

// `ink` at `alpha` over `bg`.
static void over(const CGFloat bg[3], CGFloat ink, CGFloat alpha, CGFloat out[3]) {
    for (int c = 0; c < 3; c++) out[c] = (1 - alpha) * bg[c] + alpha * ink;
}

// Pixels of the disc's round, a point in from its edge, the backdrop's color must show at least this much (the glyph's
// shape); none of them black.
static void countDisc(Pixels p, UIView *disc, UIView *root, const CGFloat bg[3], int *black, int *backdrop, int *total) {
    CGPoint middle = [root convertPoint:CGPointMake(CGRectGetMidX(disc.bounds), CGRectGetMidY(disc.bounds)) fromView:disc];
    *black = *backdrop = *total = 0;
    for (int y = 0; y < p.height; y++) {
        for (int x = 0; x < p.width; x++) {
            CGFloat px = (x + 0.5) / kScale, py = (y + 0.5) / kScale;
            if (hypot(px - middle.x, py - middle.y) > disc.bounds.size.width / 2 - 1) continue;
            const uint8_t *pixel = p.bytes + ((size_t)y * p.width + x) * 4;
            (*total)++;
            if (isBlack(pixel)) (*black)++;
            if (near(pixel, bg, 3)) (*backdrop)++;
        }
    }
}

static void check(BOOL ok, NSString *what) {
    checked++;
    if (!ok) failed++;
    printf("%s %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    fflush(stdout);
}

#pragma mark - the checks

// The scene's pixel at `point` within `tolerance` of `want`.
static void pixelIs(UIView *root, CGPoint point, const CGFloat want[3], CGFloat tolerance, NSString *what) {
    Pixels p = scene(root);
    const uint8_t *pixel = at(p, point);
    check(near(pixel, want, tolerance), [NSString stringWithFormat:@"%@: %@ against (%.0f, %.0f, %.0f)", what, described(pixel), want[0], want[1], want[2]]);
    free(p.bytes);
}


static UIView *discOf(SGRGlyphButton *button) {
    for (UIView *view in button.subviews) {
        if (view != button.glyph && ![view isKindOfClass:SPTEncoreIconView.class] && view.bounds.size.width == 38) return view;
    }
    return nil;
}

static SPTEncoreIconView *encoreOf(SGRGlyphButton *button) {
    for (UIView *view in button.subviews) if ([view isKindOfClass:SPTEncoreIconView.class]) return (SPTEncoreIconView *)view;
    return nil;
}

// A new reading of the backdrop, which the footer takes on the next turn of the main queue (refreshFooterInk).
static void newReading(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGRBackdropInkDidChangeNotification object:nil];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

static BOOL holeShowsBackdrop(UIView *root, UIView *drawn, UIView *disc, CGPoint hole, UIColor *backdrop, NSString *label) {
    root.backgroundColor = backdrop;
    CGFloat bg[3], discWant[3];
    rgbOf(backdrop, bg);
    over(bg, 255, 0.46, discWant);
    Pixels p = scene(root), shape = shapeOf(drawn, root);
    CGPoint inDisc = discPoint(shape, disc, root);
    const uint8_t *pixel = at(p, hole), *discPixel = at(p, inDisc);
    int black, shown, total;
    countDisc(p, disc, root, bg, &black, &shown, &total);
    BOOL ok = near(pixel, bg, 3) && !isBlack(pixel);
    check(ok, [NSString stringWithFormat:@"%@: the hole's middle %@ is the backdrop %@, not black", label, described(pixel),
                                         described((uint8_t[3]){(uint8_t)bg[0], (uint8_t)bg[1], (uint8_t)bg[2]})]);
    check(near(discPixel, discWant, 4), [NSString stringWithFormat:@"%@: the disc %@ is the rest ink over the backdrop (%.0f, %.0f, %.0f)",
                                                                   label, described(discPixel), discWant[0], discWant[1], discWant[2]]);
    check(black == 0 && shown > total / 20, [NSString stringWithFormat:@"%@: of the disc's %d pixels %d show the backdrop, %d black",
                                                                       label, total, shown, black]);
    free(p.bytes);
    free(shape.bytes);
    return ok;
}

static void runChecks(UIWindow *window) {
    UIColor *blue = [UIColor colorWithRed:0 green:44 / 255.0 blue:69 / 255.0 alpha:1];
    UIColor *gray = [UIColor colorWithRed:53 / 255.0 green:53 / 255.0 blue:53 / 255.0 alpha:1];
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 100)];
    root.backgroundColor = blue;
    [window.rootViewController.view addSubview:root];
    UIView *host = [[UIView alloc] initWithFrame:root.bounds];
    [root addSubview:host];

    SGRGlyphButton *lyrics = SGRPlayerLyricsGlyphIn(host);
    lyrics.bounds = CGRectMake(0, 0, 44, 44);
    lyrics.center = CGPointMake(100, 50);
    [root layoutIfNeeded];
    UIColor *rest = [UIColor colorWithWhite:1 alpha:0.46];

    // 1. On: masked, no filter, no group.
    sg_lyricsOpen = YES;
    SGRPlayerLyricsChanged();
    [root layoutIfNeeded];
    newReading();
    UIView *disc = discOf(lyrics);
    HARNESS_CHECK(disc != nil);
    check(disc.alpha == 1, [NSString stringWithFormat:@"on: the disc shows (alpha %.2f)", disc.alpha]);
    check(lyrics.glyph.layer.compositingFilter == nil && lyrics.layer.compositingFilter == nil && disc.layer.compositingFilter == nil,
          @"on: nothing is drawn with a compositing filter");
    check(disc.layer.mask != nil && disc.layer.mask.contents != nil, @"on: the disc is masked by a picture of the glyph");
    SEL group = NSSelectorFromString(@"allowsGroupBlending");
    BOOL grouped = [lyrics.layer respondsToSelector:group] && !((BOOL (*)(id, SEL))objc_msgSend)(lyrics.layer, group);
    check(!grouped, @"on: the button's layer keeps group blending");
    check([lyrics.glyph.tintColor isEqual:UIColor.clearColor], @"on: the glyph is clear over the disc");

    // 2. Over the blue and the gray backdrop.
    CGPoint middle = [root convertPoint:CGPointMake(CGRectGetMidX(lyrics.glyph.bounds), CGRectGetMidY(lyrics.glyph.bounds)) fromView:lyrics.glyph];
    Pixels shape = shapeOf(lyrics.glyph, root);
    CGPoint hole = holeMiddle(shape, NULL, middle);
    free(shape.bytes);
    holeShowsBackdrop(root, lyrics.glyph, disc, hole, blue, @"blue");
    holeShowsBackdrop(root, lyrics.glyph, disc, hole, gray, @"gray");

    // 3. Pressed: the hole fills back in to 0.4 of the disc, through a new reading, and clears on release.
    for (UIColor *backdrop in @[blue, gray]) {
        root.backgroundColor = backdrop;
        CGFloat bg[3], pressedWant[3];
        rgbOf(backdrop, bg);
        over(bg, 255, 0.46 * (1 - 0.6), pressedWant);
        NSString *name = backdrop == blue ? @"blue" : @"gray";
        lyrics.highlighted = YES;
        Pixels p = scene(root);
        const uint8_t *pixel = at(p, hole);
        check(near(pixel, pressedWant, 4), [NSString stringWithFormat:@"%@ pressed: the hole %@ holds 0.4 of the disc (%.0f, %.0f, %.0f)",
                                                                      name, described(pixel), pressedWant[0], pressedWant[1], pressedWant[2]]);
        free(p.bytes);
        newReading();
        p = scene(root);
        pixel = at(p, hole);
        check(near(pixel, pressedWant, 4), [NSString stringWithFormat:@"%@ pressed, a new reading: the hole stays %@", name, described(pixel)]);
        free(p.bytes);
        lyrics.highlighted = NO;
        p = scene(root);
        pixel = at(p, hole);
        check(near(pixel, bg, 3), [NSString stringWithFormat:@"%@ released: the hole %@ is the backdrop again", name, described(pixel)]);
        free(p.bytes);
    }

    // 4. Increase Contrast: the disc whole, the glyph black on it; off again, the hole back.
    root.backgroundColor = blue;
    sg_contrast = YES;
    newReading();
    {
        Pixels p = scene(root);
        const uint8_t *pixel = at(p, hole);
        check(isBlack(pixel) && [lyrics.glyph.tintColor isEqual:UIColor.blackColor],
              [NSString stringWithFormat:@"contrast: the glyph is black on the disc %@", described(pixel)]);
        check(disc.layer.mask.contents == nil && disc.layer.mask.cornerRadius == 19, @"contrast: the mask is the whole round");
        Pixels s = shapeOf(lyrics.glyph, root);
        const uint8_t *white = at(p, discPoint(s, disc, root));
        check(white[0] > 250 && white[1] > 250 && white[2] > 250, [NSString stringWithFormat:@"contrast: the disc is white %@", described(white)]);
        free(s.bytes);
        free(p.bytes);
        lyrics.highlighted = YES;
        p = scene(root);
        pixel = at(p, hole);
        check(pixel[0] > 100 && pixel[0] < 160 && pixel[1] > 100 && pixel[1] < 160,
              [NSString stringWithFormat:@"contrast pressed: the black glyph dims to %@", described(pixel)]);
        free(p.bytes);
        lyrics.highlighted = NO;
    }
    sg_contrast = NO;
    newReading();
    check(disc.layer.mask.contents != nil && [lyrics.glyph.tintColor isEqual:UIColor.clearColor], @"contrast off: the cut mask is back");
    holeShowsBackdrop(root, lyrics.glyph, disc, hole, blue, @"contrast off, blue");

    // 5. Off: the disc gone, the glyph in the rest ink.
    sg_lyricsOpen = NO;
    SGRPlayerLyricsChanged();
    check(disc.alpha == 0, [NSString stringWithFormat:@"off: the disc is gone (alpha %.2f)", disc.alpha]);
    check([lyrics.glyph.tintColor isEqual:rest], [NSString stringWithFormat:@"off: the glyph is in the rest ink %@", lyrics.glyph.tintColor]);
    {
        CGFloat bg[3];
        rgbOf(blue, bg);
        Pixels p = scene(root);
        const uint8_t *pixel = at(p, hole);
        check(near(pixel, bg, 3), [NSString stringWithFormat:@"off: no disc over the backdrop at the hole %@", described(pixel)]);
        free(p.bytes);
    }

    // 6. Spotify's Encore glyph, Music app icons off.
    sg_musicIcons = NO;
    newReading();
    SPTEncoreIconView *encore = encoreOf(lyrics);
    HARNESS_CHECK(encore != nil);
    check(lyrics.glyph.hidden, @"encore: the symbol gives way to Spotify's glyph");
    check([encore.foregroundColor isEqual:rest], @"encore off: Spotify's glyph is in the rest ink");
    sg_lyricsOpen = YES;
    SGRPlayerLyricsChanged();
    newReading();
    check(disc.alpha == 1 && [encore.foregroundColor isEqual:UIColor.clearColor] && encore.layer.compositingFilter == nil,
          @"encore on: the disc shows, Spotify's glyph clear with no filter");
    CGPoint encoreMiddle = [root convertPoint:CGPointMake(CGRectGetMidX(encore.bounds), CGRectGetMidY(encore.bounds)) fromView:encore];
    Pixels tall = shapeOf(encore, root);
    CGPoint tallHole = holeMiddle(tall, NULL, encoreMiddle);
    holeShowsBackdrop(root, encore, disc, tallHole, blue, @"encore, blue");
    holeShowsBackdrop(root, encore, disc, tallHole, gray, @"encore, gray");
    // A new icon in the same view: the new shape is the hole, the old one's place filled with the disc.
    [encore harnessSetIcon:@"queue"];
    newReading();
    Pixels wide = shapeOf(encore, root);
    CGPoint wideHole = holeMiddle(wide, &tall, CGPointMake(encoreMiddle.x + 7, encoreMiddle.y));
    {
        root.backgroundColor = blue;
        CGFloat bg[3], discWant[3];
        rgbOf(blue, bg);
        over(bg, 255, 0.46, discWant);
        Pixels p = scene(root);
        const uint8_t *newHole = at(p, wideHole);
        check(near(newHole, bg, 3), [NSString stringWithFormat:@"encore, new icon: its hole %@ is the backdrop", described(newHole)]);
        CGPoint oldOnly = CGPointMake(encoreMiddle.x, encoreMiddle.y - 6.5);
        const uint8_t *oldHole = at(p, oldOnly);
        check(near(oldHole, discWant, 4), [NSString stringWithFormat:@"encore, new icon: the last icon's place %@ is the disc again", described(oldHole)]);
        free(p.bytes);
    }
    free(tall.bytes);
    root.backgroundColor = blue;
    CGFloat blueBg[3], bluePressed[3], blueDisc[3];
    rgbOf(blue, blueBg);
    over(blueBg, 255, 0.46 * (1 - 0.6), bluePressed);
    over(blueBg, 255, 0.46, blueDisc);

    // Pressed, Spotify's glyph is at kFooterPressedAlpha: a new reading then draws its shape opaque all the same, so
    // neither mask is cut at 0.6 and the hole clears fully on release.
    lyrics.highlighted = YES;
    pixelIs(root, wideHole, bluePressed, 4, @"encore pressed: the hole holds 0.4 of the disc");
    newReading();
    pixelIs(root, wideHole, bluePressed, 4, @"encore pressed, a new reading: the hole stays");
    check(fabs(encore.alpha - 0.6) < 0.01 && [encore.foregroundColor isEqual:UIColor.clearColor],
          [NSString stringWithFormat:@"encore pressed, a new reading: Spotify's glyph keeps its alpha %.2f and its clear", encore.alpha]);
    lyrics.highlighted = NO;
    pixelIs(root, wideHole, blueBg, 3, @"encore released: the hole is the backdrop again");
    newReading();
    pixelIs(root, wideHole, blueBg, 3, @"encore released, a new reading: the hole is still the backdrop");

    // Increase Contrast on and off with Spotify's glyph up.
    sg_contrast = YES;
    newReading();
    check([encore.foregroundColor isEqual:UIColor.blackColor] && disc.layer.mask.contents == nil, @"encore contrast: Spotify's glyph black on the whole disc");
    {
        Pixels p = scene(root);
        const uint8_t *pixel = at(p, wideHole);
        check(isBlack(pixel), [NSString stringWithFormat:@"encore contrast: the glyph %@ is black", described(pixel)]);
        free(p.bytes);
    }
    sg_contrast = NO;
    newReading();
    check([encore.foregroundColor isEqual:UIColor.clearColor] && disc.layer.mask.contents != nil, @"encore contrast off: Spotify's glyph clear, the cut mask back");
    pixelIs(root, wideHole, blueBg, 3, @"encore contrast off: the hole is the backdrop");

    // Music app icons on and off again with the lyrics up: each glyph's own hole, the other's place the disc.
    sg_musicIcons = YES;
    newReading();
    check(!lyrics.glyph.hidden && encore.superview == nil, @"music icons on: the symbol is back, Spotify's glyph out");
    Pixels symbolShape = shapeOf(lyrics.glyph, root);
    CGPoint symbolOnly = holeMiddle(symbolShape, &wide, middle);
    CGPoint encoreOnly = holeMiddle(wide, &symbolShape, encoreMiddle);
    pixelIs(root, symbolOnly, blueBg, 3, @"music icons on: the symbol's hole is the backdrop");
    pixelIs(root, encoreOnly, blueDisc, 4, @"music icons on: Spotify's glyph's place is the disc");
    sg_musicIcons = NO;
    newReading();
    check(lyrics.glyph.hidden && encore.superview == lyrics, @"music icons off: Spotify's glyph is back");
    pixelIs(root, encoreOnly, blueBg, 3, @"music icons off: Spotify's glyph's hole is the backdrop");
    pixelIs(root, symbolOnly, blueDisc, 4, @"music icons off: the symbol's place is the disc");
    free(symbolShape.bytes);
    free(wide.bytes);

    // Spotify's glyph not sized yet: nothing drawn, no crash; sized, the hole again.
    CGRect encoreBounds = encore.bounds;
    encore.bounds = CGRectZero;
    newReading();
    check(disc.layer.mask.contents == nil, @"encore unsized: no mask drawn for an empty glyph");
    encore.bounds = encoreBounds;
    [encore layoutIfNeeded];
    newReading();
    check(disc.layer.mask.contents != nil, @"encore sized again: the mask is drawn");
    pixelIs(root, wideHole, blueBg, 3, @"encore sized again: the hole is the backdrop");

    sg_lyricsOpen = NO;
    SGRPlayerLyricsChanged();
    check(disc.alpha == 0 && [encore.foregroundColor isEqual:rest], @"encore off again: the disc gone, Spotify's glyph in the rest ink");

    [root removeFromSuperview];
    printf("%d checks, %d failed\n", checked, failed);
    fflush(stdout);
    if (failed) HARNESS_FAIL(@"%d footer disc checks failed", failed);
    exit(0);
}

@interface FooterDiscApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation FooterDiscApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 402, 874)];
    self.window.rootViewController = [UIViewController new];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.window makeKeyAndVisible];
    // From a timer, not the main queue: a block of the main queue would hold back the footer's own dispatch_async to it
    // (refreshFooterInk on a new reading) until it returned.
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *timer) { runChecks(self.window); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HARNESS_FAIL(@"footer disc checks did not finish");
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(FooterDiscApp.class)); }
}
