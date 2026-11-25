// Spotify owns the queue. History is a read-only list above the current song; Up Next keeps
// its existing skip-ahead action. Queue editing and History replay are not offered.
// History adapted from the GPL-3 jadetheda and michaelmelita1 forks.
//
// The Music app's queue (SGRKeyPlayerQueueStyle) is the same list drawn its way, as the page PlayerLyrics.x puts under the
// cover's thumbnail: a row of toggles over it (shuffle, repeat, the sleep timer where the Music app has Autoplay, and
// AutoMix, each on as the Music app marks one, a light capsule with the glyph cut out of it), then the songs to come
// under the headings the Music app gives them (Playing Next for songs queued by hand, Continue Playing for the album or
// playlist, Autoplaying similar music for autoplay), each with a grip that moves it among its section's songs, and
// History above them, out of sight until the list is pulled down. The Music app's own (its NowPlayingQueue views)
// were read for the gaps and sizes: 13 pt between the toggles, rows of a 48 pt cover with 4 pt corners and the titles
// beside it; the rest was measured on its player.
// Threading: main thread only; Spotify delivers fetches on main.
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/AutoMix/AutoMixPreview.h"
#import "Shared/Player/SleepTimer.h"
#import "Player.h"
#import "PlayerMix.h"
#import "PlayerQueue.h"
#import <objc/message.h>

static const NSUInteger kMaxRows = 50;
static const NSUInteger kHistoryRows = 10;
static const CGFloat kBlendPadding = 8, kBlendGap = 6;
// A row's cover, the Music app's list thumbnail (iOS 26, design/applemusic-gap item 22).
static const CGFloat kCoverSide = 44;
// The Music app's queue in the player: its rows' cover and corners, the room between the cover and the titles, and the
// room above and below each row (56 pt a row on its player, 2026-11-25).
static const CGFloat kMusicCoverSide = 48, kMusicCoverRadius = 4, kMusicCoverGap = 13, kMusicRowPad = 4;
// Its headings: the room over a heading, between the heading and the line under it, and under them before the rows.
// Measured on its player (402 pt wide, the default text size): the heading's capitals 20 pt under the toggles, the
// first cover 70 pt under them with a line under the heading, so a heading with its line stands 66 pt.
static const CGFloat kMusicHeadTop = 14, kMusicHeadGap = 0, kMusicHeadBottom = 10;
// Its toggles' height, measured on its player.
static const CGFloat kMusicControlsHeight = 37;

SGRPlayerQueueStyleKind SGRPlayerQueueStyle(void) {
    return SGInt(SGRKeyPlayerQueueStyle, SGRPlayerQueueStyleSpotify) == SGRPlayerQueueStyleMusic ? SGRPlayerQueueStyleMusic : SGRPlayerQueueStyleSpotify;
}

static BOOL metadataSays(SPTPlayerTrack *track, NSString *key) {
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    return [metadata isKindOfClass:NSDictionary.class] && [[metadata[key] description] isEqualToString:@"true"];
}

// Where a track to come comes from, the way Shared/Player/SleepTimer.m reads it: queued by hand, autoplay, or the album
// or playlist playing.
typedef NS_ENUM(NSInteger, SGRQueueSource) { SGRQueueSourceContext, SGRQueueSourceQueued, SGRQueueSourceAutoplay };
static SGRQueueSource sourceOf(SPTPlayerTrack *track) {
    NSString *provider = [track respondsToSelector:@selector(provider)] ? track.provider : nil;
    if (![provider isKindOfClass:NSString.class]) provider = nil;
    if ([provider isEqualToString:@"autoplay"] || metadataSays(track, @"autoplay.is_autoplay")) return SGRQueueSourceAutoplay;
    if ([provider isEqualToString:@"queue"] || metadataSays(track, @"is_queued")) return SGRQueueSourceQueued;
    return SGRQueueSourceContext;
}

// One section of the list: its heading, the line under it, its tracks, and whether a pick skips ahead to one.
@interface SGRQueueGroup : NSObject
@property (nonatomic, copy) NSString *title, *subtitle;
@property (nonatomic, copy) NSArray<SPTPlayerTrack *> *tracks;
@property (nonatomic) BOOL upcoming;
// The sheet's Up Next, with its heading and the blend under it (SGRQueueUpNextHeader).
@property (nonatomic) BOOL upNext;
// The Music app's page: the room the player's thumbnail and title stand in and the toggles under them, as a section of
// no rows, so they ride with the list.
@property (nonatomic) BOOL controls;
// History, whose heading has Clear.
@property (nonatomic) BOOL history;
@end
@implementation SGRQueueGroup
@end

static SGRQueueGroup *groupOf(NSString *title, NSString *subtitle, NSArray<SPTPlayerTrack *> *tracks, BOOL upcoming) {
    SGRQueueGroup *group = [SGRQueueGroup new];
    group.title = title;
    group.subtitle = subtitle;
    group.tracks = tracks ?: @[];
    group.upcoming = upcoming;
    return group;
}

// Verified against Spotify 9.1.90's metadata and live runtime. Every optional surface is gated below.
@protocol SGRQueueSnapshot <NSObject>
@property (nonatomic, readonly) SPTPlayerTrack *track;
@property (nonatomic, readonly) NSArray *prevTracks;
@property (nonatomic, readonly) NSArray *nextTracks;
@end
@protocol SGRQueuePlayer <SPTPlayer>
- (void)fetchQueue:(void (^)(id<SGRQueueSnapshot>))callback on:(dispatch_queue_t)queue;
@end

// Moving a song in the queue, the way Spotify's own queue screen does it (Spotify 9.2.0's binary, the function at
// 0x108439ed4 that calls setQueue:options:): a copy of the queue Spotify reported (copyWithZone:), its whole list of
// tracks to come in the new order (-[SPTPlayerQueueImplementation setNextTracks:]), and the copy handed back with a
// fresh SPTCommandOptions whose overrideRestrictions is on (-[SPTEsperantoPlayer setQueue:options:]). The copy keeps
// the reported queue's revision, which setQueue:options:loggingParams: sends on with the tracks (parseQueueRevision:),
// so a move goes against the queue it was made on. Each track keeps its own uid and provider: setQueue: rebuilds them
// from the SPTPlayerTrack objects themselves, which is why the objects Spotify reported are moved, never new ones.
static BOOL queueEditable(id queue) {
    static Class options;
    if (!options) options = NSClassFromString(@"SPTCommandOptions");
    id player = SGPlayerInstance();
    return queue && options && [queue respondsToSelector:@selector(copyWithZone:)] && [queue respondsToSelector:NSSelectorFromString(@"setNextTracks:")]
        && [options instancesRespondToSelector:NSSelectorFromString(@"setOverrideRestrictions:")]
        && [player respondsToSelector:NSSelectorFromString(@"setQueue:options:")];
}

// Hands Spotify `queue` with `next` as its tracks to come; the copy sent, which the next move builds on until Spotify
// reports the queue again, or nil.
static id sendQueue(id queue, NSArray *next) {
    if (!queueEditable(queue)) return nil;
    id copy = [queue copy];
    ((void (*)(id, SEL, NSArray *))objc_msgSend)(copy, NSSelectorFromString(@"setNextTracks:"), next);
    id options = [NSClassFromString(@"SPTCommandOptions") new];
    ((void (*)(id, SEL, BOOL))objc_msgSend)(options, NSSelectorFromString(@"setOverrideRestrictions:"), YES);
    ((id (*)(id, SEL, id, id))objc_msgSend)(SGPlayerInstance(), NSSelectorFromString(@"setQueue:options:"), copy, options);
    return copy;
}

static id queueValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSArray *trackIdentity(SPTPlayerTrack *track) {
    if (![track isKindOfClass:NSClassFromString(@"SPTPlayerTrack")]) return nil;
    NSString *uri = SGURIString(track.URI), *uid = queueValue(track, @"UID");
    if (!uri.length || ![uid isKindOfClass:NSString.class] || !uid.length) return nil;
    return @[uri, uid, track.provider ?: @""];
}

// The songs History leaves out, by URI and uid: the songs a pick from the list skipped over (the Music app plays the
// picked song next and drops the ones before it, where Spotify keeps them as played), and what Clear took away. Kept for
// as long as Spotify runs.
static NSMutableSet<NSString *> *sg_hiddenHistory;

static NSString *historyKey(SPTPlayerTrack *track) {
    NSString *uri = SGURIString(track.URI), *uid = queueValue(track, @"UID");
    if (!uri.length) return nil;
    return [NSString stringWithFormat:@"%@\t%@", uri, [uid isKindOfClass:NSString.class] ? uid : @""];
}

static void hideFromHistory(NSArray<SPTPlayerTrack *> *tracks) {
    if (!sg_hiddenHistory) sg_hiddenHistory = [NSMutableSet set];
    for (SPTPlayerTrack *track in tracks) {
        NSString *key = historyKey(track);
        if (key) [sg_hiddenHistory addObject:key];
    }
}

static NSArray<SPTPlayerTrack *> *queueTracks(NSArray *tracks, NSUInteger limit, BOOL history) {
    NSMutableArray *songs = [NSMutableArray new];
    if (![tracks isKindOfClass:NSArray.class]) return songs;
    for (SPTPlayerTrack *track in tracks) {
        if (![track isKindOfClass:NSClassFromString(@"SPTPlayerTrack")] || !track.trackTitle.length ||
            !SGURIString(track.URI) || (history && ![SGURIString(track.URI) hasPrefix:@"spotify:track:"])) continue;
        if (history && sg_hiddenHistory.count && [sg_hiddenHistory containsObject:historyKey(track) ?: @""]) continue;
        [songs addObject:track];
        if (songs.count == limit) break;
    }
    return songs;
}

// The blend from the playing song into `next`; nil when the facts say nothing about that pair.
static NSString *blendInto(SPTPlayerTrack *next) {
    SGTransitionFacts *facts = SGAutoMixCurrentTransition();
    if (!SGRMixShowsQueue() || !facts || !SGRMixTrackIs(SGPlayerState().track, facts.fromURI, facts.fromUID)
        || !SGRMixTrackIs(next, facts.toURI, facts.toUID)) return nil;
    if (facts.kind == SGTransitionKindSpotifyAutomix) return SGL(@"settings.player.queue.blend.spotify", @"Spotify AutoMix");
    SGTransitionSettings settings;
    if (facts.kind != SGTransitionKindCrossfade || !SGTransitionSettingsRead(&settings)) return nil;
    return [NSString stringWithFormat:SGL(@"settings.player.queue.blend.crossfade", @"Crossfade, %ld s"), lround(settings.milliseconds / 1000.0)];
}

// The line over the first row: the merge glyph and the blend's name, read out as the name.
@interface SGRQueueBlendView : UIView
@property (nonatomic, readonly) UILabel *label;
@end

@implementation SGRQueueBlendView {
    UIImageView *_glyph;
}

- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.triangle.merge"]];
    _glyph.tintColor = SGRSecondary();
    _glyph.contentMode = UIViewContentModeScaleAspectFit;
    _label = [UILabel new];
    _label.textColor = SGRSecondary();
    _label.numberOfLines = 0;
    [self addSubview:_glyph];
    [self addSubview:_label];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitStaticText;
    [self takeFont];
    return self;
}

- (void)takeFont {
    _label.font = SGCategoryCappedFont(UIFontTextStyleFootnote, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
    _glyph.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithFont:_label.font];
}

- (void)setText:(NSString *)text {
    _label.text = text;
    self.accessibilityLabel = text;
    [self setNeedsLayout];
}

- (CGFloat)glyphWidth {
    return ceil(_glyph.intrinsicContentSize.width);
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat text = width - self.layoutMargins.left - self.layoutMargins.right - [self glyphWidth] - kBlendGap;
    return ceil([_label sizeThatFits:CGSizeMake(text, CGFLOAT_MAX)].height) + 2 * kBlendPadding;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat x = self.layoutMargins.left, glyph = [self glyphWidth];
    CGFloat width = self.bounds.size.width - x - self.layoutMargins.right - glyph - kBlendGap;
    CGFloat height = ceil([_label sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    _glyph.frame = CGRectMake(x, kBlendPadding, glyph, _label.font.lineHeight);
    _label.frame = CGRectMake(x + glyph + kBlendGap, kBlendPadding, width, height);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self takeFont];
}

@end

// The Up Next heading and, under it, the blend into the first song. A header view of the table's own kind, so the
// table gives it the margins it gives its own headers (History, Now Playing): the heading and the blend stand where
// their headings do, over the rows' covers.
@interface SGRQueueUpNextHeader : UITableViewHeaderFooterView
@property (nonatomic, readonly) UILabel *title;
@property (nonatomic, readonly) SGRQueueBlendView *blend;
@end

@implementation SGRQueueUpNextHeader

- (instancetype)initWithReuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithReuseIdentifier:identifier])) return nil;
    _title = [UILabel new];
    _title.text = SGL(@"settings.player.queue.up_next", @"Up Next");
    _title.textColor = SGRSecondary();
    _blend = [SGRQueueBlendView new];
    [self.contentView addSubview:_title];
    [self.contentView addSubview:_blend];
    return self;
}

- (CGFloat)headingHeight {
    return ceil(_title.font.lineHeight) + 2 * kBlendPadding;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *content = self.contentView;
    UIEdgeInsets margins = content.layoutMargins;
    CGFloat width = content.bounds.size.width;
    _title.frame = CGRectMake(margins.left, kBlendPadding, MAX(0, width - margins.left - margins.right), ceil(_title.font.lineHeight));
    _blend.layoutMargins = UIEdgeInsetsMake(0, margins.left, 0, margins.right);
    _blend.frame = CGRectMake(0, [self headingHeight], width, _blend.hidden ? 0 : [_blend heightForWidth:width]);
}

@end

// A heading of the Music app's queue: its title, the line under it, and the blend into the first song under the first
// heading of the songs to come. Laid out by hand at the player's margin, the heading not pinned (the list is grouped).
@interface SGRQueueMusicHeader : UITableViewHeaderFooterView
@property (nonatomic, readonly) UILabel *title, *subtitle;
@property (nonatomic, readonly) SGRQueueBlendView *blend;
// History's Clear, at the heading's trailing end; hidden on the other headings.
@property (nonatomic, readonly) UIButton *action;
@property (nonatomic, copy) void (^onAction)(void);
- (void)setActionTitle:(NSString *)title;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

@implementation SGRQueueMusicHeader

- (instancetype)initWithReuseIdentifier:(NSString *)identifier {
    if (!(self = [super initWithReuseIdentifier:identifier])) return nil;
    self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    _title = [UILabel new];
    _title.textColor = SGRPrimary();
    _subtitle = [UILabel new];
    _subtitle.textColor = SGRSecondary();
    _blend = [SGRQueueBlendView new];
    _blend.layoutMargins = UIEdgeInsetsMake(0, SGRPlayerSideMargin, 0, SGRPlayerSideMargin);
    UIButtonConfiguration *clear = [UIButtonConfiguration grayButtonConfiguration];
    clear.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    clear.baseForegroundColor = SGRPrimary();
    clear.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    clear.contentInsets = NSDirectionalEdgeInsetsMake(6, 14, 6, 14);
    _action = [UIButton buttonWithConfiguration:clear primaryAction:nil];
    _action.hidden = YES;
    [_action addTarget:self action:@selector(acted) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[_title, _subtitle, _blend, _action]) [self.contentView addSubview:view];
    [self takeFonts];
    return self;
}

- (void)acted {
    if (self.onAction) self.onAction();
}

- (void)setActionTitle:(NSString *)title {
    _action.hidden = !title.length;
    if (!title.length) return;
    UIButtonConfiguration *config = _action.configuration;
    UIFont *font = SGCategoryCappedFont(UIFontTextStyleSubheadline, UIFontWeightSemibold, UIContentSizeCategoryAccessibilityMedium);
    config.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: font}];
    _action.configuration = config;
    [self setNeedsLayout];
}

- (void)takeFonts {
    _title.font = SGCategoryCappedFont(UIFontTextStyleTitle3, UIFontWeightBold, UIContentSizeCategoryAccessibilityMedium);
    _subtitle.font = SGCategoryCappedFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self takeFonts];
}

- (CGFloat)heightForWidth:(CGFloat)width {
    CGFloat height = kMusicHeadTop + ceil(_title.font.lineHeight) + kMusicHeadBottom;
    if (_subtitle.text.length) height += kMusicHeadGap + ceil(_subtitle.font.lineHeight);
    if (_blend.label.text.length) height += [_blend heightForWidth:width];
    return height;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, inner = MAX(0, width - 2 * SGRPlayerSideMargin);
    CGFloat y = kMusicHeadTop;
    BOOL rtlAction = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat actionWidth = 0;
    if (!_action.hidden) {
        CGSize size = [_action sizeThatFits:CGSizeMake(inner / 2, CGFLOAT_MAX)];
        actionWidth = ceil(size.width);
        CGFloat middle = y + ceil(_title.font.lineHeight) / 2;
        _action.frame = CGRectMake(rtlAction ? SGRPlayerSideMargin : width - SGRPlayerSideMargin - actionWidth,
                                   round(middle - size.height / 2), actionWidth, ceil(size.height));
        actionWidth += SGRGrid;
    }
    _title.frame = CGRectMake(SGRPlayerSideMargin + (rtlAction ? actionWidth : 0), y, MAX(0, inner - actionWidth), ceil(_title.font.lineHeight));
    y = CGRectGetMaxY(_title.frame);
    _subtitle.hidden = !_subtitle.text.length;
    if (!_subtitle.hidden) {
        _subtitle.frame = CGRectMake(SGRPlayerSideMargin, y + kMusicHeadGap, inner, ceil(_subtitle.font.lineHeight));
        y = CGRectGetMaxY(_subtitle.frame);
    }
    _blend.hidden = !_blend.label.text.length;
    _blend.layoutMargins = UIEdgeInsetsMake(0, SGRPlayerSideMargin, 0, SGRPlayerSideMargin);
    _blend.frame = CGRectMake(0, y, width, _blend.hidden ? 0 : [_blend heightForWidth:width]);
    BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    NSTextAlignment alignment = rtl ? NSTextAlignmentRight : NSTextAlignmentLeft;
    _title.textAlignment = _subtitle.textAlignment = alignment;
}

@end

// What a row shows, so a report that changed nothing in the list leaves it alone.
static NSArray<NSString *> *signatureOf(NSArray<SPTPlayerTrack *> *tracks) {
    NSMutableArray<NSString *> *signature = [NSMutableArray arrayWithCapacity:tracks.count];
    for (SPTPlayerTrack *track in tracks) {
        [signature addObject:[NSString stringWithFormat:@"%@\t%@\t%@\t%@", trackIdentity(track), SGURIString(track.URI), track.trackTitle, track.artistName ?: @""]];
    }
    return signature;
}

#ifndef __IPHONE_17_0
// UIKit calls it from iOS 13 on (back-deployed); the iOS 16.5 SDK the tweak builds with does not declare it.
@interface UIViewController (SGRIsAppearing)
- (void)viewIsAppearing:(BOOL)animated;
@end
#endif

@interface SGRPlayerQueueController : UITableViewController <SGPlayerStateObserver>
// In the two column player's side column, or the Music app's page in the player, rather than a sheet: nothing to close.
@property (nonatomic) BOOL embedded;
// Drawn the Music app's way, for its page in the player (SGRPlayerQueuePage).
@property (nonatomic, readonly) BOOL musicStyle;
- (instancetype)initMusicStyle;
// The Music app's page: the room over the toggles where the player's thumbnail and title stand (PlayerLyrics.x), the
// toggles, and what is told how far the list has moved from where it rests (positive as it scrolls up), so the thumbnail
// and the title ride with it.
@property (nonatomic) CGFloat headHeight;
@property (nonatomic, strong) UIView *controls;
@property (nonatomic, copy) void (^scrolled)(CGFloat shift);
// Back to rest at once, unless a finger is on the list.
- (void)goToRest;
- (void)placeAtUpcoming;
@end

@implementation SGRPlayerQueueController {
    NSArray<SPTPlayerTrack *> *_tracks;
    NSArray *_signature;
    NSArray<SPTPlayerTrack *> *_history;
    SPTPlayerTrack *_current;
    NSArray *_reportedKey;
    BOOL _fetching;
    UILabel *_empty;
    SGRQueueUpNextHeader *_upNext;
    // Each row's cover by the track's URI once it has landed (a failed or missing one is asked for again when its row
    // next comes on screen), and the ones on their way.
    NSCache<NSString *, UIImage *> *_covers;
    NSMutableDictionary<NSString *, NSProgress *> *_coming;
    // The sections as shown, and the blend into the first song to come.
    NSArray<SGRQueueGroup *> *_groups;
    NSString *_blendText;
    // The Music app's list opens on the songs to come, History above them: placed so once for the song playing, and
    // again for the next one while nobody is scrolling it.
    NSString *_placedFor;
    // The queue Spotify last reported, whose tracks the list shows when _fromSnapshot: only then can a song be moved.
    id _snapshot;
    BOOL _fromSnapshot;
    // A finger is moving a row: the list is not reloaded under it, and the queue Spotify reported meanwhile is shown once
    // it lets go.
    BOOL _reordering;
    NSUInteger _reorderGeneration;
    id _heldQueue;
}

- (void)dealloc {
    [self stopCoversExcept:nil];
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = SGL(@"settings.player.queue.title", @"Playing Next");
    _groups = @[];
    return self;
}

- (instancetype)initMusicStyle {
    if (!(self = [super initWithStyle:UITableViewStyleGrouped])) return nil;
    self.title = SGL(@"settings.player.queue.title", @"Playing Next");
    _musicStyle = YES;
    _embedded = YES;
    _groups = @[];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.embedded) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                                                             target:self action:@selector(close)];
    }
    // From iOS 26 a sheet short of full height is Liquid Glass the system draws; a fill here would cover it. In the
    // player's column the player's background shows through.
    if (self.embedded) self.tableView.backgroundColor = UIColor.clearColor;
    else if (@available(iOS 26.0, *)) self.tableView.backgroundColor = UIColor.clearColor;
    if (_musicStyle) {
        UITableView *table = self.tableView;
        table.separatorStyle = UITableViewCellSeparatorStyleNone;
        table.sectionHeaderTopPadding = 0;
        table.sectionFooterHeight = CGFLOAT_MIN;
        table.estimatedSectionFooterHeight = 0;
        table.cellLayoutMarginsFollowReadableWidth = NO;
        table.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, CGFLOAT_MIN)];
        table.rowHeight = kMusicCoverSide + 2 * kMusicRowPad;
        [table registerClass:SGRQueueMusicHeader.class forHeaderFooterViewReuseIdentifier:@"heading"];
        [table registerClass:UITableViewHeaderFooterView.class forHeaderFooterViewReuseIdentifier:@"controls"];
        // The Music app's grips on the songs to come: the table stays in editing mode, rows still picked with a tap.
        table.allowsSelectionDuringEditing = YES;
        table.editing = YES;
    }
    _empty = [UILabel new];
    _empty.text = SGL(@"settings.player.queue.empty", @"Nothing is playing next.");
    _empty.font = SGCategoryCappedFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
    _empty.textColor = SGRSecondary();
    _empty.textAlignment = NSTextAlignmentCenter;
    _empty.numberOfLines = 0;
    _upNext = [[SGRQueueUpNextHeader alloc] initWithReuseIdentifier:nil];
    _covers = [NSCache new];
    _coming = [NSMutableDictionary dictionary];
    self.tableView.accessibilityIdentifier = @"retrine.queue";
    [self takeState:SGPlayerState()];
    SGAddPlayerStateObserver(self);
    // Both are posted on the main thread.
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(showBlend) name:SGAutoMixTransitionDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(showBlend) name:SGAutoMixPlayerOptionsDidChangeNotification object:nil];
}

// Only the upcoming section owns the transition from current to next, never History.
- (void)showBlend {
    NSString *text = blendInto(_tracks.firstObject);
    if (_musicStyle) {
        if (_blendText == text || [_blendText isEqualToString:text]) return;
        _blendText = text;
        NSUInteger first = [self firstUpcomingSection];
        SGRQueueMusicHeader *header = first == NSNotFound ? nil : (id)[self.tableView headerViewForSection:(NSInteger)first];
        if ([header isKindOfClass:SGRQueueMusicHeader.class]) {
            [header.blend setText:text];
            [header setNeedsLayout];
        }
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
        return;
    }
    SGRQueueBlendView *blend = _upNext.blend;
    if (blend.label.text == text || [blend.label.text isEqualToString:text]) return;
    [blend setText:text];
    [_upNext setNeedsLayout];
    [self.tableView beginUpdates];
    [self.tableView endUpdates];
}

// The Up Next header's height for the table's width: the heading, and the blend when there is one, measured at the
// margins the header was last given (the table's own until it has been laid out once).
- (CGFloat)upNextHeight {
    UITableView *table = self.tableView;
    SGRQueueBlendView *blend = _upNext.blend;
    _upNext.title.font = SGCategoryCappedFont(UIFontTextStyleHeadline, UIFontWeightSemibold, UIContentSizeCategoryAccessibilityMedium);
    BOOL showsBlend = blend.label.text.length > 0;
    blend.hidden = !showsBlend;
    if (UIEdgeInsetsEqualToEdgeInsets(blend.layoutMargins, UIEdgeInsetsZero)) blend.layoutMargins = table.layoutMargins;
    return [_upNext headingHeight] + (showsBlend ? [blend heightForWidth:table.bounds.size.width] : 0);
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// Coming on screen, first or again with its rows kept, in a window already (viewWillAppear: is too early for one): each
// row shown asks for its cover, one set up off screen or cancelled when the list went away included (coverOf: asks
// nothing for a cover in or on its way), and takes it as it lands.
- (void)viewIsAppearing:(BOOL)animated {
    [super viewIsAppearing:animated];
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) [self coverOf:[self trackAt:path]];
}

// Closed, or the side column gone: no row waits for a cover, and viewIsAppearing: asks again for the rows shown.
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopCoversExcept:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    _empty.font = SGCategoryCappedFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
}

#pragma mark - the player

- (void)takeState:(SPTPlayerState *)state {
    if (!queueValue(state, @"queueRevision") || ![SGPlayerInstance() respondsToSelector:@selector(fetchQueue:on:)]) {
        _fromSnapshot = NO;
        [self showTracks:SGPlayerUpcomingTracks(state, kMaxRows)
                   past:[state.reverse isKindOfClass:NSArray.class] ? state.reverse.reverseObjectEnumerator.allObjects : @[]
                current:state.track];
        return;
    }
    NSArray *key = @[queueValue(state, @"playbackId") ?: NSNull.null,
                     queueValue(state, @"queueRevision") ?: NSNull.null,
                     trackIdentity(state.track) ?: SGURIString(state.track.URI) ?: @""];
    if ([_reportedKey isEqual:key]) return;
    if (_fetching) return;
    _reportedKey = key;
    [self refreshQueue];
}

// The queue Spotify reported: the list shows its very track objects, which a move hands back.
- (void)showQueue:(id<SGRQueueSnapshot>)queue {
    if (_reordering) {
        _heldQueue = queue;
        return;
    }
    _snapshot = queue;
    _fromSnapshot = YES;
    [self showTracks:queue.nextTracks past:queue.prevTracks current:queue.track];
}

- (void)showTracks:(NSArray *)next past:(NSArray *)past current:(SPTPlayerTrack *)current {
    if (_reordering) return;
    _tracks = queueTracks(next, kMaxRows, NO);
    NSArray *history = queueTracks(past, NSUIntegerMax, YES);
    _history = history.count > kHistoryRows ? [history subarrayWithRange:NSMakeRange(history.count - kHistoryRows, kHistoryRows)] : history;
    _current = current;
    NSArray *signature = [self signature];
    // Rebuilt every time, so the rows hold the very objects Spotify reported last (a move hands them back).
    _groups = _musicStyle ? [self musicGroups] : [self sheetGroups];
    if (![_signature isEqual:signature]) {
        _signature = signature;
        NSMutableSet<NSString *> *listed = [NSMutableSet set];
        for (SPTPlayerTrack *track in [[_history arrayByAddingObjectsFromArray:current ? @[current] : @[]] arrayByAddingObjectsFromArray:_tracks]) {
            NSString *uri = SGURIString(track.URI);
            if (uri) [listed addObject:uri];
        }
        [self stopCoversExcept:listed];
        self.tableView.backgroundView = _tracks.count || _history.count || (current && !_musicStyle) ? nil : _empty;
        [self.tableView reloadData];
        [self placeAtUpcoming];
    }
    [self showBlend];
}

- (NSArray *)signature {
    return @[signatureOf(_history), signatureOf(_current ? @[_current] : @[]), signatureOf(_tracks),
             _musicStyle ? [self sourcesOf:_tracks] : @[], @(_musicStyle && _fromSnapshot && queueEditable(_snapshot))];
}

// The sheet's three sections: History, Now Playing and Up Next, the last under its own heading.
- (NSArray<SGRQueueGroup *> *)sheetGroups {
    SGRQueueGroup *history = groupOf(_history.count ? SGL(@"settings.player.queue.history", @"History") : nil, nil, _history, NO);
    SGRQueueGroup *now = groupOf(_current ? SGL(@"settings.player.queue.now", @"Now Playing") : nil, nil, _current ? @[_current] : @[], NO);
    SGRQueueGroup *next = groupOf(nil, nil, _tracks, YES);
    next.upNext = YES;
    return @[history, now, next];
}

- (NSArray<NSNumber *> *)sourcesOf:(NSArray<SPTPlayerTrack *> *)tracks {
    NSMutableArray<NSNumber *> *sources = [NSMutableArray arrayWithCapacity:tracks.count];
    for (SPTPlayerTrack *track in tracks) [sources addObject:@(sourceOf(track))];
    return sources;
}

// The Music app's: History, then the songs to come in runs by where they come from, each under its heading. The song
// playing has none, being the player's own title over the list.
- (NSArray<SGRQueueGroup *> *)musicGroups {
    NSMutableArray<SGRQueueGroup *> *groups = [NSMutableArray array];
    if (_history.count) {
        SGRQueueGroup *history = groupOf(SGL(@"settings.player.queue.history", @"History"), nil, _history, NO);
        history.history = YES;
        [groups addObject:history];
    }
    SGRQueueGroup *controls = groupOf(nil, nil, @[], NO);
    controls.controls = YES;
    [groups addObject:controls];
    BOOL context = NO;
    NSMutableArray<SPTPlayerTrack *> *run = nil;
    SGRQueueSource runSource = SGRQueueSourceContext;
    for (SPTPlayerTrack *track in [_tracks arrayByAddingObject:(id)NSNull.null]) {
        BOOL end = track == (id)NSNull.null;
        SGRQueueSource source = end ? runSource : sourceOf(track);
        if (run.count && (end || source != runSource)) {
            NSString *title, *subtitle = nil;
            if (runSource == SGRQueueSourceQueued) {
                title = SGL(@"settings.player.queue.playing_next", @"Playing Next");
            } else if (runSource == SGRQueueSourceAutoplay) {
                title = context ? SGL(@"settings.player.queue.autoplay", @"Autoplay") : SGL(@"settings.player.queue.continue", @"Continue Playing");
                subtitle = SGL(@"settings.player.queue.autoplaying", @"Autoplaying similar music");
            } else {
                title = SGL(@"settings.player.queue.continue", @"Continue Playing");
                context = YES;
            }
            [groups addObject:groupOf(title, subtitle, run, YES)];
            run = nil;
        }
        if (end) break;
        if (!run) run = [NSMutableArray array];
        runSource = source;
        [run addObject:track];
    }
    return groups;
}

- (NSUInteger)firstUpcomingSection {
    for (NSUInteger i = 0; i < _groups.count; i++) {
        if (_groups[i].upcoming && _groups[i].tracks.count) return i;
    }
    return NSNotFound;
}

- (NSUInteger)controlsSection {
    for (NSUInteger i = 0; i < _groups.count; i++) if (_groups[i].controls) return i;
    return NSNotFound;
}

// Where the list rests: the player's thumbnail and title over the toggles at its top, History above, out of sight.
- (CGFloat)restOffset {
    UITableView *table = self.tableView;
    NSUInteger controls = [self controlsSection];
    if (controls == NSNotFound) return -table.adjustedContentInset.top;
    return CGRectGetMinY([table rectForSection:(NSInteger)controls]) - table.adjustedContentInset.top;
}

// The Music app's list opens at rest, and goes back to it for each new song while nobody is scrolling it. The rows
// under the toggles always reach the bottom of the list, so the rest can be scrolled to however few songs are left.
- (void)placeAtUpcoming {
    if (!_musicStyle || !self.isViewLoaded) return;
    UITableView *table = self.tableView;
    if (table.bounds.size.height < 1) return;
    [table layoutIfNeeded];
    NSUInteger controls = [self controlsSection];
    CGFloat below = controls == NSNotFound ? 0 : table.contentSize.height - CGRectGetMinY([table rectForSection:(NSInteger)controls]);
    CGFloat room = MAX(0, table.bounds.size.height - table.adjustedContentInset.top - below);
    if (fabs(table.contentInset.bottom - room) > 0.5) {
        UIEdgeInsets inset = table.contentInset;
        inset.bottom = room;
        table.contentInset = inset;
    }
    NSString *track = [NSString stringWithFormat:@"%@\t%.1f", SGURIString(_current.URI) ?: @"", self.headHeight];
    if ([_placedFor isEqualToString:track] || table.tracking || table.dragging || table.decelerating) {
        [self reportScroll];
        return;
    }
    _placedFor = track;
    table.contentOffset = CGPointMake(0, [self restOffset]);
    [self reportScroll];
}

- (void)goToRest {
    _placedFor = nil;
    [self placeAtUpcoming];
}

- (void)reportScroll {
    if (!_musicStyle || !self.scrolled || !self.isViewLoaded) return;
    self.scrolled(round(self.tableView.contentOffset.y - [self restOffset]));
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self reportScroll];
}

- (void)setHeadHeight:(CGFloat)headHeight {
    if (fabs(headHeight - _headHeight) < 0.5) return;
    _headHeight = headHeight;
    if (!self.isViewLoaded) return;
    [self.tableView reloadData];
    [self placeAtUpcoming];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self placeAtUpcoming];
}

- (void)refreshQueue {
    id<SGRQueuePlayer> player = SGPlayerInstance();
    SPTPlayerState *state = SGPlayerState();
    // The state's lists until the queue comes: shown, but not Spotify's queue objects, so nothing moves meanwhile.
    if (!_fromSnapshot || !_snapshot) {
        [self showTracks:SGPlayerUpcomingTracks(state, kMaxRows)
                   past:[state.reverse isKindOfClass:NSArray.class] ? state.reverse.reverseObjectEnumerator.allObjects : @[]
                current:state.track];
    }
    if (![player respondsToSelector:@selector(fetchQueue:on:)]) return;
    _fetching = YES;
    NSArray *reported = _reportedKey;
    __weak typeof(self) weakSelf = self;
    [player fetchQueue:^(id<SGRQueueSnapshot> queue) {
        typeof(self) self = weakSelf;
        if (!self) return;
        self->_fetching = NO;
        if (![queue respondsToSelector:@selector(nextTracks)] || ![queue respondsToSelector:@selector(prevTracks)] ||
            ![queue respondsToSelector:@selector(track)] ||
            (queue.nextTracks && ![queue.nextTracks isKindOfClass:NSArray.class]) ||
            (queue.prevTracks && ![queue.prevTracks isKindOfClass:NSArray.class])) return;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            SGLog(@"redesign queue: Spotify's queue is %@, %@", NSStringFromClass([(NSObject *)queue class]),
                  queueEditable(queue) ? @"songs can be moved" : @"songs stay where they are");
        });
        [self showQueue:queue];
        // A report received while fetching must not be lost.
        if ([self->_reportedKey isEqual:reported]) [self takeState:SGPlayerState()];
    } on:dispatch_get_main_queue()];
}

- (void)playerStateDidReport:(SPTPlayerState *)state {
    if (self.isViewLoaded) [self takeState:state];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (self.isViewLoaded) [self takeState:state];
}

#pragma mark - the covers

// What a row shows until its cover is in, or for a track without one: the shape the cover takes, faintly.
static UIImage *coverPlaceholder(void) {
    static UIImage *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(kCoverSide, kCoverSide);
        placeholder = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor colorWithWhite:1 alpha:0.12] setFill];
            UIRectFill((CGRect){CGPointZero, size});
        }];
    });
    return placeholder;
}

// The cover the metadata names for `track` once it is in; until then nil, and it is asked for once, only while the list
// is on screen (a row set up as it goes away would start a download nothing cancels). Rows showing the track take it as
// it lands.
- (UIImage *)coverOf:(SPTPlayerTrack *)track {
    NSString *uri = SGURIString(track.URI);
    if (!uri) return nil;
    UIImage *cover = [_covers objectForKey:uri];
    if (cover) return cover;
    if (_coming[uri] || !self.viewIfLoaded.window) return nil;
    __weak typeof(self) weakSelf = self;
    NSProgress *coming = SGRPlayerTrackCover(track, YES, ^(UIImage *image) {
        typeof(self) self = weakSelf;
        if (!self) return;
        [self->_coming removeObjectForKey:uri];
        if (!image) return;
        [self->_covers setObject:image forKey:uri];
        if (self.isViewLoaded) [self showCoverOf:uri];
    });
    // Nil when there was nothing to fetch, `done` having run already.
    if (coming) _coming[uri] = coming;
    return nil;
}

// Cancels the covers on their way for every track but those in `kept` (all of them for nil).
- (void)stopCoversExcept:(NSSet<NSString *> *)kept {
    for (NSString *uri in _coming.allKeys) {
        if ([kept containsObject:uri]) continue;
        [_coming[uri] cancel];
        [_coming removeObjectForKey:uri];
    }
}

- (void)showCoverOf:(NSString *)uri {
    NSMutableArray<NSIndexPath *> *rows = [NSMutableArray array];
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        SPTPlayerTrack *track = [self trackAt:path];
        if ([SGURIString(track.URI) isEqualToString:uri]) [rows addObject:path];
    }
    if (rows.count) [self.tableView reconfigureRowsAtIndexPaths:rows];
}

- (SGRQueueGroup *)groupAt:(NSInteger)section {
    return section >= 0 && section < (NSInteger)_groups.count ? _groups[(NSUInteger)section] : nil;
}

- (SPTPlayerTrack *)trackAt:(NSIndexPath *)path {
    NSArray<SPTPlayerTrack *> *tracks = [self groupAt:path.section].tracks;
    return path.row >= 0 && path.row < (NSInteger)tracks.count ? tracks[(NSUInteger)path.row] : nil;
}

#pragma mark - the list

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return (NSInteger)_groups.count; }

// The Music app's heading for `group`, the blend under the first heading of the songs to come.
- (void)configureHeading:(SGRQueueMusicHeader *)header section:(NSInteger)section {
    SGRQueueGroup *group = [self groupAt:section];
    header.title.text = group.title;
    header.subtitle.text = group.subtitle;
    [header.blend setText:(NSUInteger)section == [self firstUpcomingSection] ? _blendText : nil];
    header.isAccessibilityElement = NO;
    header.title.accessibilityTraits = UIAccessibilityTraitHeader;
    [header setActionTitle:group.history && group.tracks.count ? SGL(@"settings.player.queue.clear", @"Clear") : nil];
    __weak typeof(self) weakSelf = self;
    header.onAction = group.history ? ^{ [weakSelf clearHistory]; } : nil;
    [header setNeedsLayout];
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    SGRQueueGroup *group = [self groupAt:section];
    if (_musicStyle && group.controls) {
        UITableViewHeaderFooterView *head = [table dequeueReusableHeaderFooterViewWithIdentifier:@"controls"];
        head.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
        UIView *controls = self.controls;
        if (controls && controls.superview != head.contentView) [head.contentView addSubview:controls];
        CGFloat width = table.bounds.size.width;
        controls.frame = CGRectMake(SGRPlayerSideMargin, self.headHeight, MAX(0, width - 2 * SGRPlayerSideMargin), kMusicControlsHeight);
        return head;
    }
    if (_musicStyle) {
        if (!group.tracks.count) return nil;
        SGRQueueMusicHeader *header = [table dequeueReusableHeaderFooterViewWithIdentifier:@"heading"];
        [self configureHeading:header section:section];
        return header;
    }
    return group.upNext && group.tracks.count ? _upNext : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    SGRQueueGroup *group = [self groupAt:section];
    if (_musicStyle && group.controls) return self.headHeight + kMusicControlsHeight;
    if (_musicStyle) {
        if (!group.tracks.count) return CGFLOAT_MIN;
        static SGRQueueMusicHeader *measure;
        if (!measure) measure = [[SGRQueueMusicHeader alloc] initWithReuseIdentifier:nil];
        [self configureHeading:measure section:section];
        return [measure heightForWidth:table.bounds.size.width];
    }
    return group.upNext && group.tracks.count ? [self upNextHeight] : UITableViewAutomaticDimension;
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    SGRQueueGroup *group = [self groupAt:section];
    return _musicStyle || group.upNext ? nil : group.title;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self groupAt:section].tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"track"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"track"];
    cell.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    SPTPlayerTrack *track = [self trackAt:path];
    NSString *title = track.trackTitle, *artist = track.artistName.length ? track.artistName : nil;
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = title;
    content.secondaryText = artist;
    content.textProperties.color = SGRPrimary();
    content.textProperties.font = SGCategoryCappedFont(UIFontTextStyleBody, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
    content.textProperties.numberOfLines = 1;
    content.secondaryTextProperties.color = SGRSecondary();
    content.secondaryTextProperties.font = SGCategoryCappedFont(UIFontTextStyleSubheadline, UIFontWeightRegular, UIContentSizeCategoryAccessibilityMedium);
    content.secondaryTextProperties.numberOfLines = 1;
    content.image = [self coverOf:track] ?: coverPlaceholder();
    content.imageProperties.reservedLayoutSize = CGSizeMake(kCoverSide, kCoverSide);
    content.imageProperties.maximumSize = CGSizeMake(kCoverSide, kCoverSide);
    content.imageProperties.cornerRadius = SGRRadiusThumb;
    if (_musicStyle) {
        // Rows on the player's own background at its margin, as the Music app lays its queue out.
        cell.backgroundColor = UIColor.clearColor;
        UIView *pressed = [UIView new];
        pressed.backgroundColor = [UIColor colorWithWhite:1 alpha:SGRIncreaseContrast() ? 0.16 : 0.08];
        cell.selectedBackgroundView = pressed;
        content.imageProperties.reservedLayoutSize = CGSizeMake(kMusicCoverSide, kMusicCoverSide);
        content.imageProperties.maximumSize = CGSizeMake(kMusicCoverSide, kMusicCoverSide);
        content.imageProperties.cornerRadius = kMusicCoverRadius;
        content.imageToTextPadding = kMusicCoverGap;
        // The Music app's titles stand 2 pt apart (its cell's stack spacing, scaled with the text size).
        content.textToSecondaryTextVerticalPadding = [UIFontMetrics.defaultMetrics scaledValueForValue:2 compatibleWithTraitCollection:cell.traitCollection];
        content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(kMusicRowPad, SGRPlayerSideMargin, kMusicRowPad, SGRPlayerSideMargin);
        cell.showsReorderControl = YES;
    }
    cell.contentConfiguration = content;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = artist ? [NSString stringWithFormat:@"%@, %@", title, artist] : title;
    BOOL playable = [self groupAt:path.section].upcoming;
    cell.accessibilityTraits = playable ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    cell.selectionStyle = playable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)table willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)path {
    // A prepared cell can return without another cellForRow: (even after its download failed).
    UIImage *image = [self coverOf:[self trackAt:path]];
    UIListContentConfiguration *content = (id)cell.contentConfiguration;
    if (image && image != content.image) {
        content.image = image;
        cell.contentConfiguration = content;
    }
}

#pragma mark - moving a song

- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path {
    SGRQueueGroup *group = [self groupAt:path.section];
    return _musicStyle && group.upcoming && group.tracks.count > 1 && _fromSnapshot && queueEditable(_snapshot);
}

// Only rows that move take the table's editing mode: their grip, no indent and no delete button.
- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return [self tableView:table canMoveRowAtIndexPath:path];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path {
    return NO;
}

// A song stays among its own: songs queued by hand, the album or playlist's, autoplay's. Moved past its section's end,
// it stops at the end.
- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from
       toProposedIndexPath:(NSIndexPath *)proposed {
    if (proposed.section == from.section) return proposed;
    NSInteger last = MAX(0, (NSInteger)[self groupAt:from.section].tracks.count - 1);
    return [NSIndexPath indexPathForRow:proposed.section < from.section ? 0 : last inSection:from.section];
}

// UIKit's own calls around a drag (the ones Spotify's queue screen answers), so a report coming in meanwhile does not
// reload the list under the finger.
- (void)tableView:(UITableView *)table willBeginReorderingRowAtIndexPath:(NSIndexPath *)path {
    _reordering = YES;
    // These calls are UIKit's own, not in its headers: should the end never come, the list is not held for good.
    NSUInteger generation = ++_reorderGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && self->_reordering && self->_reorderGeneration == generation) [self endReordering];
    });
}

- (void)tableView:(UITableView *)table didEndReorderingRowAtIndexPath:(NSIndexPath *)path {
    [self endReordering];
}

- (void)tableView:(UITableView *)table didCancelReorderingRowAtIndexPath:(NSIndexPath *)path {
    [self endReordering];
}

- (void)endReordering {
    _reordering = NO;
    id held = _heldQueue;
    _heldQueue = nil;
    if (held) [self showQueue:held];
}

- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    // A queue Spotify reported during the drag is older than this move: dropped, the move's own report follows.
    _heldQueue = nil;
    _reordering = NO;
    if ([from isEqual:to] || from.section != to.section) return;
    SGRQueueGroup *group = [self groupAt:from.section];
    NSMutableArray<SPTPlayerTrack *> *tracks = [group.tracks mutableCopy];
    if (from.row >= (NSInteger)tracks.count || to.row >= (NSInteger)tracks.count) return;
    SPTPlayerTrack *moving = tracks[(NSUInteger)from.row];
    [tracks removeObjectAtIndex:(NSUInteger)from.row];
    [tracks insertObject:moving atIndex:(NSUInteger)to.row];
    // Spotify's whole list, the song taken out and put back before the song now after it in its section (or after the
    // one now before it, at the section's end). Songs past the 50 shown keep their places.
    id<SGRQueueSnapshot> snapshot = _snapshot;
    NSMutableArray *next = [snapshot.nextTracks mutableCopy];
    NSUInteger at = [next indexOfObjectIdenticalTo:moving];
    SPTPlayerTrack *after = to.row + 1 < (NSInteger)tracks.count ? tracks[(NSUInteger)to.row + 1] : nil;
    SPTPlayerTrack *before = to.row > 0 ? tracks[(NSUInteger)to.row - 1] : nil;
    NSUInteger place = NSNotFound;
    if (at != NSNotFound) {
        [next removeObjectAtIndex:at];
        if (after) place = [next indexOfObjectIdenticalTo:after];
        else if (before) {
            place = [next indexOfObjectIdenticalTo:before];
            if (place != NSNotFound) place++;
        }
    }
    if (place == NSNotFound || place > next.count) {
        SGLog(@"redesign queue: the moved song is not in Spotify's queue any more, the list is read again");
        _fromSnapshot = NO;
        [self refreshQueue];
        return;
    }
    [next insertObject:moving atIndex:place];
    group.tracks = tracks;
    NSMutableArray<SPTPlayerTrack *> *upcoming = [NSMutableArray array];
    for (SGRQueueGroup *g in _groups) if (g.upcoming) [upcoming addObjectsFromArray:g.tracks];
    _tracks = upcoming;
    _signature = [self signature];
    id sent = sendQueue(snapshot, next);
    if (!sent) {
        SGLog(@"redesign queue: Spotify's queue could not be set, the list is read again");
        _fromSnapshot = NO;
        [self refreshQueue];
        return;
    }
    _snapshot = sent;
    SGLog(@"redesign queue: moved a song from %ld to %ld of its section (%lu songs to come)", (long)from.row, (long)to.row, (unsigned long)next.count);
    [self showBlend];
    // Spotify reports the new queue with a new revision, which fetches it again (takeState). Should no report come, it is
    // read again here, so the list shows what Spotify kept.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && !self->_reordering && !self->_fetching) [self refreshQueue];
    });
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    SPTPlayerTrack *track = [self trackAt:path];
    SGRQueueGroup *group = [self groupAt:path.section];
    if (!track) return;
    if (_musicStyle && group.history) {
        [self replay:track];
        return;
    }
    if (!group.upcoming) return;
    id<SPTPlayer> player = SGPlayerInstance();
    if (![player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) return;
    // The Music app plays the picked song next and drops the ones before it; Spotify keeps them as played, so History
    // leaves them out.
    if (_musicStyle) {
        NSUInteger at = [_tracks indexOfObjectIdenticalTo:track];
        if (at != NSNotFound && at > 0) hideFromHistory([_tracks subarrayWithRange:NSMakeRange(0, at)]);
    }
    [player skipToNextTrackWithOptions:nil track:track];
    if (!self.embedded) [self close];
}

// A song of History played again, the way Spotify's previous button goes back to one (-[SPTEsperantoPlayer
// skipToPreviousTrackWithOptions:track:], 9.2.0): with its restrictions overridden, as Spotify's own skip to a song in
// the queue sends them (skipToNextTrackWithOptions:track:loggingParams: sets overrideRestrictions), and no seek.
- (void)replay:(SPTPlayerTrack *)track {
    id player = SGPlayerInstance();
    SEL skip = NSSelectorFromString(@"skipToPreviousTrackWithOptions:track:");
    Class optionsClass = NSClassFromString(@"SPTSkipPrevOptions");
    if (![player respondsToSelector:skip] || ![optionsClass instancesRespondToSelector:NSSelectorFromString(@"setOverrideRestrictions:")]) {
        SGLog(@"redesign queue: no way back to a song of History in this Spotify");
        return;
    }
    id options = [optionsClass new];
    ((void (*)(id, SEL, BOOL))objc_msgSend)(options, NSSelectorFromString(@"setOverrideRestrictions:"), YES);
    ((id (*)(id, SEL, id, id))objc_msgSend)(player, skip, options, track);
    SGLog(@"redesign queue: a song of History played again");
}

// Clear on History's heading: its songs go from the list at once, and Spotify is handed its queue with no songs played
// (setPrevTracks: on a copy, then setQueue:options: as a move sends it), so they stay gone.
- (void)clearHistory {
    hideFromHistory(_history);
    id<SGRQueueSnapshot> snapshot = _snapshot;
    SEL setPrev = NSSelectorFromString(@"setPrevTracks:");
    if (_fromSnapshot && queueEditable(snapshot) && [(id)snapshot respondsToSelector:setPrev]) {
        id copy = [(id)snapshot copy];
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(copy, setPrev, @[]);
        id sent = sendQueue(copy, snapshot.nextTracks ?: @[]);
        if (sent) _snapshot = sent;
    }
    SGLog(@"redesign queue: History cleared (%lu songs)", (unsigned long)_history.count);
    [self showTracks:_snapshot ? ((id<SGRQueueSnapshot>)_snapshot).nextTracks : _tracks
                past:_snapshot ? ((id<SGRQueueSnapshot>)_snapshot).prevTracks : _history current:_current];
}

@end

#pragma mark - the Music app's toggles

// The toggles over the Music app's queue: shuffle, repeat and AutoMix, 13 pt apart (its NowPlayingQueueControlsView's
// stack), each a capsule as tall as measured on its player. Off, a faint capsule with the glyph in white; on, the
// capsule in the light the footer's disc is drawn in (PlayerFooter.x) with the glyph cut out of it, so the backdrop
// shows through, and under Increase Contrast a white capsule with the glyph in black. The faint capsule is white 0.1,
// measured on its player as 20 of 255 over the backdrop.
static const CGFloat kToggleGap = 13, kToggleGlyph = 17;
static const CGFloat kToggleOnAdd = 0.46, kToggleOffAdd = 0.08, kToggleOffAlpha = 0.1;
// A toggle Spotify will not change stands this faint (UIKit's content disabled alpha, which the Music app's queue asks for).
static const CGFloat kToggleDisabledAlpha = 0.3;
// The list fades into the toggles over it and toward the progress bar under it.
static const CGFloat kListFadeTop = 12, kListFadeBottom = 24;

// AutoMix's glyph, drawn here in the Music app's way (its transitions button: two strokes crossing as one song blends
// into the next, the one coming in over the one going out, which is fainter). No SF Symbol draws it; a template image,
// so it takes the toggle's color and is cut out of the lit capsule like a symbol.
static const CGFloat kMixGlyphWidth = 17, kMixGlyphHeight = 12, kMixStroke = 2.2, kMixGoingAlpha = 0.55;

static UIImage *mixGlyph(void) {
    CGSize size = CGSizeMake(kMixGlyphWidth, kMixGlyphHeight);
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat inset = kMixStroke / 2, left = inset, right = size.width - inset, top = inset, bottom = size.height - inset;
        CGFloat mid = size.width / 2;
        // Each stroke leaves its end level and turns through the middle, an S on its side.
        UIBezierPath *going = [UIBezierPath bezierPath];
        [going moveToPoint:CGPointMake(left, top)];
        [going addCurveToPoint:CGPointMake(right, bottom) controlPoint1:CGPointMake(mid, top) controlPoint2:CGPointMake(mid, bottom)];
        UIBezierPath *coming = [UIBezierPath bezierPath];
        [coming moveToPoint:CGPointMake(left, bottom)];
        [coming addCurveToPoint:CGPointMake(right, top) controlPoint1:CGPointMake(mid, bottom) controlPoint2:CGPointMake(mid, top)];
        for (UIBezierPath *path in @[going, coming]) {
            path.lineWidth = kMixStroke;
            path.lineCapStyle = kCGLineCapRound;
        }
        [[UIColor colorWithWhite:0 alpha:kMixGoingAlpha] setStroke];
        [going stroke];
        // The one coming in is drawn over a gap cut in the one going out, so the two read apart where they cross.
        CGContextSetBlendMode(context.CGContext, kCGBlendModeClear);
        UIBezierPath *gap = [coming copy];
        gap.lineWidth = kMixStroke * 2;
        [gap stroke];
        CGContextSetBlendMode(context.CGContext, kCGBlendModeNormal);
        [UIColor.blackColor setStroke];
        [coming stroke];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface SGRQueueToggle : UIControl
@property (nonatomic, copy) NSString *symbol;
// Drawn in place of a symbol (AutoMix's glyph); the symbol is then only a name for the drawing.
@property (nonatomic, strong) UIImage *drawnGlyph;
// A tap opens this menu instead of calling onTap (the sleep timer's).
@property (nonatomic, copy) UIMenu *(^menu)(void);
@property (nonatomic) BOOL on;
@property (nonatomic, copy) void (^onTap)(void);
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@implementation SGRQueueToggle {
    UIImageView *_plate;
    SGRGlyphView *_glyph;
    NSArray *_drawn;
}

- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _symbol = [symbol copy];
    _plate = [UIImageView new];
    _plate.userInteractionEnabled = NO;
    _glyph = [[SGRGlyphView alloc] initWithSymbol:symbol pointSize:kToggleGlyph weight:UIImageSymbolWeightSemibold];
    _glyph.tintColor = SGRPrimary();
    [self addSubview:_plate];
    [self addSubview:_glyph];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = title;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.showsLargeContentViewer = YES;
    self.largeContentTitle = title;
    self.largeContentImage = _glyph.image;
    [self addInteraction:[UILargeContentViewerInteraction new]];
    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    __weak typeof(self) weakSelf = self;
    SGRBackdropInkObserve(self, ^{ [weakSelf setNeedsLayout]; });
    return self;
}

- (void)tapped {
    if (self.onTap) self.onTap();
}

- (void)setSymbol:(NSString *)symbol {
    if ([symbol isEqualToString:_symbol]) return;
    _symbol = [symbol copy];
    [_glyph setSymbol:symbol animated:self.window != nil];
    self.largeContentImage = _glyph.image;
    [self setNeedsLayout];
}

- (void)setMenu:(UIMenu *(^)(void))menu {
    _menu = [menu copy];
    self.contextMenuInteractionEnabled = menu != nil;
    self.showsMenuAsPrimaryAction = menu != nil;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    UIMenu *(^menu)(void) = self.menu;
    if (!menu) return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) { return menu(); }];
}

- (void)setDrawnGlyph:(UIImage *)drawnGlyph {
    _drawnGlyph = drawnGlyph;
    _glyph.image = drawnGlyph;
    self.largeContentImage = drawnGlyph;
    _drawn = nil;
    [self setNeedsLayout];
}

- (void)setOn:(BOOL)on {
    [self setOn:on animated:NO];
}

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    if (on == _on) return;
    _on = on;
    self.accessibilityTraits = UIAccessibilityTraitButton | (on ? UIAccessibilityTraitSelected : 0) | (self.enabled ? 0 : UIAccessibilityTraitNotEnabled);
    if (!animated || SGRReduceMotion() || !self.window) {
        [self setNeedsLayout];
        return;
    }
    [UIView transitionWithView:self duration:SGRCrossfade options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                    animations:^{ [self setNeedsLayout]; [self layoutIfNeeded]; } completion:nil];
}

// Pressed, the toggle dims to 0.6 as the Music app's buttons do; unusable, it stands at UIKit's disabled alpha.
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    CGFloat alpha = !self.enabled ? kToggleDisabledAlpha : highlighted ? 0.6 : 1;
    SGRAnimate(highlighted ? SGRMotionRespond : SGRMotionFade, ^{ self.alpha = alpha; }, nil);
}

- (void)setEnabled:(BOOL)enabled {
    BOOL changed = enabled != self.enabled;
    [super setEnabled:enabled];
    self.accessibilityTraits = (self.accessibilityTraits & ~UIAccessibilityTraitNotEnabled) | (enabled ? 0 : UIAccessibilityTraitNotEnabled);
    if (!changed) return;
    void (^dim)(void) = ^{ self.alpha = enabled ? 1 : kToggleDisabledAlpha; };
    if (self.window) SGRAnimate(SGRMotionFade, dim, nil);
    else dim();
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsLayout];
}

// The capsule as an image: its fill, and while on, the glyph's shape out of it (in black on it under Increase Contrast).
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _plate.frame = bounds;
    [_glyph sizeToFit];
    _glyph.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    BOOL contrast = SGRIncreaseContrast(), on = _on;
    _glyph.tintColor = on ? UIColor.clearColor : SGRPrimary();
    CGFloat alpha = on ? (contrast ? 1 : SGRInkPlainAlpha(self, kToggleOnAdd, kToggleOnAdd))
                       : (contrast ? 2 * kToggleOffAlpha : SGRInkPlainAlpha(self, kToggleOffAlpha, kToggleOffAdd));
    NSArray *drawn = @[NSStringFromCGSize(bounds.size), _symbol ?: @"", @(on), @(contrast), @(alpha), @(self.traitCollection.displayScale)];
    if ([drawn isEqual:_drawn] || bounds.size.width < 1 || bounds.size.height < 1) return;
    _drawn = drawn;
    UIImage *glyph = on ? [_glyph.image imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] : nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:self.traitCollection];
    _plate.image = [[[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithWhite:1 alpha:alpha] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, bounds.size} cornerRadius:bounds.size.height / 2] fill];
        if (!glyph) return;
        // drawInRect:blendMode:alpha:, not drawInRect:, which draws in the normal mode whatever the context's is.
        CGSize size = glyph.size;
        [glyph drawInRect:CGRectMake((bounds.size.width - size.width) / 2, (bounds.size.height - size.height) / 2, size.width, size.height)
                blendMode:contrast ? kCGBlendModeNormal : kCGBlendModeDestinationOut alpha:1];
    }];
}

@end

#pragma mark - the Music app's page

@interface SGRPlayerQueuePageController : UIViewController <SGPlayerStateObserver>
- (void)setHeadHeight:(CGFloat)height scrolled:(void (^)(CGFloat shift))scrolled;
@end

@implementation SGRPlayerQueuePageController {
    CGFloat _headHeight;
    void (^_scrolled)(CGFloat shift);
    SGRQueueToggle *_shuffle, *_repeat, *_sleep, *_mix;
    UIStackView *_toggles;
    UIView *_holder;
    CAGradientLayer *_fade;
    SGRPlayerQueueController *_list;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.accessibilityIdentifier = @"retrine.player.queue.page";
    _shuffle = [[SGRQueueToggle alloc] initWithSymbol:@"shuffle" title:SGL(@"settings.player.ipad.shuffle", @"Shuffle")];
    _shuffle.onTap = ^{
        SPTPlayerState *state = SGPlayerState();
        id<SPTPlayer> player = (id<SPTPlayer>)SGPlayer();
        if ([player respondsToSelector:@selector(setShufflingContext:)]) [player setShufflingContext:!state.options.shufflingContext];
    };
    _repeat = [[SGRQueueToggle alloc] initWithSymbol:@"repeat" title:SGL(@"settings.player.ipad.repeat", @"Repeat")];
    _repeat.onTap = ^{
        SGPlayerAdvanceRepeat((id<SPTPlayer>)SGPlayer(), SGPlayerState().options);
    };
    __weak typeof(self) weakSelf = self;
    // The Music app's third is Autoplay, which Spotify keeps in its core settings with no call an app's code can make
    // (player.autoplay, read and written only inside its Swift settings). In its place Retrine's own control of what plays
    // on: the sleep timer (Shared/Player/SleepTimer.h), on while one is set, its choices in a menu.
    _sleep = [[SGRQueueToggle alloc] initWithSymbol:@"moon.zzz" title:SGL(@"settings.player.queue.sleep", @"Sleep Timer")];
    _sleep.menu = ^UIMenu *{ return [weakSelf sleepMenu]; };
    // The Music app's fourth, its transitions button: AutoMix, the switch Mod Settings > AutoMix has.
    _mix = [[SGRQueueToggle alloc] initWithSymbol:@"automix" title:SGL(@"settings.automix.title", @"AutoMix")];
    _mix.drawnGlyph = mixGlyph();
    _mix.onTap = ^{
        BOOL on = !SGFlag(SGKeyAutoMix, NO);
        SGSetEnabled(SGKeyAutoMix, on);
        SGAutoMixApply(on);
        [weakSelf showOptions:YES];
    };
    _toggles = [[UIStackView alloc] initWithArrangedSubviews:@[_shuffle, _repeat, _sleep, _mix]];
    _toggles.axis = UILayoutConstraintAxisHorizontal;
    _toggles.distribution = UIStackViewDistributionFillEqually;
    _toggles.spacing = kToggleGap;
    _holder = [UIView new];
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _holder.layer.mask = _fade;
    _list = [[SGRPlayerQueueController alloc] initMusicStyle];
    // The toggles ride in the list, under the room the player's thumbnail and title stand in.
    _list.controls = _toggles;
    _list.headHeight = _headHeight;
    _list.scrolled = _scrolled;
    [self addChildViewController:_list];
    [_holder addSubview:_list.view];
    [_list didMoveToParentViewController:self];
    [self.view addSubview:_holder];
    [self showOptions:NO];
    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(transitionsChanged) name:SGTransitionSettingsDidChangeNotification object:nil];
}

- (void)transitionsChanged {
    [self showOptions:YES];
}

// The sleep timer's choices, the one set checked: the Live Activity's (Shared/LiveActivity), Off while one is set.
- (UIMenu *)sleepMenu {
    SGSleepTimerMode mode = SGSleepTimerCurrentMode();
    __weak typeof(self) weakSelf = self;
    UIAction *(^choice)(NSString *, SGSleepTimerMode, NSTimeInterval, BOOL) = ^UIAction *(NSString *title, SGSleepTimerMode set, NSTimeInterval seconds, BOOL on) {
        UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *a) {
            SGSetSleepTimer(set, seconds);
            [weakSelf showOptions:YES];
        }];
        action.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
        return action;
    };
    NSMutableArray<UIMenuElement *> *times = [NSMutableArray array];
    for (NSNumber *minutes in @[@15, @30, @45, @60]) {
        NSString *title = [NSString stringWithFormat:SGL(@"settings.player.queue.sleep.minutes", @"%ld min"), (long)minutes.integerValue];
        [times addObject:choice(title, SGSleepTimerAtTime, minutes.integerValue * 60, NO)];
    }
    NSArray<UIMenuElement *> *ends = @[
        choice(SGL(@"settings.player.queue.sleep.track", @"End of Song"), SGSleepTimerEndOfTrack, 0, mode == SGSleepTimerEndOfTrack),
        choice(SGL(@"settings.player.queue.sleep.album", @"End of Album or Playlist"), SGSleepTimerEndOfAlbum, 0, mode == SGSleepTimerEndOfAlbum),
    ];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    if (mode != SGSleepTimerOff) {
        UIAction *off = choice(SGL(@"common.off", @"Off"), SGSleepTimerOff, 0, NO);
        off.attributes = UIMenuElementAttributesDestructive;
        [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[off]]];
    }
    [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:ends]];
    [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:times]];
    NSString *title = SGL(@"settings.player.queue.sleep", @"Sleep Timer");
    NSDate *end = SGSleepTimerEnd();
    if (mode == SGSleepTimerAtTime && end) {
        NSDateComponentsFormatter *left = [NSDateComponentsFormatter new];
        left.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute;
        left.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
        NSString *remaining = [left stringFromTimeInterval:MAX(60, end.timeIntervalSinceNow)];
        if (remaining) title = [NSString stringWithFormat:SGL(@"settings.player.queue.sleep.left", @"Sleep Timer, %@ left"), remaining];
    }
    return [UIMenu menuWithTitle:title children:children];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGRect list = bounds;
    if (!CGRectEqualToRect(_holder.frame, list)) _holder.frame = list;
    _list.view.frame = _holder.bounds;
    CGFloat height = MAX(1, list.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.frame = _holder.bounds;
    _fade.locations = @[@0, @(MIN(0.5, kListFadeTop / height)), @(MAX(0.5, 1 - kListFadeBottom / height)), @1];
    [CATransaction commit];
}

// Whether the player's restrictions say no to `name` (-[SPTPlayerRestrictions disallowTogglingShuffle] and the like,
// BOOL properties, 9.2.0), read from the state Spotify reported. Radio and autoplay publish shuffle and repeat ones that
// Shared/AdBlock/RadioModes.m lifts when it is on; with them up, Spotify drops the command, so the toggle is dimmed.
static BOOL restricted(SPTPlayerState *state, NSString *name) {
    id restrictions = queueValue(state, @"restrictions");
    SEL selector = NSSelectorFromString(name);
    if (![restrictions respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(restrictions, selector);
}

// Shuffle and repeat as the player reports them, repeat with its 1 while it repeats the song; AutoMix as its switch is,
// only for an account that has it. Dimmed with nothing to play, or where Spotify does not allow the change, the way the
// Music app dims a toggle it cannot use.
- (void)showOptions:(BOOL)animated {
    if (!self.isViewLoaded) return;
    SPTPlayerState *state = SGPlayerState();
    SPTPlayerOptions *options = state.options;
    BOOL playable = state.track != nil, track = options.repeatingTrack, context = options.repeatingContext;
    animated = animated && self.view.window;
    [_shuffle setOn:options.shufflingContext animated:animated];
    [_repeat setOn:track || context animated:animated];
    _repeat.symbol = track ? @"repeat.1" : @"repeat";
    NSString *on = SGL(@"common.on", @"On"), *off = SGL(@"common.off", @"Off");
    _shuffle.accessibilityValue = options.shufflingContext ? on : off;
    _repeat.accessibilityValue = track ? SGL(@"settings.player.ipad.repeat.one", @"One") : context ? SGL(@"settings.player.ipad.repeat.all", @"All") : off;
    BOOL sleeping = SGSleepTimerCurrentMode() != SGSleepTimerOff;
    [_sleep setOn:sleeping animated:animated];
    _sleep.accessibilityValue = sleeping ? on : off;
    BOOL mix = SGFlag(SGKeyAutoMix, NO);
    [_mix setOn:mix animated:animated];
    _mix.accessibilityValue = mix ? on : off;
    BOOL mixShown = SGAutoMixAccountAllows();
    if (_mix.hidden == mixShown) _mix.hidden = !mixShown;
    BOOL shuffles = playable && !restricted(state, @"disallowTogglingShuffle");
    // Repeat goes off, then the context, then the song: usable while any step of it is.
    BOOL repeats = playable && !(restricted(state, @"disallowTogglingRepeatContext") && restricted(state, @"disallowTogglingRepeatTrack"));
    if (_shuffle.enabled != shuffles) _shuffle.enabled = shuffles;
    if (_repeat.enabled != repeats) _repeat.enabled = repeats;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self showOptions:YES];
}

// Repeat is not among what a change is reported for: every report is looked at.
- (void)playerStateDidReport:(SPTPlayerState *)state {
    [self showOptions:YES];
}

- (void)setHeadHeight:(CGFloat)height scrolled:(void (^)(CGFloat shift))scrolled {
    _headHeight = height;
    _scrolled = [scrolled copy];
    if (!self.isViewLoaded) return;
    _list.scrolled = _scrolled;
    _list.headHeight = height;
    // The page opens, or turns from the lines, at rest: the thumbnail and title over the toggles where they were placed.
    [_list goToRest];
}

@end

UIViewController *SGRPlayerQueuePage(void) {
    return [SGRPlayerQueuePageController new];
}

void SGRPlayerQueuePageConfigure(UIViewController *page, CGFloat headHeight, void (^scrolled)(CGFloat shift)) {
    if ([page isKindOfClass:SGRPlayerQueuePageController.class]) [(SGRPlayerQueuePageController *)page setHeadHeight:headHeight scrolled:scrolled];
}

#pragma mark - opening it

NSNotificationName const SGRQueueSheetPlacedNotification = @"SGRQueueSheetPlaced";

@interface SGRQueueSheet : UINavigationController
@end
@implementation SGRQueueSheet
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.isBeingDismissed)
        [NSNotificationCenter.defaultCenter postNotificationName:SGRQueueSheetPlacedNotification object:self.view];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRQueueSheetPlacedNotification object:self.view];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSNotificationCenter.defaultCenter postNotificationName:SGRQueueSheetPlacedNotification object:nil];
}
@end

// The controller on top in `from`'s window, through whatever is presented over it; the key window's without one.
static UIViewController *topIn(UIView *from) {
    UIViewController *top = from.window.rootViewController;
    if (!top) return SGTopController();
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

UIViewController *SGRPlayerQueueList(void) {
    SGRPlayerQueueController *list = [SGRPlayerQueueController new];
    list.embedded = YES;
    return list;
}

void SGRPlayerShowQueue(UIView *from) {
    UINavigationController *navigation = [[SGRQueueSheet alloc] initWithRootViewController:[SGRPlayerQueueController new]];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    SGPresentDark(navigation);
    UISheetPresentationController *sheet = navigation.sheetPresentationController;
    sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    sheet.prefersGrabberVisible = YES;
    sheet.prefersEdgeAttachedInCompactHeight = YES;
    sheet.prefersScrollingExpandsWhenScrolledToEdge = YES;
    // Picked from the system menu, which is still going away: the sheet waits for it, as the sound panel does.
    __weak UIView *weakFrom = from;
    __block int tries = 0;
    __block void (^present)(void);
    present = ^{
        UIViewController *top = topIn(weakFrom);
        if ((top.isBeingDismissed || top.isBeingPresented || top.transitionCoordinator) && ++tries < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), present);
            return;
        }
        present = nil;
        if (!top) return;
        if ([top isKindOfClass:UINavigationController.class]
            && [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:SGRPlayerQueueController.class]) return;
        [top presentViewController:navigation animated:YES completion:nil];
    };
    dispatch_async(dispatch_get_main_queue(), present);
}
