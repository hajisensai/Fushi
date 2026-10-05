import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit_video/media_kit_video.dart' show Video;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/bluray/aacs_configuration.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'encrypted disc opens, decodes an image and seeks in the real app',
    (WidgetTester tester) async {
      const String root = String.fromEnvironment('FUSHI_TEST_AACS_DISC');
      const String keyDb = String.fromEnvironment('FUSHI_TEST_AACS_KEYDB');
      expect(root, isNotEmpty);
      final String? savedKeyDb = aacsKeyDbPathOverride;
      final FlutterExceptionHandler? savedHandler = FlutterError.onError;
      addTearDown(() {
        aacsKeyDbPathOverride = savedKeyDb;
        FlutterError.onError = savedHandler;
      });
      if (keyDb.isNotEmpty) aacsKeyDbPathOverride = keyDb;
      const String playlist = '$root/BDMV/PLAYLIST/00001.mpls';
      final BluraySource? source = await resolveBluraySource(playlist);
      expect(source, isNotNull);
      await launchFushiTestApp();
      final bool homeReady = await waitForHome(tester);
      FlutterError.onError = savedHandler;
      expect(homeReady, isTrue);
      final AppModel model = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      ).read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(model.database);
      const String uid = 'video/itest-real-aacs';
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value(uid),
          title: const Value('AACS test'),
          videoPath: Value(playlist),
        ),
      );
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage(bookUid: uid, repo: repo),
          ),
        ),
      );
      VideoFushiTestHooks? hooks;
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final Finder page = find.byType(VideoFushiPage);
        if (page.evaluate().isEmpty) continue;
        hooks =
            tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
        if ((hooks.debugDurationMs ?? 0) > 0) break;
      }
      expect(
        hooks?.debugDurationMs,
        closeTo(source!.duration.inMilliseconds, 1000),
      );
      expect(hooks!.debugMiningSource, isNot(startsWith('http://')));
      // Duration is known before the asynchronous subtitle discovery completes
      // and the page replaces its loading panel with the actual video surface.
      for (int i = 0; i < 300 && find.byType(Video).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(Video), findsWidgets);
      final Video video = tester.widget<Video>(find.byType(Video).first);
      const int targetMs = 120000;
      await hooks.debugSeekMs(targetMs);
      await hooks.debugPlay();
      await video.controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 30),
      );
      for (
        int i = 0;
        i < 300 &&
            video.controller.player.state.position.inMilliseconds <
                targetMs + 500;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        video.controller.player.state.position.inMilliseconds,
        greaterThanOrEqualTo(targetMs + 500),
      );
      Uint8List? frame = await video.controller.player.screenshot(
        format: 'image/jpeg',
      );
      // The texture-size notification can precede the first displayed frame.
      // This opt-in disc fixture has a visible scene at two minutes; require
      // real decoded pixels instead of accepting a valid JPEG of a stale black frame.
      bool hasPicture(Uint8List? bytes) {
        if (bytes == null) return false;
        final img.Image? decoded = img.decodeJpg(bytes);
        if (decoded == null) return false;
        for (int y = 0; y < decoded.height; y += 80) {
          for (int x = 0; x < decoded.width; x += 80) {
            final img.Pixel pixel = decoded.getPixel(x, y);
            if (pixel.r > 24 || pixel.g > 24 || pixel.b > 24) return true;
          }
        }
        return false;
      }

      for (int i = 0; i < 30 && !hasPicture(frame); i++) {
        await tester.pump(const Duration(milliseconds: 100));
        frame = await video.controller.player.screenshot(format: 'image/jpeg');
      }
      expect(
        hasPicture(frame),
        isTrue,
        reason: 'The real disc must produce visible video',
      );
      final dynamic native = video.controller.player.platform;
      for (final String property in <String>[
        'pause',
        'time-pos',
        'video-pts',
        'video-codec',
        'vid',
        'hwdec-current',
        'vo-configured',
        'video-params/pixelformat',
        'estimated-vf-fps',
        'eof-reached',
      ]) {
        try {
          final Object? value = await native.getProperty(property);
          debugPrint('[aacs-render] $property=$value');
        } catch (_) {
          debugPrint('[aacs-render] $property=unavailable');
        }
      }
      expect(frame, isNotNull);
      expect(frame!.length, greaterThan(1000));
      const String evidence = String.fromEnvironment('FUSHI_TEST_ROOT');
      if (evidence.isNotEmpty) {
        await File('$evidence/aacs-decoded-frame.jpg').writeAsBytes(frame);
        await native.command(<String>[
          'screenshot-to-file',
          '$evidence/aacs-native-frame.png',
          'video',
        ]);
      }
      await hooks.debugPause();
      await navigator.maybePop();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
      }
      expect(find.byType(VideoFushiPage), findsNothing);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
