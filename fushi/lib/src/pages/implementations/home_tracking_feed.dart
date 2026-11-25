/// The home Tracking widget's "Last synced" view ([HomeWidgetKind.tracking]).
///
/// When nothing blocks tracking (no site wants a new sign-in, no title waits
/// to be linked) the widget shows sends instead of counts: the newest update
/// leads with its cover, what it sent and where it went, and a bigger cell
/// adds the updates before it, then each site and a 7-day count. A failed
/// update that keeps retrying leads in red ("Send failed"), queued updates
/// lead in amber ("Sending").
///
/// [HomeTrackingFeed.of] decides whether this view applies; the problems
/// layout and the status line stay in `home_tracking_panel.dart`.
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart'
    show trackingSendLabel;
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show formatActivityRelativeTime;
import 'package:fushi/src/pages/implementations/home_tracking_panel.dart'
    show HomeTrackingSummary;
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/media_tracking_recent_sends.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show TrackingKind, TrackingMediaType;
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';

/// Which update leads the widget.
enum HomeTrackingFeedState {
  /// The newest update the sites accepted.
  synced,

  /// An update whose last attempt failed; it stays queued and is retried.
  failed,

  /// Updates waiting to be sent (offline, or the next sync has not run).
  sending,
}

/// One site that is on and signed in, for the wide widget's site column.
typedef HomeTrackingSiteLine = ({
  String id,
  String name,
  int lastSyncAt,
  int linked,
});

/// What the "Last synced" view shows, read from one snapshot.
class HomeTrackingFeed {
  const HomeTrackingFeed({
    required this.state,
    required this.hero,
    required this.earlier,
    required this.sentToday,
    required this.waiting,
    required this.week,
    required this.sites,
    required this.siteNames,
  });

  /// The view for [snapshot], or null when the widget keeps its other
  /// layouts: no site connected, a site wants a new sign-in or titles wait
  /// to be linked (the problems layout), or nothing was ever sent or queued
  /// (the status line).
  ///
  /// [now] fixes "today" (local midnight) and the 7-day window.
  static HomeTrackingFeed? of(
    MediaTrackingHomeSnapshot snapshot,
    HomeTrackingSummary summary,
    DateTime now,
  ) {
    if (summary.connected == 0) return null;
    if (summary.signInNeeded > 0 || summary.unlinked > 0) return null;
    final List<MediaTrackingRecentSend> queued = snapshot.queuedSends;
    final List<MediaTrackingRecentSend> sent = <MediaTrackingRecentSend>[
      for (final MediaTrackingRecentSend s in snapshot.recentSends())
        if (s.state == MediaTrackingSendState.sent) s,
    ];
    final HomeTrackingFeedState state;
    final MediaTrackingRecentSend hero;
    if (summary.failed > 0) {
      // A failing update leads; without one to show (only ignored items
      // fail) the problems layout says it instead.
      final List<MediaTrackingRecentSend> failing = <MediaTrackingRecentSend>[
        for (final MediaTrackingRecentSend q in queued)
          if (q.state == MediaTrackingSendState.failed) q,
      ];
      if (failing.isEmpty) return null;
      state = HomeTrackingFeedState.failed;
      hero = failing.first;
    } else if (queued.isNotEmpty) {
      state = HomeTrackingFeedState.sending;
      hero = queued.first;
    } else if (sent.isNotEmpty) {
      state = HomeTrackingFeedState.synced;
      hero = sent.first;
    } else {
      return null;
    }
    final DateTime midnight = DateTime(now.year, now.month, now.day);
    final Map<String, int> linkedBySite = <String, int>{};
    final Set<String> seen = <String>{};
    for (final MediaTrackingMappingRow mapping in snapshot.mappings) {
      if (seen.add(
        '${mapping.provider}|${mapping.mediaType}|${mapping.mediaKey}',
      )) {
        linkedBySite.update(
          mapping.provider,
          (int n) => n + 1,
          ifAbsent: () => 1,
        );
      }
    }
    return HomeTrackingFeed(
      state: state,
      hero: hero,
      earlier: <MediaTrackingRecentSend>[
        for (final MediaTrackingRecentSend s in sent)
          if (s.titleKey != hero.titleKey) s,
      ],
      sentToday: snapshot
          .sendTotalsSince(midnight.millisecondsSinceEpoch)
          .titles,
      waiting: queued.length,
      week: snapshot.sendTotalsSince(
        now.subtract(const Duration(days: 7)).millisecondsSinceEpoch,
      ),
      sites: <HomeTrackingSiteLine>[
        for (final MediaTrackingProviderStatus site in snapshot.sites)
          if (site.enabled && site.configured)
            (
              id: site.providerId,
              name: snapshot.siteNames[site.providerId] ?? site.providerId,
              lastSyncAt: site.lastSyncAt,
              linked: linkedBySite[site.providerId] ?? 0,
            ),
      ],
      siteNames: snapshot.siteNames,
    );
  }

  final HomeTrackingFeedState state;

  /// The update that leads.
  final MediaTrackingRecentSend hero;

  /// Accepted updates of other titles, newest first.
  final List<MediaTrackingRecentSend> earlier;

  /// Titles that got an accepted update since local midnight.
  final int sentToday;

  /// Titles with an update in the outbox.
  final int waiting;

  /// Accepted updates in the last 7 days.
  final MediaTrackingSendTotals week;

  /// Sites that are on and signed in, in registry order.
  final List<HomeTrackingSiteLine> sites;

  /// Site id -> name as shown to the user.
  final Map<String, String> siteNames;

  /// The site ids of [send] in registry order (the order the Activity rows
  /// came in varies from send to send); sites no longer listed go last.
  List<String> siteIdsOf(MediaTrackingRecentSend send) {
    final List<String> ordered = <String>[
      for (final HomeTrackingSiteLine site in sites)
        if (send.siteIds.contains(site.id)) site.id,
    ];
    return <String>[
      ...ordered,
      for (final String id in send.siteIds)
        if (!ordered.contains(id)) id,
    ];
  }

  /// The sites of [send], by name ("AniList · MyAnimeList").
  String sitesOf(MediaTrackingRecentSend send) => <String>[
    for (final String id in siteIdsOf(send)) siteNames[id] ?? id,
  ].join(' · ');
}

/// Header title of [state].
String homeTrackingFeedTitle(HomeTrackingFeedState state) => switch (state) {
  HomeTrackingFeedState.synced => t.home_tracking_feed_title_synced,
  HomeTrackingFeedState.failed => t.home_tracking_feed_title_failed,
  HomeTrackingFeedState.sending => t.home_tracking_feed_title_sending,
};

/// Header icon of [state].
IconData homeTrackingFeedIcon(HomeTrackingFeedState state) => switch (state) {
  HomeTrackingFeedState.synced => FushiIcons.check,
  HomeTrackingFeedState.failed => FushiIcons.syncProblem,
  HomeTrackingFeedState.sending => FushiIcons.sync,
};

/// Hue of the collage block: green when sent, red when failing, amber while
/// waiting (the problems block keeps its red, `homeTrackingPosterHue`).
double homeTrackingFeedHue(HomeTrackingFeedState state) => switch (state) {
  HomeTrackingFeedState.synced => 140,
  HomeTrackingFeedState.failed => 350,
  HomeTrackingFeedState.sending => 45,
};

/// The line under the hero's title: the sites and when, or for a failing
/// update the sites and that it retries, or for a queued one how many wait.
String homeTrackingFeedMetaLine(HomeTrackingFeed feed, DateTime now) {
  final MediaTrackingRecentSend hero = feed.hero;
  return switch (feed.state) {
    HomeTrackingFeedState.synced => <String>[
      feed.sitesOf(hero),
      formatActivityRelativeTime(hero.at, now),
    ].join(' · '),
    HomeTrackingFeedState.failed => <String>[
      feed.sitesOf(hero),
      t.home_tracking_feed_retrying,
    ].join(' · '),
    HomeTrackingFeedState.sending => <String>[
      feed.sitesOf(hero),
      if (feed.waiting > 1) t.media_tracking_pending_count(n: feed.waiting),
    ].join(' · '),
  };
}

/// "+3 more today": accepted titles today other than the hero, or null.
String? homeTrackingFeedMoreToday(HomeTrackingFeed feed) {
  final int more =
      feed.sentToday - (feed.state == HomeTrackingFeedState.synced ? 1 : 0);
  return more > 0 ? t.home_tracking_feed_more_today(n: more) : null;
}

/// What [send] sent, in words ("Episode 12", "Volume 3 · finished in Fushi").
String homeTrackingSendLabel(MediaTrackingRecentSend send) => trackingSendLabel(
  progressMode: send.progressMode,
  progress: send.progress,
  completed: send.completed,
);

/// The icon standing in for a missing cover, by `TrackingKind.value`.
IconData homeTrackingKindIcon(String kind) => switch (kind) {
  _ when kind == TrackingKind.anime.value => FushiIcons.video,
  _ when kind == TrackingKind.manga.value => FushiIcons.manga,
  _ when kind == TrackingKind.game.value => FushiIcons.game,
  _ => FushiIcons.books,
};

/// Where the home page finds the local cover of a tracked item.
enum HomeTrackingCoverSource {
  /// A book in the library (a volume link, or a chapter link of a manga or
  /// light novel; both keyed by the book).
  book,

  /// A local video.
  video,

  /// A video or book collection card (its own cover; a book series falls
  /// back to a volume in it).
  collection,

  /// A game in the game library.
  game,

  /// No local cover (media server episodes and seasons): the kind icon.
  none,
}

/// The cover source of a [TrackingMediaType] `value`; unknown values have
/// none.
HomeTrackingCoverSource homeTrackingCoverSourceOf(String mediaType) {
  for (final TrackingMediaType type in TrackingMediaType.values) {
    if (type.value != mediaType) continue;
    return switch (type) {
      TrackingMediaType.book ||
      TrackingMediaType.bookChapter => HomeTrackingCoverSource.book,
      TrackingMediaType.video => HomeTrackingCoverSource.video,
      TrackingMediaType.videoCollection ||
      TrackingMediaType.bookCollection => HomeTrackingCoverSource.collection,
      TrackingMediaType.game => HomeTrackingCoverSource.game,
      TrackingMediaType.remoteVideo ||
      TrackingMediaType.remoteSeries => HomeTrackingCoverSource.none,
    };
  }
  return HomeTrackingCoverSource.none;
}

/// One place to look for the cover of a book or book series send.
sealed class HomeTrackingCoverStep {
  const HomeTrackingCoverStep();
}

/// The cover of one book (a volume).
final class HomeTrackingBookCover extends HomeTrackingCoverStep {
  const HomeTrackingBookCover(this.bookKey);

  final String bookKey;

  @override
  bool operator ==(Object other) =>
      other is HomeTrackingBookCover && other.bookKey == bookKey;

  @override
  int get hashCode => bookKey.hashCode;

  @override
  String toString() => 'book($bookKey)';
}

/// A series card's own cover.
final class HomeTrackingCardCover extends HomeTrackingCoverStep {
  const HomeTrackingCardCover(this.collectionId);

  final int collectionId;

  @override
  bool operator ==(Object other) =>
      other is HomeTrackingCardCover && other.collectionId == collectionId;

  @override
  int get hashCode => collectionId.hashCode;

  @override
  String toString() => 'card($collectionId)';
}

/// The first volume of a series card that has a cover.
final class HomeTrackingAnyVolumeCover extends HomeTrackingCoverStep {
  const HomeTrackingAnyVolumeCover(this.collectionId);

  final int collectionId;

  @override
  bool operator ==(Object other) =>
      other is HomeTrackingAnyVolumeCover && other.collectionId == collectionId;

  @override
  int get hashCode => collectionId.hashCode;

  @override
  String toString() => 'anyVolume($collectionId)';
}

/// Where to look, in order, for the cover of a book-like send; empty for
/// other media types. A volume or chapter link ([mediaType] `book` /
/// `book_chapter`, keyed by the book) tries its book, then the series card
/// the book is in ([seriesOfBook]) and another volume of it. A series link
/// (`book_collection`) tries the volume it counted ([volumeBookKey]), then
/// the card's cover and another volume. What finds nothing falls back to the
/// kind icon.
List<HomeTrackingCoverStep> homeTrackingBookCoverSteps({
  required String mediaType,
  required String mediaKey,
  int? seriesOfBook,
  String? volumeBookKey,
}) {
  if (mediaType == TrackingMediaType.book.value ||
      mediaType == TrackingMediaType.bookChapter.value) {
    return <HomeTrackingCoverStep>[
      HomeTrackingBookCover(mediaKey),
      if (seriesOfBook != null) ...<HomeTrackingCoverStep>[
        HomeTrackingCardCover(seriesOfBook),
        HomeTrackingAnyVolumeCover(seriesOfBook),
      ],
    ];
  }
  if (mediaType == TrackingMediaType.bookCollection.value) {
    final int? id = int.tryParse(mediaKey);
    return <HomeTrackingCoverStep>[
      if (volumeBookKey != null) HomeTrackingBookCover(volumeBookKey),
      if (id != null) ...<HomeTrackingCoverStep>[
        HomeTrackingCardCover(id),
        HomeTrackingAnyVolumeCover(id),
      ],
    ];
  }
  return const <HomeTrackingCoverStep>[];
}

/// A cover for a send, from the local library; null when none is known.
typedef HomeTrackingCoverOf = Widget? Function(MediaTrackingRecentSend send);

/// The "Last synced" widget: frame, header by state, and a body laid out
/// from the cell's measured size. Tapping anywhere runs [onOpen].
class HomeTrackingFeedCard extends StatelessWidget {
  const HomeTrackingFeedCard({
    super.key,
    required this.feed,
    required this.coverOf,
    required this.onOpen,
    required this.poster,
  });

  final HomeTrackingFeed feed;
  final HomeTrackingCoverOf coverOf;
  final VoidCallback onOpen;

  /// Collage block look instead of the section card.
  final bool poster;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final MediaTrackingRecentSend hero = feed.hero;
    final String title = homeTrackingFeedTitle(feed.state);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) => HomeWidgetFrame(
        key: const ValueKey<String>('home-tracking-panel'),
        tapKey: const ValueKey<String>('home-tracking-panel-open'),
        title: title,
        icon: homeTrackingFeedIcon(feed.state),
        hueKey: HomeWidgetKind.tracking.id,
        hue: homeTrackingFeedHue(feed.state),
        poster: poster,
        dense: homeWidgetIsDense(c.maxHeight),
        attention: feed.state == HomeTrackingFeedState.failed,
        onTap: onOpen,
        semanticLabel: <String>[
          t.home_tracking_panel_title,
          title,
          hero.mediaTitle,
          homeTrackingSendLabel(hero),
          homeTrackingFeedMetaLine(feed, now),
        ].join(', '),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) =>
              AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                switchInCurve: FushiMotion.enter,
                switchOutCurve: FushiMotion.exit,
                layoutBuilder: (Widget? current, List<Widget> previous) =>
                    Stack(
                      alignment: AlignmentDirectional.topStart,
                      children: <Widget>[...previous, ?current],
                    ),
                // A new update cross-fades the body instead of jumping.
                child: KeyedSubtree(
                  key: ValueKey<String>(
                    '${feed.state.name}|${hero.titleKey}|'
                    '${hero.progress}|${hero.completed}',
                  ),
                  child: SizedBox.fromSize(
                    size: box.biggest,
                    child: _FeedBody(
                      feed: feed,
                      coverOf: coverOf,
                      now: now,
                      area: box.biggest,
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
  }
}

// ── Layout thresholds (logical pixels of the content area) ─────────────────

/// Below this height the body is one line of text.
const double _kOneLineMaxHeight = 52;

/// Narrower than this (a one-column cell) the hero is a small cover with a
/// mark and the progress, without the title.
const double _kCompactMaxWidth = 200;

/// The hero row (cover + text) at its narrowest beside the earlier sends.
const double _kHeroRowMinWidth = 250;

/// One earlier send beside the hero in a one-row cell: at least this wide,
/// and up to [_kMiniMaxWidth] when the cell has room to spare.
const double _kMiniWidth = 150;
const double _kMiniMaxWidth = 200;
const double _kMiniGap = 14;

/// From this content height the hero sits on top (or in its own column) and
/// the earlier sends become a list. Two-row cells on the wide grid have about
/// 165–225 (row 104–140, `homeWidgetRowExtent`); on the compact grid (row
/// 76–96) they stay below and keep the one-row layout.
const double _kTallMinHeight = 150;

/// The hero above the list (2×2) at its shortest: cover, title, progress and
/// where / when; a failed send also keeps its error line.
const double _kStackedHeroMinHeight = 66;
const double _kStackedFailedHeroMinHeight = 80;
const double _kStackedHeroMaxHeight = 150;

/// The divider between the stacked hero and the list, with its spacing.
const double _kStackedDividerHeight = 17;

/// Two columns (hero | list) from this width, three (… | sites) from the next.
const double _kTwoColumnMinWidth = 520;
const double _kThreeColumnMinWidth = 800;
const double _kHeroColumnWidth = 300;
const double _kSitesColumnWidth = 230;

/// One row of the list (cover 30×44 plus the gap).
const double _kListRowHeight = 50;

/// Space between the columns, including the divider.
const double _kColumnGap = 16;

class _FeedBody extends StatelessWidget {
  const _FeedBody({
    required this.feed,
    required this.coverOf,
    required this.now,
    required this.area,
  });

  final HomeTrackingFeed feed;
  final HomeTrackingCoverOf coverOf;
  final DateTime now;
  final Size area;

  @override
  Widget build(BuildContext context) {
    if (area.height < _kOneLineMaxHeight) return _oneLine(context);
    if (area.width < _kCompactMaxWidth) return _compact(context);
    if (area.height < _kTallMinHeight) return _row(context);
    if (area.width >= _kTwoColumnMinWidth) return _columns(context);
    return _stacked(context);
  }

  /// A very short cell: "Title · Episode 12 · 52 min".
  Widget _oneLine(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        <String>[
          feed.hero.mediaTitle,
          homeTrackingSendLabel(feed.hero),
          if (feed.state == HomeTrackingFeedState.synced)
            formatActivityRelativeTime(feed.hero.at, now),
        ].join(' · '),
        key: const ValueKey<String>('home-tracking-feed-line'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.fushiType.bodyMedium.copyWith(
          fontWeight: FontWeight.w600,
          color: style.foreground,
        ),
      ),
    );
  }

  /// A one-column cell: the cover with a state mark, the progress and when.
  Widget _compact(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final double coverHeight = (area.height).clamp(40, 72).toDouble();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      spacing: 10,
      children: <Widget>[
        _SendCover(
          send: feed.hero,
          cover: coverOf(feed.hero),
          height: coverHeight,
          mark: feed.state,
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              // The progress first (a second line when it fits), then when;
              // large text drops lines instead of overflowing.
              final TextStyle progressStyle = context.fushiType.labelLarge
                  .copyWith(
                    fontWeight: FontWeight.w700,
                    color: style.foreground,
                  );
              final TextStyle whenStyle = context.fushiType.bodySmall.copyWith(
                color: style.muted,
              );
              final double progressLine = homeWidgetLineHeight(
                context,
                progressStyle,
              );
              final double whenLine = homeWidgetLineHeight(context, whenStyle);
              final bool showWhen = progressLine + whenLine <= box.maxHeight;
              final int progressLines =
                  progressLine * 2 + (showWhen ? whenLine : 0) <= box.maxHeight
                  ? 2
                  : 1;
              final Widget column = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    homeTrackingSendLabel(feed.hero),
                    key: const ValueKey<String>('home-tracking-feed-progress'),
                    maxLines: progressLines,
                    overflow: TextOverflow.ellipsis,
                    style: progressStyle,
                  ),
                  if (showWhen)
                    Text(
                      // The header already names the state: when it went
                      // out, or for a failed / waiting send where to.
                      feed.state == HomeTrackingFeedState.synced
                          ? formatActivityRelativeTime(feed.hero.at, now)
                          : feed.sitesOf(feed.hero),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: whenStyle,
                    ),
                ],
              );
              return progressLine > box.maxHeight
                  ? HomeWidgetOverflowClip(child: column)
                  : Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: column,
                    );
            },
          ),
        ),
      ],
    );
  }

  /// A one-row cell: the hero, then as many earlier sends as fit beside it.
  Widget _row(BuildContext context) {
    final double room = area.width - _kHeroRowMinWidth - _kColumnGap - 1;
    final int fit = (room / (_kMiniWidth + _kMiniGap)).floor().clamp(
      0,
      feed.earlier.length,
    );
    final List<MediaTrackingRecentSend> minis = feed.earlier.take(fit).toList();
    // The minis share the spare room (so "Episode 8 · 40 min ago" is not cut
    // short); the hero keeps the rest.
    final double miniWidth = minis.isEmpty
        ? 0
        : (room / minis.length - _kMiniGap)
              .clamp(_kMiniWidth, _kMiniMaxWidth)
              .toDouble();
    final double heroWidth = minis.isEmpty
        ? area.width
        : area.width -
              (_kColumnGap + 1) -
              minis.length * (miniWidth + _kMiniGap);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: heroWidth,
          child: _Hero(
            feed: feed,
            cover: coverOf(feed.hero),
            now: now,
            coverHeight: area.height,
            showMoreToday: minis.isEmpty,
          ),
        ),
        if (minis.isNotEmpty) ...<Widget>[
          const _Divider(vertical: true),
          for (int i = 0; i < minis.length; i++)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: _kMiniGap),
              child: FushiStaggeredEntrance(
                index: i,
                child: SizedBox(
                  width: miniWidth,
                  child: _SendTile(
                    key: ValueKey<String>(
                      'home-tracking-feed-earlier-${minis[i].titleKey}',
                    ),
                    send: minis[i],
                    cover: coverOf(minis[i]),
                    subtitle: <String>[
                      homeTrackingSendLabel(minis[i]),
                      formatActivityRelativeTime(minis[i].at, now),
                    ].join(' · '),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// A tall but narrow cell (2×2): the hero on top, the list below.
  Widget _stacked(BuildContext context) {
    // As many list rows as fit under the shortest hero; the hero takes the
    // rest (up to its cap; the list measures what it gets).
    final double heroMin = feed.state == HomeTrackingFeedState.failed
        ? _kStackedFailedHeroMinHeight
        : _kStackedHeroMinHeight;
    final int rows =
        ((area.height - _kStackedDividerHeight - heroMin) / _kListRowHeight)
            .floor()
            .clamp(0, feed.earlier.length);
    final double heroHeight = rows == 0
        ? area.height
        : (area.height - _kStackedDividerHeight - rows * _kListRowHeight)
              .clamp(heroMin, _kStackedHeroMaxHeight)
              .toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: heroHeight,
          child: _Hero(
            feed: feed,
            cover: coverOf(feed.hero),
            now: now,
            coverHeight: heroHeight,
            titleLines: 2,
            showMoreToday: rows == 0,
          ),
        ),
        if (rows > 0) ...<Widget>[
          const SizedBox(height: 8),
          const _Divider(vertical: false),
          const SizedBox(height: 8),
          Expanded(child: _list(context, rows)),
        ],
      ],
    );
  }

  /// A tall, wide cell: hero column | list of earlier sends | (sites).
  Widget _columns(BuildContext context) {
    final bool sites =
        area.width >= _kThreeColumnMinWidth && feed.sites.isNotEmpty;
    final int rows = ((area.height - 24) / _kListRowHeight).floor().clamp(
      0,
      feed.earlier.length,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: rows == 0 && !sites ? area.width : _kHeroColumnWidth,
          child: _HeroColumn(
            feed: feed,
            cover: coverOf(feed.hero),
            now: now,
            showMoreToday: rows == 0,
          ),
        ),
        if (rows > 0) ...<Widget>[
          const _Divider(vertical: true),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: <Widget>[
                _SubHeader(t.home_tracking_feed_earlier),
                Expanded(child: _list(context, rows)),
              ],
            ),
          ),
        ] else if (sites)
          const Spacer(),
        if (sites) ...<Widget>[
          const _Divider(vertical: true),
          SizedBox(
            width: _kSitesColumnWidth,
            child: _SitesColumn(feed: feed, now: now),
          ),
        ],
      ],
    );
  }

  /// Up to [maxRows] earlier sends, as many as fit the space it gets (the
  /// caller's count is an estimate; large text makes the header taller).
  Widget _list(BuildContext context, int maxRows) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final int rows = (box.maxHeight / _kListRowHeight).floor().clamp(
        0,
        maxRows,
      );
      return Column(
        key: const ValueKey<String>('home-tracking-feed-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < rows; i++)
            FushiStaggeredEntrance(
              index: i,
              child: SizedBox(
                height: _kListRowHeight,
                child: _SendTile(
                  key: ValueKey<String>(
                    'home-tracking-feed-earlier-${feed.earlier[i].titleKey}',
                  ),
                  send: feed.earlier[i],
                  cover: coverOf(feed.earlier[i]),
                  subtitle: <String>[
                    homeTrackingSendLabel(feed.earlier[i]),
                    feed.sitesOf(feed.earlier[i]),
                    formatActivityRelativeTime(feed.earlier[i].at, now),
                  ].join(' · '),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// The hero in a row: cover on the start side, title, what was sent, where
/// and when.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.feed,
    required this.cover,
    required this.now,
    required this.coverHeight,
    this.titleLines = 1,
    this.showMoreToday = true,
  });

  final HomeTrackingFeed feed;
  final Widget? cover;
  final DateTime now;
  final double coverHeight;
  final int titleLines;

  /// Adds "+N more today" when the earlier sends are not drawn.
  final bool showMoreToday;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final String? more = showMoreToday ? homeTrackingFeedMoreToday(feed) : null;
    final String? error = feed.state == HomeTrackingFeedState.failed
        ? feed.hero.error
        : null;
    final String? extra = error != null && error.isNotEmpty ? error : more;
    final TextStyle titleStyle = context.fushiType.titleSmall.copyWith(
      fontWeight: FontWeight.w700,
      color: style.foreground,
    );
    final TextStyle progressStyle = context.fushiType.bodyMedium.copyWith(
      fontWeight: FontWeight.w600,
      color: style.foreground,
    );
    final TextStyle metaStyle = context.fushiType.bodySmall.copyWith(
      color: style.muted,
    );
    return Row(
      spacing: 14,
      children: <Widget>[
        _SendCover(
          send: feed.hero,
          cover: cover,
          height: coverHeight.clamp(40, 112).toDouble(),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              // Lines by priority, each only when it fits: title and progress,
              // then where and when, then the extra line, then the title's
              // second line. Large text drops lines instead of overflowing.
              const double gap = 2;
              final double titleLine = homeWidgetLineHeight(
                context,
                titleStyle,
              );
              final double metaLine = homeWidgetLineHeight(context, metaStyle);
              double used =
                  titleLine +
                  gap +
                  homeWidgetLineHeight(context, progressStyle);
              bool fits(double line) {
                if (used + gap + line > box.maxHeight) return false;
                used += gap + line;
                return true;
              }

              final bool showMeta = fits(metaLine);
              final bool showExtra =
                  showMeta && extra != null && fits(metaLine);
              final int lines = titleLines > 1 && fits(titleLine) ? 2 : 1;
              final bool isMore = identical(extra, more);
              final Widget column = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: gap,
                children: <Widget>[
                  Text(
                    feed.hero.mediaTitle,
                    key: const ValueKey<String>('home-tracking-feed-title'),
                    maxLines: lines,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  Text(
                    homeTrackingSendLabel(feed.hero),
                    key: const ValueKey<String>('home-tracking-feed-progress'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: progressStyle,
                  ),
                  if (showMeta)
                    Text(
                      homeTrackingFeedMetaLine(feed, now),
                      key: const ValueKey<String>('home-tracking-feed-meta'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metaStyle,
                    ),
                  if (showExtra)
                    Text(
                      extra,
                      key: ValueKey<String>(
                        isMore
                            ? 'home-tracking-feed-more'
                            : 'home-tracking-feed-error',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: isMore
                          ? metaStyle.copyWith(fontWeight: FontWeight.w600)
                          : metaStyle,
                    ),
                ],
              );
              // Title and progress alone taller than the cell (very large
              // text): laid out at natural height and clipped.
              return used > box.maxHeight
                  ? HomeWidgetOverflowClip(child: column)
                  : Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: column,
                    );
            },
          ),
        ),
      ],
    );
  }
}

/// The hero as a column (tall, wide cells): a large cover beside the title
/// and progress, then one line per site it went to.
class _HeroColumn extends StatelessWidget {
  const _HeroColumn({
    required this.feed,
    required this.cover,
    required this.now,
    required this.showMoreToday,
  });

  final HomeTrackingFeed feed;
  final Widget? cover;
  final DateTime now;

  /// "+N more today" only when the earlier sends are not listed beside it.
  final bool showMoreToday;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final TextStyle meta = context.fushiType.bodySmall.copyWith(
      color: style.muted,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double coverHeight = (box.maxHeight * 0.62)
            .clamp(88, 150)
            .toDouble();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: coverHeight,
              child: _Hero(
                feed: feed,
                cover: cover,
                now: now,
                coverHeight: coverHeight,
                titleLines: 2,
                showMoreToday: showMoreToday,
              ),
            ),
            Expanded(
              child: _BottomClip(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 4,
                  children: <Widget>[
                    for (final String id in feed.siteIdsOf(feed.hero))
                      Row(
                        spacing: 8,
                        children: <Widget>[
                          FushiIcon(
                            feed.state == HomeTrackingFeedState.failed
                                ? FushiIcons.syncProblem
                                : feed.state == HomeTrackingFeedState.sending
                                ? FushiIcons.schedule
                                : FushiIcons.check,
                            size: 14,
                            color: style.accent,
                          ),
                          Expanded(
                            child: Text(
                              feed.siteNames[id] ?? id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.fushiType.bodySmall.copyWith(
                                fontWeight: FontWeight.w600,
                                color: style.foreground,
                              ),
                            ),
                          ),
                          if (feed.state == HomeTrackingFeedState.synced)
                            Text(
                              formatActivityRelativeTime(feed.hero.at, now),
                              style: meta,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The site column (widest cells): each signed-in site with its last sync
/// and links, then the 7-day counts.
class _SitesColumn extends StatelessWidget {
  const _SitesColumn({required this.feed, required this.now});

  final HomeTrackingFeed feed;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final TextStyle meta = context.fushiType.bodySmall.copyWith(
      color: style.muted,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Column(
      key: const ValueKey<String>('home-tracking-feed-sites'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: <Widget>[
        _SubHeader(t.home_tracking_feed_sites),
        Expanded(
          child: _TopClip(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 6,
              children: <Widget>[
                // Name on one line, last sync and links under it: side by
                // side they do not fit the column at larger text sizes.
                for (final HomeTrackingSiteLine site in feed.sites)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        site.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.fushiType.bodySmall.copyWith(
                          fontWeight: FontWeight.w600,
                          color: style.foreground,
                        ),
                      ),
                      Text(
                        <String>[
                          if (site.lastSyncAt > 0)
                            formatActivityRelativeTime(site.lastSyncAt, now),
                          t.home_tracking_panel_linked(n: site.linked),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: meta,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        _SubHeader(t.home_tracking_feed_week),
        Row(
          key: const ValueKey<String>('home-tracking-feed-week'),
          spacing: 16,
          children: <Widget>[
            _Count(
              value: feed.week.updates,
              label: t.home_tracking_feed_week_updates,
            ),
            _Count(
              value: feed.week.titles,
              label: t.home_tracking_feed_week_titles,
            ),
            _Count(
              value: feed.week.finished,
              label: t.home_tracking_feed_week_finished,
            ),
          ],
        ),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    return Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$value',
            style: context.fushiType.titleLarge.copyWith(
              fontWeight: FontWeight.w700,
              color: style.accent,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodySmall.copyWith(color: style.muted),
          ),
        ],
      ),
    );
  }
}

class _SubHeader extends StatelessWidget {
  const _SubHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: context.fushiType.labelSmall.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
      color: HomeWidgetStyle.of(context).muted,
    ),
  );
}

/// One earlier send: small cover, title, one line of detail.
class _SendTile extends StatelessWidget {
  const _SendTile({
    super.key,
    required this.send,
    required this.cover,
    required this.subtitle,
  });

  final MediaTrackingRecentSend send;
  final Widget? cover;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final TextStyle titleStyle = context.fushiType.bodySmall.copyWith(
      fontWeight: FontWeight.w700,
      color: style.foreground,
    );
    final TextStyle subtitleStyle = context.fushiType.bodySmall.copyWith(
      color: style.muted,
    );
    return Row(
      spacing: 10,
      children: <Widget>[
        _SendCover(send: send, cover: cover, height: 44),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final double line = homeWidgetLineHeight(context, titleStyle);
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    send.mediaTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  if (line * 2 <= box.maxHeight)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subtitleStyle,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A portrait cover box (2:3) for a send. Without a local cover it is a
/// tinted tile with the kind's icon. [mark] adds a state badge on the end
/// corner (one-column cells, where the header is the only other cue).
class _SendCover extends StatelessWidget {
  const _SendCover({
    required this.send,
    required this.cover,
    required this.height,
    this.mark,
  });

  final MediaTrackingRecentSend send;
  final Widget? cover;
  final double height;
  final HomeTrackingFeedState? mark;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final double width = height * 2 / 3;
    final Widget box = ClipRRect(
      borderRadius: height >= 80
          ? FushiBorderRadius.card
          : FushiBorderRadius.chip,
      child: SizedBox(
        width: width,
        height: height,
        child:
            cover ??
            ColoredBox(
              color: style.accent.withValues(alpha: 0.16),
              child: Center(
                child: FushiIcon(
                  homeTrackingKindIcon(send.kind),
                  size: (height * 0.36).clamp(14, 32).toDouble(),
                  color: style.accent,
                ),
              ),
            ),
      ),
    );
    final HomeTrackingFeedState? state = mark;
    if (state == null) return ExcludeSemantics(child: box);
    final bool problem = state == HomeTrackingFeedState.failed;
    return ExcludeSemantics(
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          box,
          PositionedDirectional(
            end: -6,
            bottom: -6,
            child: Container(
              key: const ValueKey<String>('home-tracking-feed-mark'),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: problem
                    ? Theme.of(context).colorScheme.error
                    : style.accent,
              ),
              child: Center(
                child: FushiIcon(
                  homeTrackingFeedIcon(state),
                  size: 13,
                  color: problem
                      ? Theme.of(context).colorScheme.onError
                      : (style.colors?.container ??
                            Theme.of(context).colorScheme.onPrimary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.vertical});

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final Color color = HomeWidgetStyle.of(
      context,
    ).foreground.withValues(alpha: 0.14);
    return vertical
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: _kColumnGap / 2),
            child: SizedBox(width: 1, child: ColoredBox(color: color)),
          )
        : SizedBox(height: 1, child: ColoredBox(color: color));
  }
}

/// Lays [child] out at its natural height from the top and clips what does
/// not fit (site rows at large text sizes).
class _TopClip extends StatelessWidget {
  const _TopClip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: OverflowBox(
      alignment: AlignmentDirectional.topStart,
      minHeight: 0,
      maxHeight: double.infinity,
      child: child,
    ),
  );
}

/// Like [_TopClip], anchored to the bottom edge.
class _BottomClip extends StatelessWidget {
  const _BottomClip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: OverflowBox(
      alignment: AlignmentDirectional.bottomStart,
      minHeight: 0,
      maxHeight: double.infinity,
      child: child,
    ),
  );
}
