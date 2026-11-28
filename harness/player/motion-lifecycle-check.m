// The player clip's lifecycle (issue #82), with production code from PlayerField.x and PlayerMotion.x pasted in by
// motion-lifecycle-check.sh. A drag that closes the player a little and is let go back, and Notification Center
// pulled over the player, keep the clip on screen (no clear, no walk, no copy faded in); the background, a close
// that ends and a player that is really gone still let it go at once. Fails through harness-fail.h.
#import <UIKit/UIKit.h>
#import "Redesigned/Kit/SGRRestyle.h"
#import "harness-fail.h"

NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
static UIApplicationState harnessAppState = UIApplicationStateActive;
static void SGRBackdropInkSetSource(UIView *source) {}
static BOOL SGRPlayerLandscapeCovers(UIWindow *window) { return NO; }

// The field in the player: the overlay above it is what Spotify's animator fades to its end alpha.
static UIView *screen;
static BOOL inScreen;   // set once the hierarchy is built: UIKit's own addSubview: asks the real window
@interface SGRArtworkField : UIView
@property (nonatomic) BOOL offscreen;
@end
@implementation SGRArtworkField
- (UIWindow *)window { return inScreen ? (UIWindow *)screen : nil; }
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view { return screen.bounds; }
@end

#include "field.inc"

#pragma mark - doubles for PlayerMotion.x

#define SGLog(...) do {} while (0)
static const CGFloat kSquareAspect = 1.05;

@interface SGRPlayerMotionView : NSObject
- (void)playFile:(NSURL *)file poster:(UIImage *)poster;
@end
@implementation SGRPlayerMotionView
- (void)playFile:(NSURL *)file poster:(UIImage *)poster {}
@end

@interface FollowerDouble : NSObject
@property (nonatomic) int restarts;
- (void)restart;
@end
@implementation FollowerDouble
- (void)restart { self.restarts++; }
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
    puts("motion lifecycle: all checks passed");
    return 0;
} }
