// The player clip's lifecycle (issue #82), with production code from PlayerField.x and PlayerMotion.x pasted in by
// motion-lifecycle-check.sh. A drag that closes the player a little and is let go back, and Notification Center
// pulled over the player, keep the clip on screen (no clear, no walk, no copy faded in); the background, a close
// that ends and a player that is really gone still let it go at once. The field goes on drawing through a close that
// is dragged; a song without a clip keeps its Still or Colors field while it is walked again; and the field is Fluid
// under the Visualizer and the full-screen cover, whatever was stored before them. Fails through harness-fail.h.
#import <UIKit/UIKit.h>
#import "Redesigned/Kit/SGRRestyle.h"
#import "harness-fail.h"

NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
static UIApplicationState harnessAppState = UIApplicationStateActive;
static void SGRBackdropInkSetSource(UIView *source) {}
static BOOL SGRPlayerLandscapeCovers(UIWindow *window) { return NO; }
#include "kinds.inc"
static SGRPlayerBackgroundKind storedNoClip = SGRPlayerBackgroundColours;
static BOOL stillOn, visualiserOn;
static SGRPlayerBackgroundKind SGRPlayerArtworkBackground(void) { return SGRPlayerBackgroundAnimated; }
static SGRPlayerBackgroundKind SGRPlayerNoClipBackground(void) { return storedNoClip; }
static BOOL SGRPlayerStillOn(void) { return stillOn; }
static BOOL SGRPlayerAnimatedVisualiserOn(void) { return visualiserOn; }

// The field in the player: the overlay above it is what Spotify's animator fades to its end alpha.
static UIView *screen;
static BOOL inScreen;   // set once the hierarchy is built: UIKit's own addSubview: asks the real window
// Each change of what the field draws (flows, fluid) is counted: one is a blur or palette read again.
static int redraws;
@interface SGRArtworkField : UIView
@property (nonatomic) BOOL offscreen;
@property (nonatomic) BOOL flows, fluid;
@end
@implementation SGRArtworkField
- (UIWindow *)window { return inScreen ? (UIWindow *)screen : nil; }
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view { return screen.bounds; }
- (void)setFlows:(BOOL)flows {
    if (flows != _flows) redraws++;
    _flows = flows;
}
- (void)setFluid:(BOOL)fluid {
    if (fluid != _fluid) redraws++;
    _fluid = fluid;
}
@end

#include "field.inc"

#pragma mark - doubles for PlayerMotion.x

#define SGLog(...) do {} while (0)
static const CGFloat kSquareAspect = 1.05;

@interface SGRPlayerMotionView : NSObject
- (void)playFile:(NSURL *)file poster:(UIImage *)poster;
- (void)handover;
@end
@implementation SGRPlayerMotionView
- (void)playFile:(NSURL *)file poster:(UIImage *)poster {}
- (void)handover {}
@end

// The track Spotify reports playing, and whether the follower walks it on a restart, as SGMotionFollower does.
static NSString *harnessPlayingURI;
static BOOL beginTrack(NSString *track);

@interface FollowerDouble : NSObject
@property (nonatomic) int restarts;
@property (nonatomic) BOOL walks;
- (void)restart;
@end
@implementation FollowerDouble
- (void)restart {
    self.restarts++;
    if (self.walks && harnessPlayingURI) beginTrack(harnessPlayingURI);
}
@end

static SGRPlayerMotionView *sg_motion, *sg_coverClip;
static NSString *sg_track, *sg_shown, *sg_stillOf;
static NSURL *sg_motionFile;
static UIImage *sg_motionPoster;
static NSUInteger sg_begun;
static BOOL sg_inactive;
static FollowerDouble *sg_follower;

static int clears, rebuilds, posterReads;
static BOOL lastClearAnimated;
static UIImage *tallPoster;

static void forget(void) {
    sg_motion = sg_coverClip = nil;
    sg_shown = sg_stillOf = nil;
    sg_motionFile = nil;
    sg_motionPoster = nil;
}

static void clear(BOOL animated) {
    clears++;
    lastClearAnimated = animated;
    forget();
}

static void clearForReplacement(BOOL animated, BOOL fieldClipFollows) {
    rebuilds++;
    forget();
}

static NSString *sg_noClip;
static const NSTimeInterval kHandOver = 0.4;
static int visualiserUpdates;
static BOOL harnessClipWanted = YES;
BOOL SGRPlayerTrackHasNoClip(void);
static BOOL clipWanted(void) { return harnessClipWanted; }
static BOOL seen(SGRPlayerMotionView *view) { return view && harnessAppState == UIApplicationStateActive; }
static BOOL showStill(void) { return NO; }
static void SGRPlayerVisualiserUpdate(void) { visualiserUpdates++; }
// PlayerField.x's, as far as what the field draws: configured for the playing track's answer.
static void SGRPlayerHoldField(void) { SGRPlayerConfigureField(sg_field, SGRPlayerTrackHasNoClip()); }

static void SGMotionPoster(NSURL *file, void (^done)(UIImage *poster)) {
    posterReads++;
    done(tallPoster);
}

static void showInCover(NSString *track, NSURL *file, UIImage *poster) {
    sg_coverClip = [SGRPlayerMotionView new];
    sg_shown = track;
    sg_motionFile = file;
}

static void showBehind(NSString *track, NSString *name, void (^draw)(SGRPlayerMotionView *motion)) {
    sg_motion = [SGRPlayerMotionView new];
    sg_shown = track;
    draw(sg_motion);
}

#include "motion.inc"

#pragma mark - the scenarios

static UIView *overlay;
static int posts;
static NSURL *fileA, *fileB;
static NSString *const kTrack = @"spotify:track:a";

static UIImage *imageOf(size_t width, size_t height) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    UIImage *picture = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return picture;
}

static void post(NSNotificationName name) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:nil];
}

// Spotify's animator writing the overlay's alpha; SGRObserveVisibility reports the setter.
static void overlayAlpha(CGFloat alpha) {
    overlay.alpha = alpha;
    visibilityChanged();
}

// The player open and in front, the clip of the playing track on screen, counters at zero.
static SGRPlayerMotionView *seat(void) {
    harnessAppState = UIApplicationStateActive;
    sg_inactive = NO;
    overlay.alpha = 1;
    field_viewWillAppear();
    field_viewDidAppear();
    HARNESS_CHECK(SGRPlayerIsVisible() && !SGRPlayerClosePending());
    sg_track = sg_shown = kTrack;
    sg_motion = [SGRPlayerMotionView new];
    sg_motionFile = fileA;
    clears = rebuilds = posterReads = posts = 0;
    sg_follower.restarts = 0;
    return sg_motion;
}

static void dragLetGoBack(void) {
    SGRPlayerMotionView *clip = seat();
    field_viewWillDisappear();
    overlayAlpha(0);   // the close's end alpha, given as the drag starts
    HARNESS_CHECK(!SGRPlayerIsVisible() && SGRPlayerClosePending());
    HARNESS_CHECK(clears == 0 && sg_motion == clip);
    int restartsHeld = sg_follower.restarts;
    // A walk's answer while held is not shown (the player cannot be seen), and nothing is read for it.
    show(kTrack, fileA);
    HARNESS_CHECK(posterReads == 0 && rebuilds == 0 && sg_motion == clip);
    overlayAlpha(1);   // the animator ends where it began
    field_viewWillAppear();
    field_viewDidAppear();
    HARNESS_CHECK(SGRPlayerIsVisible() && !SGRPlayerClosePending());
    HARNESS_CHECK(clears == 0 && sg_motion == clip);
    HARNESS_CHECK(sg_follower.restarts > restartsHeld);   // walked again once seen
    // The walk finds the file on screen: the clip plays on, no poster is read and no copy fades in.
    show(kTrack, fileA);
    HARNESS_CHECK(posterReads == 0 && rebuilds == 0 && sg_motion == clip && [sg_shown isEqualToString:kTrack]);
    // Another file for the track (its Canvas came late) still replaces it.
    show(kTrack, fileB);
    HARNESS_CHECK(posterReads == 1 && rebuilds == 1 && sg_motion && sg_motion != clip);
    puts("motion lifecycle: a close dragged a little and let go back keeps the clip");
}

// The field goes on drawing while the close is dragged, and stops once the close is over.
static void fieldThroughDrag(void) {
    seat();
    SGRArtworkField *field = sg_field;
    HARNESS_CHECK(!field.offscreen);
    field_viewWillDisappear();
    overlayAlpha(0);
    HARNESS_CHECK(!SGRPlayerIsVisible() && SGRPlayerClosePending() && !field.offscreen);
    overlayAlpha(0.5);
    HARNESS_CHECK(!field.offscreen);
    overlayAlpha(1);
    field_viewWillAppear();
    field_viewDidAppear();
    HARNESS_CHECK(!field.offscreen);
    // Let go to close: ended by viewDidDisappear.
    field_viewWillDisappear();
    overlayAlpha(0);
    HARNESS_CHECK(!field.offscreen);
    field_viewDidDisappear();
    HARNESS_CHECK(!SGRPlayerClosePending() && field.offscreen);
    // Ended by the coordinator alone.
    seat();
    field_viewWillDisappear();
    overlayAlpha(0);
    HARNESS_CHECK(!field.offscreen);
    post(SGPlayerTransitionEndedNotification);
    HARNESS_CHECK(!SGRPlayerClosePending() && field.offscreen);
    // The field out of its window mid close.
    seat();
    field_viewWillDisappear();
    overlayAlpha(0);
    HARNESS_CHECK(!field.offscreen);
    inScreen = NO;
    visibilityChanged();
    HARNESS_CHECK(!SGRPlayerClosePending() && field.offscreen);
    inScreen = YES;
    overlayAlpha(1);
    field_viewWillAppear();
    field_viewDidAppear();
    HARNESS_CHECK(!field.offscreen);
    puts("motion lifecycle: the field draws through a dragged close and stops when the close is over");
}

// A song whose walk found no clip, with Colors chosen for it: walking it again (Notification Center, a dragged close
// let go back) keeps the Colors field, and only an answer changes it.
static void noClipWalkedAgain(void) {
    seat();
    forget();
    storedNoClip = SGRPlayerBackgroundColours;
    harnessPlayingURI = kTrack;
    beginTrack(kTrack);
    motion_found(kTrack, nil);
    SGRArtworkField *field = sg_field;
    HARNESS_CHECK(SGRPlayerTrackHasNoClip() && field.flows && !field.fluid);
    redraws = 0;
    sg_follower.walks = YES;
    int restarts = sg_follower.restarts;
    post(UIApplicationWillResignActiveNotification);
    harnessAppState = UIApplicationStateInactive;
    harnessAppState = UIApplicationStateActive;
    post(UIApplicationDidBecomeActiveNotification);
    HARNESS_CHECK(sg_follower.restarts == restarts + 2);
    HARNESS_CHECK(SGRPlayerTrackHasNoClip() && redraws == 0 && field.flows && !field.fluid);
    motion_found(kTrack, nil);
    HARNESS_CHECK(redraws == 0 && field.flows);
    field_viewWillDisappear();
    overlayAlpha(0);
    overlayAlpha(1);
    field_viewWillAppear();
    field_viewDidAppear();
    HARNESS_CHECK(sg_follower.restarts > restarts + 2);
    HARNESS_CHECK(SGRPlayerTrackHasNoClip() && redraws == 0 && field.flows);
    motion_found(kTrack, nil);
    HARNESS_CHECK(redraws == 0 && field.flows && !field.fluid);
    // A clip found for it later (its Canvas came late): Fluid under the clip, and the Visualizer told.
    int updates = visualiserUpdates;
    motion_found(kTrack, fileA);
    HARNESS_CHECK(!SGRPlayerTrackHasNoClip() && field.fluid && !field.flows && visualiserUpdates > updates && sg_motion);
    motion_found(kTrack, nil);
    HARNESS_CHECK(SGRPlayerTrackHasNoClip() && field.flows);
    // Another track has no answer yet: Fluid until its walk gives one.
    harnessPlayingURI = @"spotify:track:b";
    beginTrack(harnessPlayingURI);
    HARNESS_CHECK(!SGRPlayerTrackHasNoClip() && field.fluid && !field.flows);
    motion_found(harnessPlayingURI, nil);
    HARNESS_CHECK(SGRPlayerTrackHasNoClip() && field.flows && !field.fluid);
    sg_follower.walks = NO;
    harnessPlayingURI = nil;
    sg_noClip = nil;
    puts("motion lifecycle: a song without a clip keeps its Colors field while it is walked again");
}

// Still or Colors stored before the Visualizer or the full-screen cover was chosen leaves the field Fluid under them.
static void fieldUnderStandIns(void) {
    SGRArtworkField *field = [[SGRArtworkField alloc] initWithFrame:CGRectZero];
    for (NSNumber *stored in @[@(SGRPlayerBackgroundStill), @(SGRPlayerBackgroundColours)]) {
        storedNoClip = stored.integerValue;
        SGRPlayerConfigureField(field, YES);
        HARNESS_CHECK(field.flows == (storedNoClip == SGRPlayerBackgroundColours) && !field.fluid);
        visualiserOn = YES;
        SGRPlayerConfigureField(field, YES);
        HARNESS_CHECK(field.fluid && !field.flows);
        visualiserOn = NO;
        stillOn = YES;
        SGRPlayerConfigureField(field, NO);
        HARNESS_CHECK(field.fluid && !field.flows);
        SGRPlayerConfigureField(field, YES);
        HARNESS_CHECK(field.fluid && !field.flows);
        stillOn = NO;
    }
    storedNoClip = SGRPlayerBackgroundColours;
    puts("motion lifecycle: the field is Fluid under the Visualizer and the full-screen cover");
}

static void closeEnds(void) {
    seat();
    field_viewWillDisappear();
    overlayAlpha(0);
    HARNESS_CHECK(clears == 0 && sg_motion);
    int before = posts;
    field_viewDidDisappear();
    HARNESS_CHECK(posts == before + 1);   // the end of the close is told, though the player was already unseen
    HARNESS_CHECK(clears == 1 && !lastClearAnimated && !sg_motion);
    HARNESS_CHECK(!SGRPlayerClosePending());
    puts("motion lifecycle: a close that ends lets the clip go at once");
}

static void closeEndedByCoordinator(void) {
    seat();
    field_viewWillDisappear();
    overlayAlpha(0);
    HARNESS_CHECK(clears == 0 && sg_motion);
    post(SGPlayerTransitionEndedNotification);   // no didDisappear: the coordinator's end alone
    HARNESS_CHECK(clears == 1 && !lastClearAnimated && !sg_motion);
    puts("motion lifecycle: a close the coordinator ended lets the clip go");
}

static void notificationCenter(SGRPlayerMotionView *(^put)(void)) {
    SGRPlayerMotionView *clip = put();
    post(UIApplicationWillResignActiveNotification);   // still active as it is posted
    harnessAppState = UIApplicationStateInactive;
    HARNESS_CHECK(sg_inactive && clears == 0 && sg_follower.restarts == 0);
    HARNESS_CHECK(sg_motion == clip || sg_coverClip == clip);
    show(kTrack, fileA);
    HARNESS_CHECK(posterReads == 0 && rebuilds == 0);
    visibilityChanged();   // PlayerField.x's own pass changes nothing
    HARNESS_CHECK(clears == 0);
    harnessAppState = UIApplicationStateActive;
    post(UIApplicationDidBecomeActiveNotification);
    HARNESS_CHECK(!sg_inactive && clears == 0 && sg_follower.restarts == 1);
    HARNESS_CHECK(sg_motion == clip || sg_coverClip == clip);
    show(kTrack, fileA);
    HARNESS_CHECK(posterReads == 0 && rebuilds == 0 && (sg_motion == clip || sg_coverClip == clip));
}

static void background(UIApplicationState stateAtPost) {
    seat();
    post(UIApplicationWillResignActiveNotification);
    HARNESS_CHECK(clears == 0 && sg_motion);
    harnessAppState = stateAtPost;
    post(UIApplicationDidEnterBackgroundNotification);
    HARNESS_CHECK(clears == 1 && !lastClearAnimated && !sg_motion && !sg_coverClip);
    harnessAppState = UIApplicationStateActive;
    int restarts = sg_follower.restarts;
    post(UIApplicationDidBecomeActiveNotification);
    HARNESS_CHECK(clears == 1 && sg_follower.restarts == restarts + 1);   // walked again for the clip to come back
}

static void inactiveOverHiddenPlayer(void) {
    seat();
    overlay.alpha = 0;   // the player not on screen, and no close under way
    post(UIApplicationWillResignActiveNotification);
    HARNESS_CHECK(clears == 1 && !sg_motion);
    harnessAppState = UIApplicationStateActive;
    overlay.alpha = 1;
    post(UIApplicationDidBecomeActiveNotification);
    puts("motion lifecycle: an inactive app over a player that is not seen lets the clip go");
}

static void inactiveWithoutClip(void) {
    seat();
    forget();
    post(UIApplicationWillResignActiveNotification);
    HARNESS_CHECK(clears == 1 && sg_follower.restarts == 1);   // as before: nothing held, the walk begun again
    harnessAppState = UIApplicationStateActive;
    post(UIApplicationDidBecomeActiveNotification);
    HARNESS_CHECK(sg_follower.restarts == 2);
}

int main(void) { @autoreleasepool {
    screen = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 402, 874)];
    overlay = [[UIView alloc] initWithFrame:screen.bounds];
    SGRArtworkField *field = [[SGRArtworkField alloc] initWithFrame:screen.bounds];
    [overlay addSubview:field];
    inScreen = YES;
    sg_field = field;
    sg_follower = [FollowerDouble new];
    tallPoster = imageOf(90, 160);
    fileA = [NSURL fileURLWithPath:@"/tmp/a.mp4"];
    fileB = [NSURL fileURLWithPath:@"/tmp/b.mp4"];
    [NSNotificationCenter.defaultCenter addObserverForName:SGRPlayerVisibilityDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) { posts++; }];
    field_observe();
    motion_observe();

    dragLetGoBack();
    closeEnds();
    closeEndedByCoordinator();
    notificationCenter(^{ return seat(); });
    notificationCenter(^{
        seat();
        SGRPlayerMotionView *square = [SGRPlayerMotionView new];
        sg_motion = nil;
        sg_coverClip = square;
        return square;
    });
    puts("motion lifecycle: Notification Center pulled over the player pauses the clip and goes on with it");
    background(UIApplicationStateBackground);
    background(UIApplicationStateInactive);
    puts("motion lifecycle: the background lets the clip go");
    inactiveOverHiddenPlayer();
    inactiveWithoutClip();
    fieldThroughDrag();
    noClipWalkedAgain();
    fieldUnderStandIns();
    puts("motion lifecycle: all checks passed");
    return 0;
} }
