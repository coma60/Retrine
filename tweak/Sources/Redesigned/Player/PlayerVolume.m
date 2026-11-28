// Player redesign: a volume slider under the controls, as the Music app has. It is MPVolumeView, as the HIG asks
// (sliders.md, playing-audio.md) for local playback, unchanged. On a supported Connect device a matching slider
// uses Spotify's volume service (PlayerConnectVolume.x). No route button: the footer's Connect glyph is the route.
//
// It sits in Spotify's bottom stack, outside its arranged views, between the controls and the footer row, so the
// lyrics fade it with the rest of the stack (PlayerLyrics.x) and its touches stay inside the stack. The footer's
// lowerRow (PlayerFooter.x) places it after the moves, and keeps the controls where Spotify put them to make the room.
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"
#import "PlayerConnectVolume.h"
#import "Shared/Haptics/Haptics.h"

// The row's height, the glyphs' point size and the gap between a glyph and the track.
static const CGFloat kRowHeight = 34, kGlyphSize = 13, kGlyphGap = 4;
// The Music app's volume row reaches this far past the player's side margins: its speaker glyphs stand at 34 pt and
// its track runs from 57 to 336 pt on a 402 pt screen.
static const CGFloat kRowOut = 5;
// The speaker glyphs' ink: plain white 0.6 over a dark backdrop, which is the Music app's added white (0.46) there.
static const CGFloat kGlyphInkAlpha = 0.6, kGlyphInkAdd = 0.46;
// Half the footer glyphs' height: the row stops this far above their middle.
static const CGFloat kGlyphsHalf = 14;

// The slider is drawn as the progress bar above is (Player.h, SGRPlayerBarImage) on every iOS, the Music app's look:
// the fill ends square inside the round track, and a drag thickens the track and lights the fill as a scrub does the
// progress bar's, with the progress bar's held rail drawn over the slider while it is held. Such a slider tracks only
// a touch on its thumb, the fill's end; a sideways drag that starts anywhere
// else on the row moves the volume by the distance the finger goes, as iOS 26's thumbless slider and the Music app's
// do, and a tap there moves nothing. MPVolumeView keeps the images it is given for every slider it makes; it makes one
// when it lays out and may make another later, so each new one gets the drag's feedback after each of its layouts.
@interface SGRVolumeView : MPVolumeView
@end

@implementation SGRVolumeView

- (void)layoutSubviews {
    [super layoutSubviews];
    for (UISlider *slider in self.subviews) {
        if ([slider isKindOfClass:UISlider.class]) SGInstallVolumeFeedback(slider);
    }
    // The row's glyphs follow the slider, which this layout may have made or moved, and it follows the slider's drags.
    [self.superview setNeedsLayout];
}

@end

@interface SGRVolumeRow : UIView <UIGestureRecognizerDelegate>
@end

@implementation SGRVolumeRow {
    MPVolumeView *_volume;
    UISlider *_remote;
    UIImageView *_quiet, *_loud;
    UIPanGestureRecognizer *_pan;
    UISlider *_panSlider;               // the slider the drag began on, which alone it moves
    CGFloat _panFrom;                   // where along the slider the finger was at _panStart
    CGFloat _panAt;                     // where the finger was at the drag's last write
    float _panStart;                    // the level the finger's distance from _panFrom applies to
    NSMutableSet<NSNumber *> *_panOwn;  // the levels the drag wrote, with the one it began at
    // The sliders a finger's drag has held: the held rail stays over each until it has shrunk back after the finger
    // lets go, so it is kept here past the drag's end, for the layouts and repaints in between.
    NSHashTable<UISlider *> *_railed;
    BOOL _inkObserved;
    UIColor *_paintedFill, *_paintedTrack;  // the colors the tracks' images were last drawn in
}

// How far the fill's end goes from the slider's minimum to its maximum: negative right to left, where it goes leftward.
static CGFloat travel(UISlider *slider) {
    CGRect bounds = slider.bounds, track = [slider trackRectForBounds:bounds];
    return CGRectGetMidX([slider thumbRectForBounds:bounds trackRect:track value:slider.maximumValue])
        - CGRectGetMidX([slider thumbRectForBounds:bounds trackRect:track value:slider.minimumValue]);
}

static UIImageView *glyph(NSString *symbol) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:kGlyphSize weight:UIImageSymbolWeightSemibold];
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]];
    view.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    view.contentMode = UIViewContentModeCenter;
    view.isAccessibilityElement = NO;
    return view;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _volume = [SGRVolumeView new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _volume.showsRouteButton = NO;
#pragma clang diagnostic pop
    [_volume setVolumeThumbImage:[UIImage new] forState:UIControlStateNormal];
    _quiet = glyph(@"speaker.fill");
    _loud = glyph(@"speaker.wave.3.fill");
    [self addSubview:_quiet];
    [self addSubview:_volume];
    [self addSubview:_loud];
    _remote = [UISlider new];
    [_remote setThumbImage:[UIImage new] forState:UIControlStateNormal];
    _railed = [NSHashTable weakObjectsHashTable];
    [self paint];
    _remote.accessibilityLabel = SGL(@"player.volume", @"Volume");
    SGInstallVolumeFeedback(_remote);
    [self followDrags:_remote];
    [_remote addTarget:self action:@selector(remoteChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_remote];
    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    _pan.delegate = self;
    [self addGestureRecognizer:_pan];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshVolume)
        name:SGRConnectVolumeChangedNotification object:nil];
    [self refreshVolume];
    return self;
}

- (void)refreshVolume {
    double value;
    BOOL remote = SGRConnectReadVolume(&value);
    _remote.hidden = !remote;
    _volume.hidden = remote;
    // A level the Connect device reports during a drag of the row shows too: the drag goes on from it (panned:).
    if (remote && !_remote.tracking) _remote.value = value;
    SGRPlayerHeldVolumeBarMoved(_remote);
    // The other slider now shows: the drag ends without touching it.
    if (_panSlider && _panSlider != [self shownSlider]) [self cancelDrag];
}

// The recognizer goes to cancelled and says so to panned:, which ends the drag's look on its slider.
- (void)cancelDrag {
    _pan.enabled = NO;
    _pan.enabled = YES;
}

// The slider that shows: the Connect device's, or MPVolumeView's (none until it has laid one out).
- (UISlider *)shownSlider {
    if (!_remote.hidden) return _remote;
    for (UISlider *slider in _volume.subviews) {
        if ([slider isKindOfClass:UISlider.class]) return slider;
    }
    return nil;
}

// A touch that starts across the slider's width. The drag counts from where it went down, not from where the pan
// recognized it, a few points on.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (recognizer != _pan) return YES;
    UISlider *slider = [self shownSlider];
    CGFloat x = [touch locationInView:slider].x;
    if (!slider || x < CGRectGetMinX(slider.bounds) || x > CGRectGetMaxX(slider.bounds)) return NO;
    _panFrom = x;
    return YES;
}

// Sideways, and not a drag the slider tracks itself (one from its thumb); vertical ones stay the player's.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != _pan) return [super gestureRecognizerShouldBegin:recognizer];
    UISlider *slider = [self shownSlider];
    CGPoint velocity = [_pan velocityInView:self];
    return slider.enabled && !slider.tracking && fabs(velocity.x) > fabs(velocity.y);
}

// The slider has gestures of its own from iOS 26 on, which see every drag across it and move it only from its thumb;
// they would keep this one from starting.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return recognizer == _pan && other.view == [self shownSlider];
}

// The drag plays to the slider the events its own tracking sends, so the drag's look, the haptics and the Connect
// device follow it as they follow a drag of the thumb. MPVolumeView's slider sets the system volume with its value.
// The drag stays on the slider it began on: when the other one shows (the Connect device came or went), it is
// cancelled, never carried over with a level that was the other's.
//
// A level the drag did not write (the hardware buttons, which MPVolumeView shows on its slider, the Connect device or
// another app) becomes the drag's new start, so the finger's later distance applies to it and the change stays. The
// levels it wrote come back late as the system's and the device's own reports; those are not a change.
- (void)panned:(UIPanGestureRecognizer *)pan {
    UIGestureRecognizerState state = pan.state;
    if (state == UIGestureRecognizerStateBegan) {
        _panSlider = [self shownSlider];
        _panStart = _panSlider.value;
        _panAt = _panFrom;
        _panOwn = [NSMutableSet setWithObject:@(_panStart)];
        [_panSlider sendActionsForControlEvents:UIControlEventTouchDown];
    }
    UISlider *slider = _panSlider;
    BOOL moving = state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged;
    BOOL stays = slider == [self shownSlider];
    if (moving && !stays) {
        [self cancelDrag];
        return;
    }
    if (stays && (moving || state == UIGestureRecognizerStateEnded)) {
        float now = slider.value;
        if (![_panOwn containsObject:@(now)]) {
            _panStart = now;
            _panFrom = _panAt;
        }
        CGFloat x = [pan locationInView:slider].x;
        slider.value = _panStart + (x - _panFrom) / travel(slider) * (slider.maximumValue - slider.minimumValue);
        _panAt = x;
        [_panOwn addObject:@(slider.value)];
        if (slider.value != now) [slider sendActionsForControlEvents:UIControlEventValueChanged];
    }
    if (moving) return;
    [slider sendActionsForControlEvents:state == UIGestureRecognizerStateEnded ? UIControlEventTouchUpInside : UIControlEventTouchCancel];
    _panSlider = nil;
    _panOwn = nil;
}

- (void)remoteChanged:(UISlider *)slider {
    if (!SGRConnectSetVolume(slider.value)) [self refreshVolume];
}

// Both sliders' tracks, of which one shows: the bar's at rest. A finger's drag draws the held rail over them.
- (void)paint {
    CGFloat height = SGRPlayerBarHeight;
    // In the backdrop's hue (SGRInkPlainColor), as the Music app's bar and speakers are over a colored cover.
    UIColor *fillColor = SGRPlayerBarFillOver(self, NO, YES), *trackColor = SGRPlayerBarTrackOver(self);
    // The speaker glyphs stand where the bar's fill does (measured: 0.46 added), so they follow the backdrop the same way.
    UIColor *ink = SGRInkPlainColor(self, kGlyphInkAlpha, kGlyphInkAdd);
    if (![_quiet.tintColor isEqual:ink]) _quiet.tintColor = ink;
    if (![_loud.tintColor isEqual:ink]) _loud.tintColor = ink;
    // A reading that leaves the colors as they were draws no image (a drifting field reports several a second).
    if ([fillColor isEqual:_paintedFill] && [trackColor isEqual:_paintedTrack]) return;
    _paintedFill = fillColor;
    _paintedTrack = trackColor;
    UIImage *fill = SGRPlayerBarImage(fillColor, height), *track = SGRPlayerBarImage(trackColor, height);
    [_volume setMinimumVolumeSliderImage:fill forState:UIControlStateNormal];
    [_volume setMaximumVolumeSliderImage:track forState:UIControlStateNormal];
    [_remote setMinimumTrackImage:fill forState:UIControlStateNormal];
    [_remote setMaximumTrackImage:track forState:UIControlStateNormal];
    // A rail over a slider (a drag, or one shrinking back) in the new colors, the new images under it hidden.
    for (UISlider *slider in [self railSliders]) SGRPlayerRepaintHeldVolumeBar(slider);
}

// Every slider that may have a rail over it: the two the row shows now and any a drag held.
- (NSArray<UISlider *> *)railSliders {
    NSMutableOrderedSet<UISlider *> *sliders = [NSMutableOrderedSet orderedSet];
    if (_remote) [sliders addObject:_remote];
    for (UISlider *slider in _volume.subviews) {
        if ([slider isKindOfClass:UISlider.class]) [sliders addObject:slider];
    }
    [sliders addObjectsFromArray:_railed.allObjects];
    return sliders.array;
}

// A slider sends a touch down only for a touch it tracks (one on its thumb), so a drag's look starts with it, never with
// a touch it lets go.
- (void)followDrags:(UISlider *)slider {
    if ([slider actionsForTarget:self forControlEvent:UIControlEventTouchDown].count) return;
    [slider addTarget:self action:@selector(dragBegan:) forControlEvents:UIControlEventTouchDown];
    [slider addTarget:self action:@selector(dragEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [slider addTarget:self action:@selector(dragMoved:) forControlEvents:UIControlEventValueChanged];
}

- (void)dragBegan:(UISlider *)slider {
    [self showDrag:YES on:slider];
}

- (void)dragEnded:(UISlider *)slider {
    [self showDrag:NO on:slider];
}

- (void)dragMoved:(UISlider *)slider {
    SGRPlayerHeldVolumeBarMoved(slider);
}

// The held rail grows on the layout spring and back, as the progress bar's does; under Reduce Motion it crossfades.
- (void)showDrag:(BOOL)dragging on:(UISlider *)slider {
    if (dragging) [_railed addObject:slider];
    SGRPlayerHoldVolumeBar(slider, dragging);
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        // Out of the window no drag goes on (UIKit cancels its touches): no rail is left behind, shrinking or not.
        for (UISlider *slider in [self railSliders]) SGRPlayerDropVolumeBar(slider);
        [_railed removeAllObjects];
        return;
    }
    if (!_inkObserved) {
        _inkObserved = YES;
        // Painted again at each new reading of the backdrop, in whichever state the bar is.
        __weak SGRVolumeRow *weak = self;
        SGRBackdropInkObserve(self, ^{
            [weak paint];
        });
    }
    [self paint];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat side = kRowHeight, middle = CGRectGetMidY(bounds);
    CGFloat left = side / 2 + kGlyphSize / 2 + kGlyphGap, right = CGRectGetMaxX(bounds) - side / 2 - kGlyphSize - kGlyphGap;
    // MPVolumeView draws its slider at the top of its bounds, not in the middle: it gets the slider's own height,
    // centered, so the track lines up with the glyphs (it sat 9pt above them).
    CGFloat sliderHeight = MIN(side, [_volume sizeThatFits:CGSizeMake(MAX(0, right - left), side)].height ?: side);
    _volume.frame = CGRectMake(left, round(middle - sliderHeight / 2), MAX(0, right - left), sliderHeight);
    _remote.frame = _volume.frame;
    // MPVolumeView places its slider off its own middle (8pt above it on iOS 26, issue #86) and the track is centered
    // in the slider, so the glyphs stand on the slider's middle.
    CGFloat glyphs = middle;
    for (UISlider *slider in _volume.subviews) {
        if (![slider isKindOfClass:UISlider.class]) continue;
        glyphs = CGRectGetMidY([_volume convertRect:slider.frame toView:self]);
        [self followDrags:slider];
    }
    // A rail follows its slider, also while it shrinks back after the drag; one whose slider MPVolumeView has let go
    // (it makes a new one) goes with it.
    for (UISlider *slider in [self railSliders]) {
        if (slider.superview == _volume || slider == _remote) {
            SGRPlayerHeldVolumeBarMoved(slider);
        } else {
            [_railed removeObject:slider];
            SGRPlayerDropVolumeBar(slider);
        }
    }
    _quiet.frame = CGRectMake(0, glyphs - side / 2, side / 2 + kGlyphSize / 2, side);
    _loud.frame = CGRectMake(CGRectGetMaxX(bounds) - side / 2 - kGlyphSize, glyphs - side / 2, side / 2 + kGlyphSize, side);
}

@end

static char kVolumeKey, kPlayKey, kSettleKey;
// Passes the footer's layout is asked for again while the row's place keeps changing, at most.
static const NSUInteger kSettlePasses = 6;

// Read at launch, as the player's other switches are: the footer asks on every layout pass.
BOOL SGRPlayerVolumeOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGEnabled(SGRKeyPlayerVolume); });
    return on;
}

// The footer lays out before Spotify's bottom stack has arranged its views the first time the player opens (the
// controls then stand near the stack's top), and nothing lays the footer out again once the stack has: the row was
// placed against the controls' old place and stayed there, over their buttons. A row that moved asks the footer's
// layout once more on the next turn of the run loop, which finds the settled places; one that did not move ends it.
static void settle(UIView *stack, UIView *row, BOOL moved, CGRect frame) {
    NSUInteger passes = [objc_getAssociatedObject(stack, &kSettleKey) unsignedIntegerValue];
    if (!moved) {
        if (passes) objc_setAssociatedObject(stack, &kSettleKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (passes >= kSettlePasses) return;
    objc_setAssociatedObject(stack, &kSettleKey, @(passes + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (passes > 0) SGLog(@"redesign player: volume row placed again at %.0f (pass %lu)", frame.origin.y, (unsigned long)passes + 1);
    __weak UIView *weakStack = stack, *weakRow = row;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *settledStack = weakStack, *settledRow = weakRow;
        if (!settledStack.window || !settledRow.window) return;
        [settledStack layoutIfNeeded];
        SGRPlayerLowerRow(settledRow);
    });
}

BOOL SGRPlayerPlaceVolume(UIView *stack, UIView *controls, UIView *row, CGFloat margin, BOOL rhythm) {
    SGRVolumeRow *volume = objc_getAssociatedObject(stack, &kVolumeKey);
    if (!SGRPlayerVolumeOn() || !controls) {
        SGRPlayerLyricsFadeView(volume, NO);
        return NO;
    }
    if (!volume) {
        volume = [SGRVolumeRow new];
        // The floating unit grows the bottom-pinned stack at its top. Like
        // play and the footer, stay with the bottom during that resize, even
        // when neither unit changes size or receives another layout pass.
        volume.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
        objc_setAssociatedObject(stack, &kVolumeKey, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (volume.superview != stack) [stack addSubview:volume];
    // Between the play button's bottom and the footer glyphs' top, each where it is drawn (convertRect: takes the moves'
    // transforms in). Without the button there is nothing to stand under: a guess from the controls' unit
    // put the row across the buttons on an iPhone 13 Pro with iOS 17 (issue #32) and took their taps, so no row.
    UIView *play = SGRFindByIdentifier(controls, @"SPTNowPlayingPlayButton", &kPlayKey);
    if (!play) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            SGLog(@"redesign player: no play button in %@, so no volume row", NSStringFromClass(controls.class));
        }
        SGRPlayerLyricsFadeView(volume, NO);
        return NO;
    }
    CGFloat above = CGRectGetMaxY([play convertRect:play.bounds toView:stack]);
    CGFloat rowMiddle = [row convertPoint:CGPointMake(CGRectGetMidX(row.bounds), CGRectGetMidY(row.bounds)) toView:stack].y;
    CGFloat below = rowMiddle - kGlyphsHalf;
    CGFloat height = kRowHeight, room = below - above;
    // With the rhythm, the Music app's distance over the footer row where the room is as tall as the rhythm makes it;
    // halfway between the play button and the footer's glyphs where it is shorter, and without the rhythm.
    CGFloat halfway = (above + below) / 2;
    CGFloat middle = rhythm ? MAX(halfway, rowMiddle - SGRPlayerVolumeToRow) : halfway;
    CGRect frame = CGRectMake(margin - kRowOut, round(middle - height / 2), MAX(0, stack.bounds.size.width - 2 * (margin - kRowOut)), height);
    BOOL moved = !CGRectEqualToRect(volume.frame, frame);
    if (moved) volume.frame = frame;
    settle(stack, row, moved, frame);
    // The lyrics fade the stack's views by their alpha and bring back only the ones they faded.
    // The track is at most 12pt of the row's 34: it fits with the glyphs' and buttons' own clearance around it.
    BOOL fits = room >= height * 0.6;
    // A track change lays the stack out again while the lines are alone: the row must stay away from them until
    // the fade lets it go, rather than be shown here over the lyrics.
    BOOL faded = SGRPlayerLyricsFadeView(volume, fits);
    if (!faded && volume.alpha < 0.01 && controls.alpha > 0.99) volume.alpha = 1;
    return fits;
}
