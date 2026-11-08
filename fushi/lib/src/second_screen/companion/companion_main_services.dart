import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdateQuery;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show JapaneseLanguage;
import 'package:fushi_engine/media/video/m3u8_playlist.dart'
    show playlistEpisodeCount;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart'
    show AudiobookPlayerController;
import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show SessionBookInfo;
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart' show MediaItemAppLookup;
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart'
    show MusicPlayerEngine;
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/settings_index.dart' show settingsIndexContext;
import 'package:fushi/src/pages/implementations/dashboard_continue_logic.dart';
import 'package:fushi/src/platform/widget_links.dart';
import 'package:fushi/src/platform/widget_snapshot.dart'
    show WidgetImmersionCategory;
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_settings_service.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_now_playing.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/stats/stat_window.dart';

/// A library item that could be the summary's Continue entry.
class CompanionContinueCandidate {
  const CompanionContinueCandidate({
    required this.item,
    required this.recentAt,
    this.resolveCover,
  });

  final CompanionContinueItem item;

  /// Last activity (epoch ms); the most recent candidate wins.
  final int recentAt;

  /// Looks up the cover file; only run for the winner (cover probing is I/O,
  /// possibly on a network drive, BUG-3756).
  final Future<String> Function()? resolveCover;
}

/// The daily summary from already-loaded data (pure; the I/O is in
/// [collectCompanionDailySummary]). Today's time per category uses the same
/// mapping as the home-screen widget ([WidgetImmersionCategory]).
CompanionDailySummary buildCompanionDailySummary({
  required String todayKey,
  required Iterable<StatFact> daily,
  CompanionSrsDue? srsDue,
  CompanionContinueItem? continueItem,
}) {
  final Map<WidgetImmersionCategory, int> ms = <WidgetImmersionCategory, int>{};
  for (final StatFact f in daily) {
    if (f.dateKey != todayKey) continue;
    final WidgetImmersionCategory? category =
        WidgetImmersionCategory.fromMediaKind(f.mediaKind);
    if (category == null) continue;
    ms[category] = (ms[category] ?? 0) + f.ms;
  }
  return CompanionDailySummary(
    dayKey: todayKey,
    readingMs: ms[WidgetImmersionCategory.reading] ?? 0,
    watchingMs: ms[WidgetImmersionCategory.watching] ?? 0,
    listeningMs: ms[WidgetImmersionCategory.listening] ?? 0,
    gamesMs: ms[WidgetImmersionCategory.games] ?? 0,
    srsDue: srsDue,
    continueItem: continueItem,
  );
}

/// The candidate with the latest activity; null when there is none.
CompanionContinueCandidate? pickCompanionContinue(
  Iterable<CompanionContinueCandidate> candidates,
) {
  CompanionContinueCandidate? best;
  for (final CompanionContinueCandidate c in candidates) {
    if (best == null || c.recentAt > best.recentAt) best = c;
  }
  return best;
}

/// Collects the daily summary in the main engine: [loadStatFacts] for today's
/// time, the review deck list for due counts (only when cards go to the
/// built-in review), and the home dashboard's "continue" rules for the books /
/// manga / videos in progress.
Future<CompanionDailySummary> collectCompanionDailySummary(Ref ref) async {
  final AppModel appModel = ref.read(appProvider);
  final FushiDatabase db = appModel.database;
  final ModuleVisibility modules = appModel.moduleVisibility;
  final StatWindow window = StatWindow(DateTime.now());
  final StatFacts facts = await loadStatFacts(db, activityLimit: 0);

  CompanionSrsDue? srsDue;
  if (ref.read(srsMiningToReviewProvider)) {
    final SrsDeckListData? decks = await ref.read(srsDeckListProvider.future);
    if (decks != null) {
      srsDue = CompanionSrsDue(
        newCount: decks.todayNew,
        learnCount: decks.todayLearn,
        reviewCount: decks.todayReview,
      );
    }
  }

  final CompanionContinueCandidate?
  next = pickCompanionContinue(<CompanionContinueCandidate>[
    if (modules.isEnabled(ModuleId.books) || modules.isEnabled(ModuleId.manga))
      ...await _bookCandidates(ref, appModel),
    if (modules.isEnabled(ModuleId.video)) ...await _videoCandidates(db, facts),
  ]);
  CompanionContinueItem? continueItem;
  if (next != null) {
    final String cover = await next.resolveCover?.call() ?? '';
    continueItem = CompanionContinueItem(
      kind: next.item.kind,
      title: next.item.title,
      link: next.item.link,
      subtitle: next.item.subtitle,
      progress: next.item.progress,
      coverPath: cover,
    );
  }
  return buildCompanionDailySummary(
    todayKey: window.todayKey,
    daily: facts.daily,
    srsDue: srsDue,
    continueItem: continueItem,
  );
}

/// Books and manga in progress ([isDashboardContinueBook], the home
/// dashboard's rule), latest read time from [bookLastReadAtProvider].
Future<List<CompanionContinueCandidate>> _bookCandidates(
  Ref ref,
  AppModel appModel,
) async {
  final List<MediaItem> books = await ref.read(
    fushiBooksProvider(JapaneseLanguage.instance).future,
  );
  final Map<String, int> lastReadByUid = await ref.read(
    bookLastReadAtProvider.future,
  );
  final Map<String, String> uidByKey = await ref.read(
    epubBookUidByKeyProvider.future,
  );
  final Set<String> completed = await ref.read(
    completedEpubBookKeysProvider.future,
  );
  final ModuleVisibility modules = appModel.moduleVisibility;
  final List<CompanionContinueCandidate> result =
      <CompanionContinueCandidate>[];
  for (final MediaItem item in books) {
    if (!isDashboardContinueBook(item, completed)) continue;
    final bool manga =
        item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey;
    if (!modules.isEnabled(manga ? ModuleId.manga : ModuleId.books)) continue;
    final String bookKey =
        ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
        item.mediaIdentifier;
    final WidgetMediaKind linkKind = manga
        ? WidgetMediaKind.manga
        : WidgetMediaKind.book;
    result.add(
      CompanionContinueCandidate(
        item: CompanionContinueItem(
          kind: manga
              ? CompanionContinueKind.manga
              : CompanionContinueKind.book,
          title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
          subtitle: item.author ?? '',
          progress: item.duration > 0 ? item.position / item.duration : null,
          link: WidgetContinueLink(
            kind: linkKind,
            id: item.mediaIdentifier,
          ).toUri(),
        ),
        recentAt: lastReadByUid[uidByKey[bookKey] ?? bookKey] ?? 0,
        resolveCover: () async => _bookCoverPath(appModel, item),
      ),
    );
  }
  return result;
}

/// The book's cover file: the user's override, else a local `file://` image.
String _bookCoverPath(AppModel appModel, MediaItem item) {
  try {
    final File? override = item
        .getMediaSource(appModel: appModel)
        .resolveOverrideThumbnailFile(appModel: appModel, item: item);
    if (override != null && override.existsSync()) return override.path;
    final String? url = item.imageUrl;
    if (url != null && url.startsWith('file://')) {
      final String path = Uri.parse(url).toFilePath();
      if (File(path).existsSync()) return path;
    }
  } on FileSystemException {
    return '';
  }
  return '';
}

/// Videos in progress: a saved position and not finished (the home
/// dashboard's rule); latest watch time from today's stat facts.
Future<List<CompanionContinueCandidate>> _videoCandidates(
  FushiDatabase db,
  StatFacts facts,
) async {
  final List<VideoBookRow> videos = await VideoBookRepository(
    db,
  ).listForShelf();
  final List<VideoBookRow> watching = <VideoBookRow>[
    for (final VideoBookRow v in videos)
      if (v.lastPositionMs > 0 && v.completedAt == null) v,
  ];
  if (watching.isEmpty) return const <CompanionContinueCandidate>[];
  final Map<String, int> watchAt = <String, int>{};
  for (final StatFact w in facts.dailyVideos) {
    if (w.mediaKey.isEmpty) continue;
    if (w.lastActiveMs > (watchAt[w.mediaKey] ?? 0)) {
      watchAt[w.mediaKey] = w.lastActiveMs;
    }
  }
  final Map<String, VideoFileSpecRow> specs = await db.videoFileSpecsByPath(
    <String>[for (final VideoBookRow v in watching) v.videoPath],
  );
  return <CompanionContinueCandidate>[
    for (final VideoBookRow v in watching)
      CompanionContinueCandidate(
        item: CompanionContinueItem(
          kind: CompanionContinueKind.video,
          title: v.title,
          progress: dashboardVideoContinueProgress(
            completed: false,
            positionMs: v.lastPositionMs,
            durationMs: specs[v.videoPath]?.durationMs,
            currentEpisode: v.currentEpisode,
            playlistEpisodeCount: playlistEpisodeCount(v.playlistJson),
          ).fraction,
          link: WidgetContinueLink(
            kind: WidgetMediaKind.video,
            id: v.bookUid,
          ).toUri(),
        ),
        recentAt: watchAt[v.bookUid] ?? v.importedAt ?? 0,
        resolveCover: () async =>
            await dashboardVideoCoverPath(
              collectionCovers: const <String?>[],
              ownCover: v.coverPath,
              exists: (String path) => File(path).exists(),
            ) ??
            '',
      ),
  ];
}

/// The now-playing entry among [candidates] (in priority order): the first
/// one that is playing, else the first one that exists. With the order
/// video, music, audiobook this is: playing video > playing music > playing
/// audiobook > paused video > paused music > paused audiobook.
CompanionNowPlaying? pickCompanionNowPlaying(
  List<CompanionNowPlaying?> candidates,
) {
  for (final CompanionNowPlaying? c in candidates) {
    if (c != null && c.playing) return c;
  }
  for (final CompanionNowPlaying? c in candidates) {
    if (c != null) return c;
  }
  return null;
}

/// What plays: an open video page ([CompanionVideoPlaybackRegistry], the
/// page registers itself while open) and the background sessions (music
/// engine, audiobook session), chosen by [pickCompanionNowPlaying]. A video
/// page comes first: when one is open on top it is what the user watches
/// (opening it pauses the other players), otherwise the home widget's
/// priority applies (playing music > playing audiobook > paused music >
/// paused audiobook).
class AppCompanionNowPlayingSource extends ChangeNotifier
    implements CompanionNowPlayingSource {
  AppCompanionNowPlayingSource(
    this._appModel, {
    CompanionVideoPlaybackRegistry? video,
  }) : _video = video ?? companionVideoPlayback;

  final AppModel _appModel;
  final CompanionVideoPlaybackRegistry _video;
  bool _attached = false;

  /// Starts following the sessions (they exist once the AppModel is up).
  void attach() {
    if (_attached) return;
    _attached = true;
    _appModel.musicSession.addListener(notifyListeners);
    _appModel.audiobookSession.addListener(notifyListeners);
    _video.addListener(notifyListeners);
  }

  CompanionNowPlaying? _videoNowPlaying() {
    final CompanionVideoPlayback? video = _video.current;
    if (video == null) return null;
    final String title = video.title();
    if (title.isEmpty) return null;
    return CompanionNowPlaying(
      kind: CompanionNowPlayingKind.video,
      title: title,
      playing: video.playing(),
    );
  }

  @override
  CompanionNowPlaying? get current {
    if (!_attached) return null;
    final MusicPlayerEngine engine = _appModel.musicSession.engine;
    final MusicPlayItem? track = engine.current;
    final AudiobookPlayerController? book =
        _appModel.audiobookSession.controller;
    final SessionBookInfo? info = _appModel.audiobookSession.book;
    return pickCompanionNowPlaying(<CompanionNowPlaying?>[
      _videoNowPlaying(),
      if (track != null)
        CompanionNowPlaying(
          kind: CompanionNowPlayingKind.music,
          title: track.title,
          subtitle: track.artist ?? '',
          playing: engine.isPlaying,
        ),
      if (book != null && info != null)
        CompanionNowPlaying(
          kind: CompanionNowPlayingKind.audiobook,
          title: info.title,
          subtitle: info.author ?? '',
          playing: book.isPlaying,
        ),
    ]);
  }

  @override
  Future<void> toggle() async {
    final CompanionNowPlaying? now = current;
    switch (now?.kind) {
      case CompanionNowPlayingKind.music:
        await _appModel.musicSession.engine.togglePlayPause();
      case CompanionNowPlayingKind.audiobook:
        await _appModel.audiobookSession.controller?.togglePlayPause();
      case CompanionNowPlayingKind.video:
        await _video.current?.toggle();
      case null:
        return;
    }
  }

  @override
  void dispose() {
    if (_attached) {
      _appModel.musicSession.removeListener(notifyListeners);
      _appModel.audiobookSession.removeListener(notifyListeners);
      _video.removeListener(notifyListeners);
    }
    super.dispose();
  }
}

/// App-wide companion bridge (main engine). Inert where there is no
/// second-screen host; elsewhere it starts once the AppModel is up and
/// listens to preference, library and review changes.
final Provider<CompanionBridge> companionBridgeProvider =
    Provider<CompanionBridge>((Ref ref) {
      final AppModel appModel = ref.read(appProvider);
      final SecondScreenHost? host = SecondScreenHost.forCurrentPlatform();
      final AppCompanionNowPlayingSource nowPlaying =
          AppCompanionNowPlayingSource(appModel);
      final CompanionBridge bridge = CompanionBridge(
        host: host,
        controller: ref.read(secondScreenControllerProvider),
        contexts: companionContexts,
        collectSummary: () => collectCompanionDailySummary(ref),
        nowPlaying: nowPlaying,
        untilNextDay: StatWindow.untilNextStatDayBoundary,
      );
      ref.onDispose(() {
        bridge.dispose();
        nowPlaying.dispose();
      });
      if (host == null) return bridge;
      registerCompanionSettingsHandlers(
        bridge,
        CompanionSettingsService(
          settingsContext: () {
            final OpContext? op = appOpContext;
            if (op == null) {
              throw const CtlFailure.conflict('the main screen is not ready');
            }
            return settingsIndexContext(appModel, op.ref);
          },
          currentContext: () => companionContexts.current,
        ),
      );

      final List<StreamSubscription<Object?>> subscriptions =
          <StreamSubscription<Object?>>[];
      ref.onDispose(() {
        for (final StreamSubscription<Object?> s in subscriptions) {
          unawaited(s.cancel());
        }
      });
      ref.listen<int>(
        srsRevisionProvider,
        (int? _, int _) => bridge.notifyReviewsChanged(),
      );
      ref.listen<int>(
        srsLocalWriteProvider,
        (int? _, int _) => bridge.notifyReviewsChanged(),
      );
      bool started = false;
      void maybeStart() {
        if (started || !appModel.isInitialised) return;
        started = true;
        nowPlaying.attach();
        final FushiDatabase db = appModel.database;
        // Every preference write (theme, locale, popup and dictionary
        // settings, a profile switch) and dictionary order / toggles: the
        // panel reloads with the popup's warm-refresh path.
        subscriptions
          ..add(
            db
                .tableUpdates(
                  TableUpdateQuery.onAllTables(
                    <ResultSetImplementation<dynamic, dynamic>>[
                      db.preferences,
                      db.dictionaryMetadata,
                    ],
                  ),
                )
                .listen((_) => bridge.notifyPrefsChanged()),
          )
          ..add(
            // Settings values live in preferences: the Settings tab reloads.
            db
                .tableUpdates(
                  TableUpdateQuery.onAllTables(
                    <ResultSetImplementation<dynamic, dynamic>>[db.preferences],
                  ),
                )
                .listen((_) => bridge.notifySettingsChanged()),
          )
          ..add(
            db.watchDashboardDataChanges().listen(
              (_) => bridge.notifyLibraryChanged(),
            ),
          );
        bridge.start();
      }

      appModel.addListener(maybeStart);
      ref.onDispose(() => appModel.removeListener(maybeStart));
      maybeStart();
      return bridge;
    });
