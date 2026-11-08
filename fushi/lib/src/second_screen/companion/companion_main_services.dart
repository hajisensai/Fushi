import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdateQuery;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart'
    show AudiobookPlayerController;
import 'package:fushi/src/media/audiobook/audiobook_session.dart'
    show SessionBookInfo;
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_player_engine.dart'
    show MusicPlayerEngine;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart'
    show statTodayKey;
import 'package:fushi/src/ops/app_op_context.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/settings_index.dart' show settingsIndexContext;
import 'package:fushi/src/platform/widget_snapshot.dart'
    show WidgetImmersionCategory;
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/companion_settings_service.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_now_playing.dart';
import 'package:fushi/src/second_screen/companion/companion_continue.dart';
import 'package:fushi/src/second_screen/companion/companion_library_app_data.dart';
import 'package:fushi/src/second_screen/companion/companion_library_service.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

export 'package:fushi/src/second_screen/companion/companion_continue.dart'
    show
        CompanionContinueCandidate,
        collectCompanionContinueCandidates,
        pickCompanionContinue;

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

/// Collects the daily summary in the main engine: [loadStatFacts] for today's
/// time, the review deck list for due counts (only when cards go to the
/// built-in review), and the home dashboard's "continue" rules for the books /
/// manga / videos in progress.
Future<CompanionDailySummary> collectCompanionDailySummary(Ref ref) async {
  final AppModel appModel = ref.read(appProvider);
  final FushiDatabase db = appModel.database;
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

  final CompanionContinueCandidate? next = pickCompanionContinue(
    await collectCompanionContinueCandidates(ref, facts: facts),
  );
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
        countUnclaimedLookup: () => _countUnclaimedCompanionLookup(appModel),
        onMined: _showCompanionMinedOnTop,
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
      registerCompanionLibraryHandlers(
        bridge,
        CompanionLibraryService(AppCompanionLibraryData(ref)),
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

/// A companion lookup no page on top claimed (home, a library, settings):
/// the same identity-less count the panel's own popup wrote before S6
/// (`PopupDictionaryPage`'s default counter), now written by the main engine.
void _countUnclaimedCompanionLookup(AppModel appModel) {
  try {
    unawaited(
      appModel.database
          .addLookupCount(
            bookKey: null,
            title: '',
            sourceType: kStatSourceBook,
            dateKey: statTodayKey(),
          )
          .catchError((Object e, StackTrace st) {
            ErrorLogService.instance.log('CompanionLookupCount', e, st);
          }),
    );
  } catch (e, st) {
    ErrorLogService.instance.log('CompanionLookupCount', e, st);
  }
}

/// A card was mined on the companion: a brief confirmation on top, where the
/// controller user is looking (controller lookup mode mines from the top).
void _showCompanionMinedOnTop(String? term) {
  // The mining notice exit (respects the user's "mining notices" setting).
  FushiToast.showMine(
    msg: t.second_screen_lookup_mined(term: term ?? ''),
    status: MineToastStatus.added,
  );
}
