import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart' show appProvider;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:integration_test/integration_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/pages/implementations/video_remote_page.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

import 'helpers/focus_driver.dart';
import 'helpers/video_remote_phone_app_model.dart';
import 'helpers/observe_capture.dart';

/// Actual phone widgets and authenticated HTTP routes against an isolated host.
/// The playback binding and Anki result are fixtures: this does not verify a
/// native video decoder, extraction, Anki writes, or desktop/phone connectivity.
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('phone remote focus-driven HTTP learning smoke', (
    WidgetTester tester,
  ) async {
    LocaleSettings.setLocale(AppLocale.en);
    final Directory temp = await Directory.systemTemp.createTemp(
      'video-phone-',
    );
    final FushiDatabase database = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final SyncRepository repository = SyncRepository(database);
    final FavoriteSentenceRepository favorites = FavoriteSentenceRepository(
      database,
    );
    final _PhonePlayer player = _PhonePlayer();
    final VideoRemoteHost host = VideoRemoteHost(favorites: () => favorites);
    host.register(player.binding);
    final _RecordedService recording = _RecordedService(host);
    final _PhoneDictionary dictionary = _PhoneDictionary();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: temp.path,
      port: 0,
      token: 'legacy-unused',
      videoRemoteService: recording,
      remoteLookupService: dictionary,
    );
    server.pairedPeerTokensProvider = () async => <String>{
      'phone-fixture-token',
    };
    await tester.runAsync(() async {
      await server.start();
      await repository.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(
          url: 'http://127.0.0.1:${server.port}',
          hostId: 'phone-fixture',
          token: 'phone-fixture-token',
        ),
      ]);
    });
    final FushiClientUrl peer = (await tester.runAsync(
      repository.getFushiClientUrls,
    ))!.single;
    addTearDown(() async {
      await server.stop();
      await host.dispose();
      await database.close();
      await temp.delete(recursive: true);
    });
    final VideoRemotePhoneAppModel appModel = VideoRemotePhoneAppModel();
    VideoRemotePageState page() =>
        tester.state<VideoRemotePageState>(find.byType(VideoRemotePage));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWith((Ref ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: VideoRemotePage(repository: repository, peer: peer),
          ),
        ),
      ),
    );
    await _wait(
      tester,
      () => find.byType(SubtitleTranscriptText).evaluate().isNotEmpty,
    );
    final FocusDriver driver = FocusDriver(tester);

    // Line actions live in the shared scaffold; drive the page's favorite
    // command for the first subtitle line.
    unawaited(page().toggleRowFavorite(page().rows.first));
    await _wait(tester, () => recording.operations.contains('favoriteSet'));
    await _wait(tester, () => player.favoriteWritesVisible);
    final List<FavoriteSentence> saved = (await tester.runAsync(
      favorites.getAll,
    ))!;
    expect(saved.single.text, '猫が眠る');
    expect(saved.single.source, kFavoriteSentenceSourceVideo);
    final ObserveShot subtitles = await captureFlutterFrame(
      tester,
      'video-remote-phone-subtitles',
    );
    expect(subtitles.saved, isTrue);
    expect(subtitles.nonBlank, isTrue);
    debugPrint('[video-remote-phone] screenshot=${subtitles.path}');

    expect(
      await driver.focusWidget(find.byType(SubtitleTranscriptText)),
      isTrue,
    );
    await driver.activate();
    await _wait(tester, () => dictionary.terms.isNotEmpty);
    await _wait(tester, () => page().lookupOpen);
    expect(dictionary.terms.single, startsWith('猫'));
    expect(appModel.localSearches, 0);
    expect(player.playing, isFalse);
    // The popup is the shared WebView dictionary popup; its ＋ button reaches
    // the page through onMineEntry. Drive that boundary directly.
    late MinePopupResult mined;
    await tester.runAsync(() async {
      mined = await page().onMineEntry(<String, String>{
        'expression': '猫',
        'reading': 'ねこ',
        'glossary': 'A small domestic feline.',
      });
    });
    expect(mined.queued, isTrue);
    expect(player.mines, hasLength(1));
    expect(player.mines.single['rawFields'], containsPair('expression', '猫'));
    expect(
      player.mines.single['rawFields'],
      containsPair('glossary', 'A small domestic feline.'),
    );
    expect(
      recording.operations,
      containsAll(<String>['lookupBegin', 'mine', 'mineStatus']),
    );
    final ObserveShot card = await captureFlutterFrame(
      tester,
      'video-remote-phone-card-fixture',
    );
    expect(card.saved, isTrue);
    debugPrint('[video-remote-phone] screenshot=${card.path} fixtureAnki=true');
    page().closeLookup();
    await _wait(tester, () => recording.operations.contains('lookupEnd'));
    await _wait(tester, () => player.playing);

    unawaited(page().setFavoritesAllVideos(false));
    await _wait(tester, () => page().favorites.isNotEmpty);
    unawaited(
      page().removeFavorites(<String>{
        for (final Map<String, dynamic> f in page().favorites)
          f['id'].toString(),
      }),
    );
    await _wait(tester, () => recording.operations.contains('favoritesRemove'));
    await tester.runAsync(() async {
      for (int i = 0; i < 20 && (await favorites.getAll()).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await favorites.getAll(), isEmpty);
    });

    const int soakSeconds = int.fromEnvironment('VIDEO_REMOTE_SOAK_SECONDS');
    if (soakSeconds > 0) {
      final List<FrameTiming> frames = <FrameTiming>[];
      void collect(List<FrameTiming> timings) => frames.addAll(timings);
      SchedulerBinding.instance.addTimingsCallback(collect);
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      final Stopwatch wall = Stopwatch()..start();
      try {
        while (wall.elapsed.inSeconds < soakSeconds) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 1)),
          );
          player.positionMs = (wall.elapsedMilliseconds % 10000);
          player.notify();
          await tester.pump();
        }
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(collect);
      }
      final List<int> raster =
          frames
              .map((FrameTiming f) => f.rasterDuration.inMicroseconds)
              .toList()
            ..sort();
      debugPrint(
        '[video-remote-phone] fixture-poll-soak seconds=${wall.elapsed.inSeconds} frames=${raster.length} rasterP95Us=${raster.isEmpty ? 0 : raster[((raster.length - 1) * .95).floor()]}',
      );
      // This is one UI style with fixture playback, not a thermal/video benchmark.
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    await _wait(tester, () => recording.operations.contains('disconnect'));
  }, timeout: const Timeout(Duration(minutes: 40)));
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (int i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue);
}

final class _RecordedService implements VideoRemoteService {
  _RecordedService(this.host);
  final VideoRemoteHost host;
  final List<String> operations = <String>[];
  @override
  Future<Map<String, Object?>> handle(
    String operation,
    Map<String, dynamic> body,
    String peerId,
  ) {
    operations.add(operation);
    return host.handle(operation, body, peerId);
  }
}

final class _PhoneDictionary implements FushiRemoteLookupService {
  final List<String> terms = <String>[];
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async {
    terms.add(term);
    return DictionarySearchResult(
      searchTerm: term,
      bestLength: 1,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          word: '猫',
          reading: 'ねこ',
          meaning: 'A small domestic feline.',
          dictionaryName: 'Phone fixture dictionary',
        ),
      ],
    );
  }

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

final class _PhonePlayer {
  bool playing = true, favoriteWritesVisible = false;
  int positionMs = 1000, controlRevision = 0;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<Map<String, dynamic>> mines = <Map<String, dynamic>>[];
  static const List<VideoRemoteCue> cues = <VideoRemoteCue>[
    VideoRemoteCue(
      id: 'cat-cue',
      text: '猫が眠る',
      startMs: 0,
      endMs: 10000,
      delayMs: 0,
      track: 'primary',
    ),
  ];
  late final VideoRemotePlaybackBinding binding = VideoRemotePlaybackBinding(
    identity: () => 'phone-fixture-video',
    title: () => 'Phone HTTP fixture',
    bookUid: () => 'phone-fixture-book',
    sectionIndex: () => 0,
    cues: () => cues,
    state: () => <String, Object?>{
      'playing': playing,
      'positionMs': positionMs,
      'durationMs': 10000,
      'speed': 1.0,
      'controlRevision': controlRevision,
    },
    command: (String action, Map<String, dynamic> body) async {
      controlRevision++;
      if (action == 'pause') playing = false;
      if (action == 'play' || action == 'seekCue') playing = true;
      notify();
    },
    mine:
        (
          VideoRemoteCue cue,
          Map<String, dynamic> fields,
          VideoRemoteMineSelection selection,
        ) async {
          mines.add(fields);
          await Future<void>.delayed(const Duration(milliseconds: 700));
          return <String, Object?>{'success': true, 'fixtureAnki': true};
        },
    openFavorite: (FavoriteSentence favorite) async {
      positionMs = favorite.normCharOffset ?? 0;
      notify();
    },
    addListener: listeners.add,
    removeListener: listeners.remove,
    favoritesChanged: () async {
      favoriteWritesVisible = true;
    },
  );
  void notify() {
    for (final VoidCallback callback in List<VoidCallback>.of(listeners)) {
      callback();
    }
  }
}
