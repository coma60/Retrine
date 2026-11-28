// The ink of the player's small text (the artist, the times, the audio quality badge) over a backdrop that is not
// always dark. Each is white ADDED to what is behind it (plusL), which brightens a dark backdrop and goes nowhere on
// a light one (a white cover's gray lower half: the words vanish). Two things are read to fix that:
//
//  - how light the backdrop is behind each of them: the field is drawn small now and then (a few times a second,
//    only while the player shows) and the rows the text stands on are averaged, so the reading follows a moving
//    field, a new cover and the lower shade (SGRFluid.m) without knowing which of them is drawing; and
//  - whether plusL can see that backdrop at all: a layer under an ancestor that is masked, rasterized or filtered
//    is drawn into a group of its own, where plusL adds to nothing and the ink is a plain translucent white.
//
// Over a dark backdrop nothing changes (the legacy alpha, plusL). Over a light one the alpha rises toward the
// ceiling given, and where plusL cannot see the backdrop the same result is drawn as a normal white of the alpha
// that lands on the same value over the measured backdrop.
//
// plusL adds to each channel apart, so over a colored backdrop the Music app's ink keeps the backdrop's hue (measured
// beside it over Coldplay's blue sky: the progress fill +108/+115/+106 of 255 on red/green/blue, the artist
// +123/+127/+106), where a plain white of any alpha pulls every channel toward white and goes gray. The field is read
// in color for that, and the ink is drawn as the plain color that lands on min(1, backdrop + add) in every channel
// (SGRInkSolve): over black or a gray that is white at the alpha it always was.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

// Posted on the main thread when a reading changed enough to matter.
extern NSNotificationName const SGRBackdropInkDidChangeNotification;

// The view whose pixels are behind the player's text, nil when the player goes. Starts and stops the readings.
void SGRBackdropInkSetSource(UIView *source);
// 0 (black) to 1 (white), encoded luma of the backdrop behind `view`; -1 while there is no reading.
CGFloat SGRBackdropLightnessBehind(UIView *view);
// The backdrop's encoded sRGB behind `view` (each 0 to 1), read where SGRBackdropLightnessBehind reads; NO while there
// is no reading.
BOOL SGRBackdropColorBehind(UIView *view, CGFloat rgb[3]);
// The plain color (`ink` at `alpha`) that lands where `add` ADDED to `backdrop` does, min(1, backdrop + add) in each
// channel: the least alpha that gets there is the brightest channel's, add / (1 - its value), at which that channel's
// ink is white and the others keep their distance below it, the backdrop's hue. With `step` the alpha is rounded up to
// steps of it and the ink worked out again for that alpha (both land on the same value). Never under `floorAlpha` (the
// ink's alpha over a dark backdrop), where the ink is the one worked out for the least alpha: white over black or gray.
void SGRInkSolve(const CGFloat backdrop[3], CGFloat add, CGFloat floorAlpha, CGFloat step, CGFloat ink[3], CGFloat *alpha);
// Whether plusL on `view` composites against nothing: a mask, a rasterized layer or a filter above it.
BOOL SGRInkIsolated(UIView *view);
// The ink for `view`: the plain color that lands where `alpha` of white added to the backdrop behind it would
// (SGRInkSolve, no floor), white of `alpha` with no reading. `lightAlpha` is not used. `plusL` is set to NO: the color
// is the plain one.
UIColor *SGRInkFor(UIView *view, CGFloat alpha, CGFloat lightAlpha, BOOL *plusL);
// For things drawn as plain translucent white that the Music app draws as white ADDED to the backdrop (its bars, its
// glyphs): the plain alpha that lands on the same value as `add` of white added over the measured backdrop,
// add / (1 - light), never under `floorAlpha` (the alpha that is the same thing over a dark backdrop), in steps of
// 0.05 so a drifting field does not redraw an image at every reading. `floorAlpha` where there is no reading or
// under Increase Contrast.
CGFloat SGRInkPlainAlpha(UIView *view, CGFloat floorAlpha, CGFloat add);
// The same in the backdrop's hue (SGRInkSolve with steps of 0.05, the ink in steps of 0.025, so a drifting field does
// not redraw an image at every reading): white of `floorAlpha` where there is no reading or under Increase Contrast.
UIColor *SGRInkPlainColor(UIView *view, CGFloat floorAlpha, CGFloat add);
// The backdrop starts a change of `duration` seconds (a new cover crossfading in): the readings follow it at the
// display's pace until it ends, rather than every quarter second.
void SGRBackdropInkFollow(CFTimeInterval duration);
// Calls `changed` after each change of reading for as long as `view` lives; a second call replaces the block.
void SGRBackdropInkObserve(UIView *view, void (^changed)(void));
