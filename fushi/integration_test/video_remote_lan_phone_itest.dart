/// Physical Android UI talks to the isolated Windows player's LAN listener.
/// The Windows fixture uses real mpv/ffmpeg and an isolated FakeAnkiConnect.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart' show appProvider;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/pages/implementations/video_remote_page.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_client.dart';
import 'package:fushi_core/fushi_core.dart';

import 'helpers/focus_driver.dart';
import 'helpers/video_remote_phone_app_model.dart';
import 'helpers/observe_capture.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const String hostUrl = String.fromEnvironment('VIDEO_REMOTE_HOST_URL');
  const String token = 'video-remote-integration-paired-token';
  const int soakSeconds = int.fromEnvironment('VIDEO_REMOTE_SOAK_SECONDS');
  testWidgets('Android controls real fullscreen Windows player over LAN', (
    WidgetTester tester,
  ) async {
    expect(
      hostUrl,
      isNotEmpty,
      reason: 'Start the isolated Windows hold fixture',
    );
    expect(Platform.isAndroid, isTrue, reason: 'This validates Android UI');
    LocaleSettings.setLocale(AppLocale.en);
    final FushiDatabase database = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    final SyncRepository repository = SyncRepository(database);
    final FushiClientUrl peer = FushiClientUrl(
      url: hostUrl,
      hostId: 'isolated-windows-video',
      token: token,
    );
    final VideoRemoteClient probe = VideoRemoteClient(
      repository: repository,
      peer: peer,
    );
    addTearDown(() async {
      probe.cancelPending();
      await database.close();
    });
    await tester.runAsync(
      () => repository.setFushiClientUrls(<FushiClientUrl>[peer]),
    );
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
    await _waitRemote(
      tester,
      probe,
      'favorites',
      (Map<String, dynamic> value) => (value['items'] as List).any(
        (dynamic item) => item['text'] == '猫がいる',
      ),
    );
    final ObserveShot initial = await captureFlutterFrame(
      tester,
      'lan-phone-subtitles',
    );
    expect(initial.saved && initial.nonBlank, isTrue);
    expect(
      await driver.focusWidget(find.byType(SubtitleTranscriptText).first),
      isTrue,
    );
    await driver.activate();
    await _wait(tester, () => page().lookupOpen);
    await _waitRemote(
      tester,
      probe,
      'snapshot',
      (Map<String, dynamic> value) => value['playing'] == false,
    );
    // The desktop surrogate already mined 猫. A unique field avoids duplicates
    // while retaining the actual selected sentence/audio/image extraction.
    // The popup's ＋ button reaches the page through onMineEntry.
    late MinePopupResult result;
    await tester.runAsync(() async {
      result = await page().onMineEntry(<String, String>{
        'expression': 'remote_phone_cat',
        'reading': 'ねこ',
        'glossary': 'cat',
      });
    });
    expect(result.queued, isTrue);
    final ObserveShot mined = await captureFlutterFrame(
      tester,
      'lan-phone-mined',
    );
    expect(mined.saved && mined.nonBlank, isTrue);
    page().closeLookup();
    await _waitRemote(
      tester,
      probe,
      'snapshot',
      (Map<String, dynamic> value) => value['playing'] == true,
    );
    unawaited(page().setFavoritesAllVideos(false));
    await _wait(tester, () => page().favorites.isNotEmpty);
    unawaited(
      page().removeFavorites(<String>{
        for (final Map<String, dynamic> f in page().favorites)
          f['id'].toString(),
      }),
    );
    await _waitRemote(
      tester,
      probe,
      'favorites',
      (Map<String, dynamic> value) => (value['items'] as List).isEmpty,
    );
    debugPrint(
      '[video-remote-lan] Android UI learning and favorites passed; FakeAnkiConnect=true',
    );

    if (soakSeconds > 0) {
      final List<int> rasterUs = <int>[];
      int slowFrames = 0;
      void record(List<FrameTiming> frames) {
        for (final FrameTiming frame in frames) {
          rasterUs.add(frame.rasterDuration.inMicroseconds);
          if (frame.totalSpan.inMicroseconds > 16667) slowFrames++;
        }
      }

      SchedulerBinding.instance.addTimingsCallback(record);
      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      final Stopwatch wall = Stopwatch()..start();
      try {
        while (wall.elapsed.inSeconds < soakSeconds) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 1)),
          );
          await tester.pump();
        }
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(record);
      }
      rasterUs.sort();
      debugPrint(
        '[video-remote-lan] soak seconds=${wall.elapsed.inSeconds} '
        'frames=${rasterUs.length} slowFrames=$slowFrames '
        'rasterP95Us=${rasterUs.isEmpty ? 0 : rasterUs[((rasterUs.length - 1) * .95).floor()]}',
      );
      // One UI style, USB charging and profile/debug builds are distinct evidence.
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 45)));
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() ready, {
  int seconds = 30,
}) async {
  final Stopwatch wall = Stopwatch()..start();
  while (!ready() && wall.elapsed.inSeconds < seconds) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue);
}

Future<void> _waitRemote(
  WidgetTester tester,
  VideoRemoteClient client,
  String operation,
  bool Function(Map<String, dynamic>) ready,
) async {
  Map<String, dynamic> value = <String, dynamic>{};
  final Stopwatch wall = Stopwatch()..start();
  do {
    value = (await tester.runAsync(() => client.call(operation)))!;
    if (ready(value)) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  } while (wall.elapsed.inSeconds < 30);
  expect(ready(value), isTrue, reason: '$operation: $value');
}
