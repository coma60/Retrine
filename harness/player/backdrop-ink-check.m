// The player's ink in the backdrop's hue (SGRBackdropInk.h, issue #82 F1), the complete SGRRestyle.m on Mac Catalyst:
//  - SGRInkSolve: a plain color that lands where light ADDED to the backdrop (plusL) does, min(1, backdrop + add) in each
//    channel, over the backdrops measured beside the Music app (Coldplay's blue sky), and white at the alpha it always
//    was over black and over a gray (Wish You Were Here);
//  - the field read in color: a source view of a solid color is read behind a view over it, its lightness as before
//    (the details popover's light glass reads it, SGRBackdropLightnessBehind), and a change of hue at the same lightness
//    is reported to the observers;
//  - with no reading, and under Increase Contrast, the inks are the plain whites they were.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "../harness-fail.h"

static int checked, failed;
static BOOL contrast;

BOOL SGRedesignedUI(void) { return YES; }
BOOL SGFlag(NSString *key, BOOL fallback) { return fallback; }
NSInteger SGInt(NSString *key, NSInteger fallback) { return fallback; }
void SGPresentDark(UIViewController *controller) {}
UIColor *SGRAccentColor(void) { return nil; }
// Increase Contrast, switched by the check: SGRRestyle.m linked into this executable calls this one, not UIKit's.
BOOL UIAccessibilityDarkerSystemColorsEnabled(void) { return contrast; }

static void check(BOOL ok, NSString *what) {
    checked++;
    if (!ok) failed++;
    printf("%s %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    fflush(stdout);
}

static NSString *triple(const CGFloat c[3]) {
    return [NSString stringWithFormat:@"(%.0f, %.0f, %.0f)", c[0] * 255, c[1] * 255, c[2] * 255];
}

// What `ink` at `alpha` drawn plainly over `bg` comes to.
static void over(const CGFloat bg[3], const CGFloat ink[3], CGFloat alpha, CGFloat out[3]) {
    for (int c = 0; c < 3; c++) out[c] = (1 - alpha) * bg[c] + alpha * ink[c];
}

static BOOL lands(const CGFloat out[3], const CGFloat bg[3], CGFloat add, CGFloat tolerance) {
    for (int c = 0; c < 3; c++) if (fabs(out[c] - MIN(1, bg[c] + add)) > tolerance) return NO;
    return YES;
}

static CGFloat saturation(const CGFloat c[3]) {
    CGFloat most = MAX(c[0], MAX(c[1], c[2])), least = MIN(c[0], MIN(c[1], c[2]));
    return most > 0 ? (most - least) / most : 0;
}

static void colorOf(UIColor *color, CGFloat rgb[3], CGFloat *alpha) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0;
        [color getWhite:&white alpha:&a];
        r = g = b = white;
    }
    rgb[0] = r, rgb[1] = g, rgb[2] = b;
    if (alpha) *alpha = a;
}

static void runSolve(void) {
    // Measured on feat1.png (Retrine left, the Music app right, 3x): the Music app's progress fill stood at
    // (154, 210, 251) over (46, 95, 145), +108/+115/+106; Retrine's plain white of 0.6 at (167, 191, 208) over (29, 92, 136).
    const CGFloat blue[3] = {46 / 255.0, 95 / 255.0, 145 / 255.0}, music[3] = {154 / 255.0, 210 / 255.0, 251 / 255.0};
    const CGFloat black[3] = {0, 0, 0}, gray[3] = {0.5, 0.5, 0.5}, light[3] = {184 / 255.0, 184 / 255.0, 184 / 255.0};
    const CGFloat white[3] = {1, 1, 1}, darkBlue[3] = {0.05, 0.10, 0.20};
    CGFloat ink[3], a, out[3];

    // Blue: the progress fill (0.44 added, floor 0.6, steps of 0.05) lands on plusL's result, in the sky's hue.
    SGRInkSolve(blue, 0.44, 0.6, 0.05, ink, &a);
    over(blue, ink, a, out);
    CGFloat plainWhite[3], whiteInk[3] = {1, 1, 1};
    over(blue, whiteInk, 0.6, plainWhite);
    BOOL near = fabs(out[0] - music[0]) < 0.03 && fabs(out[1] - music[1]) < 0.03 && fabs(out[2] - music[2]) < 0.03;
    check(lands(out, blue, 0.44, 0.005) && near && saturation(out) > 0.3 && saturation(plainWhite) < 0.2,
          [NSString stringWithFormat:@"blue backdrop %@: the fill lands on plusL's %@, the Music app's %@ (ink %@ at %.2f, "
           "saturation %.2f; plain white of 0.6 %@, saturation %.2f)", triple(blue), triple(out), triple(music), triple(ink), a,
           saturation(out), triple(plainWhite), saturation(plainWhite)]);

    // Blue: the times (0.265, no floor, no steps) and the track (0.175 over floor 0.2) land too.
    SGRInkSolve(blue, 0.265, 0, 0, ink, &a);
    over(blue, ink, a, out);
    check(lands(out, blue, 0.265, 0.001) && a < 1, [NSString stringWithFormat:@"blue backdrop: the times land on %@ at alpha %.2f (ink %@)",
                                                    triple(out), a, triple(ink)]);
    SGRInkSolve(blue, 0.175, 0.2, 0.05, ink, &a);
    over(blue, ink, a, out);
    check(lands(out, blue, 0.175, 0.005), [NSString stringWithFormat:@"blue backdrop: the track lands on %@ at alpha %.2f", triple(out), a]);

    // Black: white at the alpha it always was (the floor where the floor is above the added light).
    SGRInkSolve(black, 0.44, 0.6, 0.05, ink, &a);
    check(ink[0] == 1 && ink[1] == 1 && ink[2] == 1 && fabs(a - 0.6) < 1e-9,
          [NSString stringWithFormat:@"black backdrop: the fill is white of 0.60 as before (ink %@ at %.2f)", triple(ink), a]);
    SGRInkSolve(black, 0.265, 0, 0, ink, &a);
    check(ink[0] == 1 && ink[1] == 1 && ink[2] == 1 && fabs(a - 0.265) < 1e-9,
          [NSString stringWithFormat:@"black backdrop: the times are white of 0.265 as before (ink %@ at %.3f)", triple(ink), a]);

    // A dark blue under the floor: the floor's alpha, the ink white in its brightest channel and tinted no further.
    SGRInkSolve(darkBlue, 0.44, 0.6, 0.05, ink, &a);
    check(fabs(a - 0.6) < 1e-9 && ink[2] == 1 && ink[0] > 0.8, [NSString stringWithFormat:@"dark blue backdrop: the fill at the floor's 0.60, ink %@", triple(ink)]);

    // Gray: white at the alpha the lightness asked before, add / (1 - lightness), and landing on plusL's result.
    SGRInkSolve(gray, 0.265, 0, 0, ink, &a);
    check(ink[0] == 1 && ink[1] == 1 && ink[2] == 1 && fabs(a - 0.265 / 0.5) < 1e-9,
          [NSString stringWithFormat:@"gray backdrop: the times are white of %.3f as before (ink %@ at %.3f)", 0.265 / 0.5, triple(ink), a]);
    SGRInkSolve(light, 0.44, 0.6, 0.05, ink, &a);
    over(light, ink, a, out);
    check(lands(out, light, 0.44, 0.005) && fabs(ink[0] - ink[1]) < 1e-9 && fabs(ink[1] - ink[2]) < 1e-9,
          [NSString stringWithFormat:@"Wish You Were Here's gray %@: the fill neutral, at %@ (alpha %.2f)", triple(light), triple(out), a]);

    // White: white, opaque.
    SGRInkSolve(white, 0.265, 0, 0, ink, &a);
    check(ink[0] == 1 && ink[1] == 1 && ink[2] == 1 && a == 1, [NSString stringWithFormat:@"white backdrop: opaque white (%.2f)", a]);

    // Boundary and degenerate inputs: never NaN, alpha stays in [0, 1], NULL alpha is safe, and small add over near-white is exact.
    SGRInkSolve(black, 0, 1.5, 0.05, ink, &a);
    check(ink[0] == 1 && ink[1] == 1 && ink[2] == 1 && a == 1,
          [NSString stringWithFormat:@"add == 0 with floorAlpha > 1 clamps alpha to 1 (%.2f)", a]);
    SGRInkSolve(blue, -0.2, 1.2, 0.05, ink, &a);
    check(ink[0] == 1 && ink[1] == 1 && ink[2] == 1 && a == 1,
          [NSString stringWithFormat:@"negative add with floorAlpha > 1 clamps alpha to 1 (%.2f)", a]);
    SGRInkSolve(blue, 0.44, 0.2, INFINITY, ink, &a);
    over(blue, ink, a, out);
    check(isfinite(a) && a >= 0 && a <= 1 && lands(out, blue, 0.44, 0.001),
          [NSString stringWithFormat:@"step == +INFINITY stays finite and lands on %@ at %.2f", triple(out), a]);
    const CGFloat nanBg[3] = {NAN, 0.5, INFINITY};
    SGRInkSolve(nanBg, NAN, NAN, NAN, ink, &a);
    check(isfinite(ink[0]) && isfinite(ink[1]) && isfinite(ink[2]) && isfinite(a) && a == 0,
          [NSString stringWithFormat:@"NaN/Inf inputs stay finite (%@ at %.2f)", triple(ink), a]);
    SGRInkSolve(blue, 0.44, 0.6, 0.05, ink, NULL);
    check(isfinite(ink[0]) && isfinite(ink[1]) && isfinite(ink[2]), @"NULL alpha output pointer is safe");
    const CGFloat nearWhite[3] = {0.98, 0.98, 0.98};
    SGRInkSolve(nearWhite, 0.01, 0, 0, ink, &a);
    over(nearWhite, ink, a, out);
    check(lands(out, nearWhite, 0.01, 1e-6) && fabs(a - 0.5) < 1e-6,
          [NSString stringWithFormat:@"near-white 0.98 + 0.01 lands exactly at alpha %.3f", a]);

    // Every backdrop on a grid (with and without a floor): the ink lands on plusL's result within a step's rounding, alpha in 0...1.
    BOOL all = YES;
    NSString *worst = @"";
    for (int r = 0; r <= 10 && all; r++) for (int g = 0; g <= 10 && all; g++) for (int b = 0; b <= 10 && all; b++) {
        CGFloat bg[3] = {r / 10.0, g / 10.0, b / 10.0};
        for (NSNumber *add in @[@0.175, @0.265, @0.44, @0.55]) {
            SGRInkSolve(bg, add.doubleValue, 0, 0.05, ink, &a);
            over(bg, ink, a, out);
            if (!lands(out, bg, add.doubleValue, 0.002) || a < 0 || a > 1) {
                all = NO;
                worst = [NSString stringWithFormat:@"%@ + %@ came to %@ at %.2f", triple(bg), add, triple(out), a];
            }
            SGRInkSolve(bg, add.doubleValue, 0.6, 0.05, ink, &a);
            if (!isfinite(a) || a < 0.6 - 1e-9 || a > 1 || !isfinite(ink[0]) || !isfinite(ink[1]) || !isfinite(ink[2])) {
                all = NO;
                worst = [NSString stringWithFormat:@"floor 0.6 on %@ + %@ gave %@ at %.2f", triple(bg), add, triple(ink), a];
            }
        }
    }
    check(all, [NSString stringWithFormat:@"a grid of backdrops: every ink lands on plusL's result %@", worst]);
}

// A solid source, the player's field, with the ink's views over it.
static UIView *sg_source;
static int sg_reports;
static void (^sg_onReport)(void);

static void after(NSTimeInterval seconds, void (^block)(void)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void waitNextReport(int afterCount, void (^block)(void)) {
    if (sg_reports > afterCount) {
        dispatch_async(dispatch_get_main_queue(), block);
        return;
    }
    __block BOOL fired = NO;
    sg_onReport = ^{
        if (fired || sg_reports <= afterCount) return;
        fired = YES;
        void (^next)(void) = block;
        sg_onReport = nil;
        dispatch_async(dispatch_get_main_queue(), next);
    };
}

static void finish(void) {
    SGRBackdropInkSetSource(nil);
    printf("backdrop ink checks: %d of %d right -- %s\n", checked - failed, checked, failed ? "FAIL" : "PASS");
    fflush(stdout);
    exit(failed ? 1 : 0);
}

static void runField(UIWindow *window) {
    sg_source = [[UIView alloc] initWithFrame:window.bounds];
    sg_source.backgroundColor = [UIColor colorWithRed:46 / 255.0 green:95 / 255.0 blue:145 / 255.0 alpha:1];
    [window.rootViewController.view addSubview:sg_source];
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(32, window.bounds.size.height * 0.65, window.bounds.size.width - 64, 8)];
    [sg_source addSubview:bar];
    UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(32, window.bounds.size.height * 0.15, window.bounds.size.width - 64, 8)];
    [sg_source addSubview:topBar];
    UIView *offWindow = [UIView new];

    // No reading yet (and a view in no window): the whites they were, and plusL is set to NO.
    CGFloat rgb[3], a;
    BOOL plusL = YES;
    UIColor *beforeColor = SGRInkFor(bar, 0.265, 0.85, &plusL);
    colorOf(beforeColor, rgb, &a);
    BOOL whiteBefore = !plusL && rgb[0] == 1 && rgb[1] == 1 && rgb[2] == 1 && fabs(a - 0.265) < 1e-6;
    colorOf(SGRInkPlainColor(offWindow, 0.6, 0.44), rgb, &a);
    check(whiteBefore && rgb[0] == 1 && rgb[1] == 1 && rgb[2] == 1 && fabs(a - 0.6) < 1e-6 && SGRBackdropLightnessBehind(bar) == -1,
          @"no reading: SGRInkFor white of 0.265 (plusL=NO), SGRInkPlainColor white of its floor, no lightness (-1)");

    __weak UIView *weakBar = bar;
    SGRBackdropInkObserve(bar, ^{
        if (!weakBar) return;
        sg_reports++;
        if (sg_onReport) sg_onReport();
    });
    SGRBackdropInkSetSource(sg_source);
    waitNextReport(0, ^{
        CGFloat behind[3];
        BOOL read = SGRBackdropColorBehind(bar, behind);
        CGFloat lightness = SGRBackdropLightnessBehind(bar);
        CGFloat luma = 0.299 * 46 / 255.0 + 0.587 * 95 / 255.0 + 0.114 * 145 / 255.0;
        check(read && fabs(behind[0] - 46 / 255.0) < 0.02 && fabs(behind[1] - 95 / 255.0) < 0.02 && fabs(behind[2] - 145 / 255.0) < 0.02
              && fabs(lightness - luma) < 0.02 && sg_reports >= 1,
              [NSString stringWithFormat:@"the field read in color: %@ behind the bar, lightness %.3f (luma %.3f), %d report(s)",
               read ? triple(behind) : @"none", lightness, luma, sg_reports]);

        // The bar's fill drawn over what was read lands on plusL's result, in the sky's hue.
        CGFloat ink[3], drawn[3], out[3], a1;
        UIColor *fillOverBlue = SGRInkPlainColor(bar, 0.6, 0.44);
        colorOf(fillOverBlue, ink, &a1);
        over(behind, ink, a1, out);
        check(lands(out, behind, 0.44, 0.02) && saturation(out) > 0.3,
              [NSString stringWithFormat:@"the fill over the blue field: %@ at %.2f comes to %@, plusL's", triple(ink), a1, triple(out)]);
        BOOL plusLBlue = YES;
        colorOf(SGRInkFor(bar, 0.265, 0.85, &plusLBlue), drawn, &a1);
        over(behind, drawn, a1, out);
        check(!plusLBlue && lands(out, behind, 0.265, 0.002), [NSString stringWithFormat:@"the times over the blue field come to %@ (plusL=%d)", triple(out), plusLBlue]);

        // Increase Contrast: the plain whites, whatever is behind.
        contrast = YES;
        colorOf(SGRInkPlainColor(bar, 0.85, 0.44), ink, &a1);
        contrast = NO;
        check(ink[0] == 1 && ink[1] == 1 && ink[2] == 1 && fabs(a1 - 0.85) < 1e-6,
              [NSString stringWithFormat:@"Increase Contrast: SGRInkPlainColor is white of its floor (%@ at %.2f)", triple(ink), a1]);

        // A tiny drift under kInkReportDelta (0.02) does not fire a report and keeps SGRInkPlainColor equal.
        int steadyCount = sg_reports;
        sg_source.backgroundColor = [UIColor colorWithRed:47 / 255.0 green:96 / 255.0 blue:146 / 255.0 alpha:1];
        after(0.6, ^{
            check(sg_reports == steadyCount && [SGRInkPlainColor(bar, 0.6, 0.44) isEqual:fillOverBlue],
                  [NSString stringWithFormat:@"sub-delta drift: reports stayed %d -> %d, plain color equal", steadyCount, sg_reports]);

            // A change of hue at the same lightness (luma within the report's 0.02) is a change of ink: reported, and the ink follows.
            int before = sg_reports;
            sg_source.backgroundColor = [UIColor colorWithRed:0.52 green:0.245 blue:0.33 alpha:1];
            waitNextReport(before, ^{
                CGFloat now[3], ink2[3], out2[3], a2;
                SGRBackdropColorBehind(bar, now);
                colorOf(SGRInkPlainColor(bar, 0.6, 0.44), ink2, &a2);
                over(now, ink2, a2, out2);
                check(sg_reports > before && now[0] > now[2] && lands(out2, now, 0.44, 0.02) && fabs(SGRBackdropLightnessBehind(bar) - luma) < 0.02,
                      [NSString stringWithFormat:@"a rose field of the same lightness (%.3f): reported (%d to %d), the fill now %@",
                       SGRBackdropLightnessBehind(bar), before, sg_reports, triple(out2)]);

                // Split field (top blue, bottom red): readBehind samples the region behind each view (y orientation).
                int beforeSplit = sg_reports;
                UIView *topHalf = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sg_source.bounds.size.width, sg_source.bounds.size.height / 2)];
                topHalf.backgroundColor = [UIColor colorWithRed:0.1 green:0.2 blue:0.8 alpha:1];
                UIView *bottomHalf = [[UIView alloc] initWithFrame:CGRectMake(0, sg_source.bounds.size.height / 2, sg_source.bounds.size.width, sg_source.bounds.size.height / 2)];
                bottomHalf.backgroundColor = [UIColor colorWithRed:0.8 green:0.15 blue:0.15 alpha:1];
                [sg_source insertSubview:topHalf atIndex:0];
                [sg_source insertSubview:bottomHalf atIndex:1];
                waitNextReport(beforeSplit, ^{
                    CGFloat topRGB[3], botRGB[3];
                    SGRBackdropColorBehind(topBar, topRGB);
                    SGRBackdropColorBehind(bar, botRGB);
                    check(topRGB[2] > 0.6 && topRGB[0] < 0.25 && botRGB[0] > 0.6 && botRGB[2] < 0.25,
                          [NSString stringWithFormat:@"split field: top %@ (blue), bottom %@ (red)", triple(topRGB), triple(botRGB)]);
                    [topHalf removeFromSuperview];
                    [bottomHalf removeFromSuperview];

                    // Black field: SGRInkFor returns a color equal to the pre-reading white fallback.
                    int beforeBlack = sg_reports;
                    sg_source.backgroundColor = UIColor.blackColor;
                    waitNextReport(beforeBlack, ^{
                        UIColor *blackInk = SGRInkFor(bar, 0.265, 0.85, NULL);
                        check([blackInk isEqual:beforeColor], @"black field: SGRInkFor matches pre-reading white color space and value");

                        // Gray: the field read neutral, the fill as white as it was (SGRInkPlainAlpha's alpha).
                        int beforeGray = sg_reports;
                        sg_source.backgroundColor = [UIColor colorWithWhite:184 / 255.0 alpha:1];
                        waitNextReport(beforeGray, ^{
                            CGFloat ink3[3], a3;
                            colorOf(SGRInkPlainColor(bar, 0.6, 0.44), ink3, &a3);
                            CGFloat legacy = SGRInkPlainAlpha(bar, 0.6, 0.44);
                            CGFloat behind3[3], out3[3], legacyOut[3], whiteInk[3] = {1, 1, 1};
                            SGRBackdropColorBehind(bar, behind3);
                            over(behind3, ink3, a3, out3);
                            over(behind3, whiteInk, legacy, legacyOut);
                            check(fabs(ink3[0] - ink3[1]) < 1e-6 && fabs(ink3[1] - ink3[2]) < 1e-6 && fabs(out3[0] - legacyOut[0]) < 0.03,
                                  [NSString stringWithFormat:@"a gray field: the fill neutral, %@ against the white of %.2f's %@", triple(out3), legacy, triple(legacyOut)]);
                            finish();
                        });
                    });
                });
            });
        });
    });
}

@interface BackdropInkApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation BackdropInkApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 402, 874)];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    runSolve();
    // Readings start once the app is active and the source draws.
    after(0.5, ^{ runField(self.window); });
    after(30, ^{ HARNESS_FAIL(@"backdrop ink checks did not finish"); });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(BackdropInkApp.class)); }
}
