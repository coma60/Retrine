// The Music queue page's History across picks (issue #82, item 4): a song picked out of Continue Playing, a song of
// History played again, Spotify's own History rewound or begun anew, and the motion of a pick. The production
// PlayerQueue.m with Spotify as the only behavioral double; harness/player/queue-check.m keeps the list's other checks.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SleepTimer.h"
#import "Redesigned/Player/PlayerMix.h"
#import "Redesigned/Player/PlayerQueue.h"
#import "Redesigned/Player/Player.h"
#import "Redesigned/Kit/SGRKit.h"
#import "../harness-fail.h"

@implementation SPTPlayerTrack
@end
@implementation SPTPlayerState
@end
@implementation SGRGlyphView
- (instancetype)initWithSymbol:(NSString *)symbol pointSize:(CGFloat)size weight:(UIImageSymbolWeight)weight {
    return [super initWithFrame:CGRectZero];
}
- (void)setSymbol:(NSString *)symbol animated:(BOOL)animated {}
@end
@interface QueueTrack : SPTPlayerTrack
@property NSString *UID;
@end
@implementation QueueTrack
@end
@interface QueueState : SPTPlayerState
@property NSString *queueRevision;
@property NSString *playbackId;
@end
@implementation QueueState
@end
@interface SPTSkipPrevOptions : NSObject
@property (nonatomic) BOOL overrideRestrictions;
@end
@implementation SPTSkipPrevOptions
@end
@interface QueueSnapshot : NSObject <NSCopying>
@property SPTPlayerTrack *track;
@property NSArray *prevTracks;
@property NSArray *nextTracks;
@end
@implementation QueueSnapshot
- (id)copyWithZone:(NSZone *)zone {
    QueueSnapshot *copy = [QueueSnapshot new];
    copy.track = self.track;
    copy.prevTracks = self.prevTracks;
    copy.nextTracks = self.nextTracks;
    return copy;
}
@end
// Records the commands; the checks then report what Spotify would.
@interface QueuePlayer : NSObject
@property QueueSnapshot *currentQueue;
@property SPTPlayerTrack *skippedTo, *rewoundTo;
@end
@implementation QueuePlayer
- (void)fetchQueue:(void (^)(id))callback on:(dispatch_queue_t)queue { callback(self.currentQueue); }
- (id)skipToNextTrackWithOptions:(id)options track:(SPTPlayerTrack *)track { self.skippedTo = track; return nil; }
- (id)skipToPreviousTrackWithOptions:(id)options track:(SPTPlayerTrack *)track { self.rewoundTo = track; return nil; }
@end

static QueueState *state;
static QueuePlayer *player;
static NSHashTable *observers;
static UIWindow *window;
static int checked;
SPTPlayerState *SGPlayerState(void) { return state; }
id SGPlayerInstance(void) { return player; }
id SGPlayer(void) { return player; }
id SGPlayerAdvanceRepeat(id<SPTPlayer> value, SPTPlayerOptions *options) { return nil; }
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) {
    if (!observers) observers = [NSHashTable weakObjectsHashTable];
    [observers addObject:observer];
}
NSString *SGURIString(id uri) { return [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : uri; }
NSArray *SGPlayerUpcomingTracks(SPTPlayerState *value, NSUInteger limit) { return value.future ?: @[]; }
NSString *SGL(NSString *key, NSString *english) { return english; }
BOOL SGRedesignedUI(void) { return YES; }
BOOL SGFlag(NSString *key, BOOL fallback) { return fallback; }
NSInteger SGInt(NSString *key, NSInteger fallback) { return fallback; }
void SGSetEnabled(NSString *key, BOOL on) {}
void SGPresentDark(UIViewController *controller) { controller.overrideUserInterfaceStyle = UIUserInterfaceStyleDark; }
UIViewController *SGTopController(void) { return window.rootViewController; }
UIColor *SGRPrimary(void) { return UIColor.whiteColor; }
UIColor *SGRSecondary(void) { return UIColor.grayColor; }
const CGFloat SGRGrid = 8;
const NSTimeInterval SGRCrossfade = 0;
BOOL SGRIncreaseContrast(void) { return NO; }
BOOL SGRReduceMotion(void) { return NO; }
// Motion: by default each animation lands at once and its completion is held until flushed, so a check can look at
// where it sends things. With realMotion it runs as SGRMotionLayout does (a 0.45 s critically damped spring), and the
// largest row offset it starts from is kept.
static BOOL realMotion;
static CGFloat startedFrom;
static NSMutableArray *heldCompletions;
static UITableView *watchedTable;
void SGRAnimate(SGRMotion motion, void (^animations)(void), void (^completion)(BOOL finished)) {
    if (!animations) return;
    if (realMotion) {
        for (UITableViewCell *cell in watchedTable.visibleCells) startedFrom = MAX(startedFrom, cell.transform.ty);
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:animations completion:completion];
        return;
    }
    animations();
    if (!completion) return;
    if (!heldCompletions) heldCompletions = [NSMutableArray array];
    [heldCompletions addObject:[completion copy]];
}
static void flushMotion(void) {
    NSArray *held = heldCompletions;
    heldCompletions = nil;
    for (void (^completion)(BOOL) in held) completion(YES);
}
UIFont *SGCategoryCappedFont(UIFontTextStyle style, UIFontWeight weight, UIContentSizeCategory largest) {
    return [UIFont preferredFontForTextStyle:style];
}
SGTransitionFacts *SGAutoMixCurrentTransition(void) { return nil; }
BOOL SGAutoMixAccountAllows(void) { return YES; }
void SGAutoMixApply(BOOL on) {}
SGSleepTimerMode SGSleepTimerCurrentMode(void) { return SGSleepTimerOff; }
NSDate *SGSleepTimerEnd(void) { return nil; }
void SGSetSleepTimer(SGSleepTimerMode mode, NSTimeInterval seconds) {}
BOOL SGRMixShowsQueue(void) { return NO; }
BOOL SGRMixTrackIs(SPTPlayerTrack *track, NSString *uri, NSString *uid) { return NO; }
BOOL SGTransitionSettingsRead(SGTransitionSettings *settings) { return NO; }
const CGFloat SGRRadiusThumb = 6;
NSProgress *SGRPlayerTrackCover(SPTPlayerTrack *track, BOOL small, void (^done)(UIImage *image)) {
    done(nil);
    return nil;
}
NSNotificationName const SGAutoMixTransitionDidChangeNotification = @"queue-history.mix";
NSNotificationName const SGAutoMixPlayerOptionsDidChangeNotification = @"queue-history.options";
NSNotificationName const SGTransitionSettingsDidChangeNotification = @"queue-history.transition-settings";

@interface SGRPlayerQueueController : UITableViewController
- (SPTPlayerTrack *)trackAt:(NSIndexPath *)path;
- (CGFloat)restOffset;
@end

static void check(BOOL condition, NSString *message) {
    checked++;
    printf("%s %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    fflush(stdout);
    if (!condition) HARNESS_FAIL(@"%@", message);
}

// A song of a context, its uri and uid its name unless a uid is given (a second report of one song can carry another).
static QueueTrack *song(NSString *name) {
    QueueTrack *track = [QueueTrack new];
    track.UID = name;
    [track setValue:[@"spotify:track:" stringByAppendingString:name] forKey:@"URI"];
    [track setValue:name forKey:@"trackTitle"];
    [track setValue:@"context" forKey:@"provider"];
    return track;
}
static QueueTrack *again(QueueTrack *track, NSString *uid) {
    QueueTrack *copy = song(track.trackTitle);
    copy.UID = uid;
    return copy;
}
static NSArray<QueueTrack *> *songs(NSString *prefix, NSInteger count) {
    NSMutableArray *list = [NSMutableArray array];
    for (NSInteger i = 0; i < count; i++) [list addObject:song([NSString stringWithFormat:@"%@%ld", prefix, (long)i])];
    return list;
}

static NSUInteger revision;
// Spotify reports `current` playing, `past` its History oldest first (its state lists it newest first) and `future`.
static void spotify(SPTPlayerTrack *current, NSArray *past, NSArray *future) {
    [state setValue:current forKey:@"track"];
    [state setValue:past.reverseObjectEnumerator.allObjects forKey:@"reverse"];
    [state setValue:future forKey:@"future"];
    player.currentQueue.track = current;
    player.currentQueue.prevTracks = past;
    player.currentQueue.nextTracks = future;
    state.queueRevision = [NSString stringWithFormat:@"%lu", (unsigned long)++revision];
    for (id<SGPlayerStateObserver> observer in observers.allObjects) [observer playerStateDidReport:state];
}

static SGRPlayerQueueController *list;

static NSInteger sectionWhere(BOOL (^test)(id group)) {
    NSArray *groups = [list valueForKey:@"groups"];
    for (NSUInteger i = 0; i < groups.count; i++) if (test(groups[i])) return (NSInteger)i;
    return NSNotFound;
}
static NSArray<NSString *> *names(NSArray<SPTPlayerTrack *> *tracks) {
    NSMutableArray *values = [NSMutableArray array];
    for (SPTPlayerTrack *track in tracks) [values addObject:track.trackTitle];
    return values;
}
static NSArray<NSString *> *history(void) {
    NSInteger section = sectionWhere(^BOOL(id group) { return [[group valueForKey:@"history"] boolValue]; });
    if (section == NSNotFound) return @[];
    return names([[list valueForKey:@"groups"][(NSUInteger)section] valueForKey:@"tracks"]);
}
static NSInteger upcomingSection(void) {
    return sectionWhere(^BOOL(id group) { return [[group valueForKey:@"upcoming"] boolValue]; });
}
static NSIndexPath *upcoming(NSInteger row) { return [NSIndexPath indexPathForRow:row inSection:upcomingSection()]; }
static NSIndexPath *historyRow(NSString *name) {
    NSInteger section = sectionWhere(^BOOL(id group) { return [[group valueForKey:@"history"] boolValue]; });
    NSUInteger at = [history() indexOfObject:name];
    if (section == NSNotFound || at == NSNotFound) HARNESS_FAIL(@"no History row %@", name);
    return [NSIndexPath indexPathForRow:(NSInteger)at inSection:section];
}
static void tap(NSIndexPath *path) {
    [list tableView:list.tableView didSelectRowAtIndexPath:path];
}
static void settle(void) {
    flushMotion();
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    flushMotion();
    [list.tableView layoutIfNeeded];
}
static NSString *joined(NSArray<NSString *> *values) { return [values componentsJoinedByString:@" "]; }
static void expectHistory(NSArray<NSString *> *expected, NSString *what) {
    check([history() isEqual:expected], [NSString stringWithFormat:@"%@ (History: %@)", what, joined(history())]);
}
static NSArray<UIView *> *snapshotClips(void) {
    NSMutableArray *clips = [NSMutableArray array];
    for (UIView *view in list.tableView.subviews) {
        if (view.clipsToBounds && view.layer.zPosition == 50 && ![view isKindOfClass:UITableViewCell.class]) [clips addObject:view];
    }
    return clips;
}

static void run(void) {
    player = [QueuePlayer new];
    player.currentQueue = [QueueSnapshot new];
    state = [QueueState new];
    state.playbackId = @"playback";
    NSArray<QueueTrack *> *past = songs(@"h", 3), *context = songs(@"c", 12);
    QueueTrack *playing = song(@"now");
    spotify(playing, past, context);

    UIViewController *page = SGRPlayerQueuePage();
    page.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [window.rootViewController addChildViewController:page];
    page.view.frame = window.rootViewController.view.bounds;
    [window.rootViewController.view addSubview:page.view];
    [page didMoveToParentViewController:window.rootViewController];
    SGRPlayerQueuePageConfigure(page, 90, nil);
    [page.view layoutIfNeeded];
    list = (SGRPlayerQueueController *)page.childViewControllers.firstObject;
    watchedTable = list.tableView;
    settle();
    expectHistory(@[@"h0", @"h1", @"h2"], @"History starts as Spotify reports it");

    // 1. A song further down Continue Playing, Spotify keeping the songs skipped as played.
    check(fabs(list.tableView.contentOffset.y - [list restOffset]) < 1, @"the list opens at rest");
    tap(upcoming(2));
    check(player.skippedTo == context[2], @"a song to come skips ahead to that song");
    spotify(context[2], [past arrayByAddingObjectsFromArray:@[playing, context[0], context[1]]], [context subarrayWithRange:NSMakeRange(3, 9)]);
    NSArray<UIView *> *clips = snapshotClips();
    UIView *skippedSnap = clips.firstObject.subviews.firstObject;
    check(clips.count == 1 && clips.firstObject.subviews.count == 2 && skippedSnap.alpha < 0.01 && skippedSnap.transform.ty < -1,
          [NSString stringWithFormat:@"the two songs skipped are carried up with the rows and fade instead of vanishing (%lu pictures, moved %.0f)",
                                     (unsigned long)clips.firstObject.subviews.count, skippedSnap.transform.ty]);
    check(CGRectGetMinY(clips.firstObject.frame) - list.tableView.contentOffset.y >= 0,
          @"their pictures are cut off where the songs to come begin");
    settle();
    check(snapshotClips().count == 0, @"the pictures are gone once the motion ends");
    expectHistory(@[@"h0", @"h1", @"h2", @"now"], @"the song that was playing joins History; the songs skipped stay out");

    // 2. A song picked out of autoplay: Spotify begins another History, empty, then one of its own.
    NSArray<QueueTrack *> *autoplay = songs(@"a", 6);
    for (QueueTrack *track in autoplay) [track setValue:@"autoplay" forKey:@"provider"];
    spotify(context[2], [past arrayByAddingObjectsFromArray:@[playing, context[0], context[1]]],
            [[context subarrayWithRange:NSMakeRange(3, 2)] arrayByAddingObjectsFromArray:autoplay]);
    settle();
    NSArray *groups = [list valueForKey:@"groups"];
    check([names([groups[(NSUInteger)upcomingSection() + 1] valueForKey:@"tracks"]) isEqual:names(autoplay)],
          @"autoplay's songs stand under their own heading");
    tap([NSIndexPath indexPathForRow:3 inSection:upcomingSection() + 1]);
    check(player.skippedTo == autoplay[3], @"the autoplay song picked is skipped to");
    spotify(context[2], [past arrayByAddingObjectsFromArray:@[playing, context[0], context[1]]], autoplay);
    expectHistory(@[@"h0", @"h1", @"h2", @"now"], @"the report before Spotify moves leaves History as it was");
    QueueTrack *started = again(autoplay[3], @"a3-started");
    spotify(started, @[again(autoplay[0], @"a0-x"), again(autoplay[1], @"a1-x"), again(autoplay[2], @"a2-x")], [autoplay subarrayWithRange:NSMakeRange(4, 2)]);
    settle();
    expectHistory(@[@"h0", @"h1", @"h2", @"now", @"c2"], @"a new context's History keeps the songs played before it and leaves its skipped songs out");
    spotify(autoplay[4], @[again(autoplay[0], @"a0-x"), again(autoplay[1], @"a1-x"), again(autoplay[2], @"a2-x"), started], @[autoplay[5]]);
    settle();
    expectHistory(@[@"h0", @"h1", @"h2", @"now", @"c2", @"a3"], @"songs Spotify records after the pick join History in the order played");

    // 3. Songs of History played again. Spotify holds a3 in its History, a4 is to come, and "now" is kept by the page only.
    UITableViewCell *kept = [list tableView:list.tableView cellForRowAtIndexPath:historyRow(@"now")];
    player.skippedTo = player.rewoundTo = nil;
    tap(historyRow(@"now"));
    check(!player.rewoundTo && !player.skippedTo && kept.accessibilityTraits == UIAccessibilityTraitStaticText,
          @"a row only the page keeps, which Spotify has neither behind nor to come, plays nothing and reads as text");
    tap(historyRow(@"a3"));
    check(player.rewoundTo == started && !player.skippedTo, @"a song in Spotify's History is played again by going back to Spotify's own song");
    settle();
    spotify(started, @[again(autoplay[0], @"a0-x"), again(autoplay[1], @"a1-x"), again(autoplay[2], @"a2-x")], @[autoplay[4], autoplay[5]]);
    settle();
    expectHistory(@[@"h0", @"h1", @"h2", @"now", @"c2", @"a4"],
                  @"Spotify rewinding keeps every song played: the song played again leaves its place, the one that was playing joins");
    // a4 is now to come again, and only the page lists it as History.
    player.skippedTo = player.rewoundTo = nil;
    tap(historyRow(@"a4"));
    check(player.skippedTo == autoplay[4] && !player.rewoundTo, @"a row only the page keeps, to come in Spotify's queue, is skipped ahead to");
    spotify(autoplay[4], @[again(autoplay[0], @"a0-x"), again(autoplay[1], @"a1-x"), again(autoplay[2], @"a2-x"), started], @[autoplay[5]]);
    settle();
    expectHistory(@[@"h0", @"h1", @"h2", @"now", @"c2", @"a3"], @"played from the songs to come, History still holds every song played but the one playing");

    // A pick while the page still carries History: before Spotify moves, a new revision shows the same History.
    QueueTrack *extra = song(@"x");
    tap(upcoming(0));
    check(player.skippedTo == autoplay[5], @"the next song is picked");
    spotify(autoplay[4], @[again(autoplay[0], @"a0-x"), again(autoplay[1], @"a1-x"), again(autoplay[2], @"a2-x"), started], @[autoplay[5], extra]);
    settle();
    expectHistory(@[@"h0", @"h1", @"h2", @"now", @"c2", @"a3"], @"a report before the song picked plays leaves the carried History in place");
    spotify(autoplay[5], @[again(autoplay[0], @"a0-x"), again(autoplay[1], @"a1-x"), again(autoplay[2], @"a2-x"), started, autoplay[4]], @[extra]);
    settle();
    expectHistory(@[@"h0", @"h1", @"h2", @"now", @"c2", @"a3", @"a4"], @"then the song that was playing joins it");

    // 4. Clear hides what is shown; songs played after it show again.
    [list performSelector:@selector(clearHistory)];
    settle();
    expectHistory(@[], @"Clear empties History");
    spotify(extra, @[again(autoplay[0], @"a0-x"), again(autoplay[1], @"a1-x"), again(autoplay[2], @"a2-x"), started, autoplay[4], autoplay[5]], @[]);
    settle();
    expectHistory(@[@"a5"], @"Clear keeps hidden what it hid, and the song that was playing joins once it moves on");

    // Clear between a pick and Spotify moving: the song still playing is not lost.
    NSArray<QueueTrack *> *pending = songs(@"k", 4);
    spotify(pending[0], @[], [pending subarrayWithRange:NSMakeRange(1, 3)]);
    settle();
    tap(upcoming(1));
    [list performSelector:@selector(clearHistory)];
    settle();
    spotify(pending[2], @[pending[0], pending[1]], @[pending[3]]);
    settle();
    expectHistory(@[@"k0"], @"Clear before the song picked plays keeps the song that was playing for History");

    // 1. Spotify going back from outside (the lock screen, another device) while the page carries History.
    NSArray<QueueTrack *> *outside = songs(@"r", 6);
    spotify(outside[2], @[outside[0], outside[1]], [outside subarrayWithRange:NSMakeRange(3, 3)]);
    settle();
    tap(upcoming(1));
    spotify(outside[4], @[outside[0], outside[1], outside[2], outside[3]], @[outside[5]]);
    settle();
    expectHistory(@[@"r0", @"r1", @"r2"], @"the carry is shown once the song picked plays");
    spotify(outside[1], @[outside[0]], [outside subarrayWithRange:NSMakeRange(2, 4)]);
    settle();
    check([list valueForKey:@"carry"] == nil, @"going back past what the carry stood on lets the carry go");
    expectHistory(@[@"r0"], @"History is Spotify's again, in its order, without the song playing");

    // 5. A song skipped by a pick and played later is no longer hidden.
    NSArray<QueueTrack *> *fresh = songs(@"f", 6);
    QueueTrack *base = song(@"base");
    spotify(base, @[], fresh);
    settle();
    tap(upcoming(3));
    spotify(fresh[3], @[base, fresh[0], fresh[1], fresh[2]], [fresh subarrayWithRange:NSMakeRange(4, 2)]);
    settle();
    check(![history() containsObject:@"f1"], @"a song skipped by a pick is not History");
    spotify(fresh[1], @[base, fresh[0]], @[fresh[2], fresh[3], fresh[4], fresh[5]]);
    spotify(fresh[2], @[base, fresh[0], fresh[1]], @[fresh[3], fresh[4], fresh[5]]);
    settle();
    check([history() containsObject:@"f1"], [NSString stringWithFormat:@"a skipped song played later is History (%@)", joined(history())]);

    // 6. The carry lets go once Spotify has recorded ten songs of its own, and History is Spotify's again.
    NSArray<QueueTrack *> *plain = songs(@"p", 14);
    spotify(plain[0], @[], [plain subarrayWithRange:NSMakeRange(1, 13)]);
    settle();
    tap(upcoming(0));
    spotify(plain[1], @[plain[0]], [plain subarrayWithRange:NSMakeRange(2, 12)]);
    BOOL held9 = NO;
    for (NSInteger i = 2; i <= 11; i++) {
        spotify(plain[i], [plain subarrayWithRange:NSMakeRange(0, (NSUInteger)i)], [plain subarrayWithRange:NSMakeRange((NSUInteger)i + 1, 13 - (NSUInteger)i)]);
        if (i == 10) held9 = [list valueForKey:@"carry"] != nil;
    }
    settle();
    check(held9 && [list valueForKey:@"carry"] == nil, @"the carry holds through nine songs Spotify records and lets go at ten");
    expectHistory(names([plain subarrayWithRange:NSMakeRange(1, 10)]), @"History is then Spotify's ten most recent");
    spotify(plain[11], [plain subarrayWithRange:NSMakeRange(0, 4)], @[]);
    settle();
    expectHistory(@[@"p0", @"p1", @"p2", @"p3"], @"a shorter History from Spotify for the same song is shown as reported");

    // 7. A pick that does not take: Spotify plays something else, and History is Spotify's again.
    NSArray<QueueTrack *> *other = songs(@"o", 5);
    spotify(other[0], @[], [other subarrayWithRange:NSMakeRange(1, 4)]);
    settle();
    tap(upcoming(2));
    spotify(other[1], @[other[0]], [other subarrayWithRange:NSMakeRange(2, 3)]);
    settle();
    expectHistory(@[@"o0"], @"a pick Spotify did not follow carries nothing");

    // 8. A report reloading the rows mid-slide carries on from where they stand, not from a straight line's guess.
    NSArray<QueueTrack *> *slide = songs(@"s", 14);
    spotify(slide[0], @[], [slide subarrayWithRange:NSMakeRange(1, 13)]);
    settle();
    realMotion = YES;
    startedFrom = 0;
    tap(upcoming(3));
    spotify(slide[4], @[slide[0], slide[1], slide[2], slide[3]], [slide subarrayWithRange:NSMakeRange(5, 9)]);
    CGFloat first = startedFrom;
    CFTimeInterval began = CACurrentMediaTime();
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.08]];
    CGFloat (^onScreen)(void) = ^CGFloat {
        CGFloat most = 0;
        for (UITableViewCell *cell in list.tableView.visibleCells) most = MAX(most, cell.layer.presentationLayer.transform.m42);
        return most;
    };
    CGFloat shown = onScreen();
    CGFloat linear = first * (1 - (CACurrentMediaTime() - began) / 0.45);
    startedFrom = 0;
    // Spotify's queue answers with songs to come that differ from its state's: the rows are reloaded.
    spotify(slide[4], @[slide[1], slide[2], slide[3]], [slide subarrayWithRange:NSMakeRange(5, 8)]);
    CGFloat second = startedFrom;
    check(first > 50 && shown > 0.5 && shown < linear - 5 && fabs(second - shown) <= 2,
          [NSString stringWithFormat:@"a reload mid-slide starts the new rows where the old ones stood on screen (slid %.0f, on screen %.1f, straight line %.1f, started from %.1f)",
                                     first, shown, linear, second]);
    check([[list valueForKey:@"slideRemaining"] doubleValue] == 0, @"the distance carried on is used up by that slide");
    // Still sliding, the list is moved off rest: the next reload is not placed, and leaves nothing behind for a later one.
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    CGFloat stillShown = onScreen();
    UITableView *slid = list.tableView;
    slid.contentOffset = CGPointMake(0, [list restOffset] + 30);
    startedFrom = 0;
    spotify(slide[4], @[slide[1], slide[2], slide[3]], [slide subarrayWithRange:NSMakeRange(5, 7)]);
    check(stillShown > 0.5 && startedFrom == 0 && [[list valueForKey:@"slideRemaining"] doubleValue] == 0,
          [NSString stringWithFormat:@"a reload not placed mid-slide keeps no distance for a later slide (on screen %.1f)", stillShown]);
    realMotion = NO;
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];

    // 9. Picked with History pulled down: the list glides back to rest at the tap.
    NSArray<QueueTrack *> *glide = songs(@"g", 8);
    spotify(glide[3], @[glide[0], glide[1], glide[2]], [glide subarrayWithRange:NSMakeRange(4, 4)]);
    settle();
    UITableView *table = list.tableView;
    CGFloat rest = [list restOffset];
    table.contentOffset = CGPointMake(0, rest - 150);
    tap(upcoming(1));
    BOOL returning = [[list valueForKey:@"returning"] boolValue];
    spotify(glide[5], @[glide[0], glide[1], glide[2], glide[3], glide[4]], @[glide[6], glide[7]]);
    BOOL held = [list valueForKey:@"heldShow"] != nil;
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
    settle();
    check(returning && held && fabs(table.contentOffset.y - [list restOffset]) < 1 && [names([list valueForKey:@"tracks"]) isEqual:@[@"g6", @"g7"]],
          @"a pick with History pulled down glides to rest and shows the change from there");

    printf("queue history checks: %d of %d right -- PASS\n", checked, checked);
    fflush(stdout);
    exit(0);
}

@interface QueueApp : UIResponder <UIApplicationDelegate>
@end
@implementation QueueApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 402, 600)];
    window.rootViewController = [UIViewController new];
    [window makeKeyAndVisible];
    [NSTimer scheduledTimerWithTimeInterval:0 repeats:NO block:^(NSTimer *timer) { run(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        HARNESS_FAIL(@"queue history checks did not finish");
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(QueueApp.class)); }
}
