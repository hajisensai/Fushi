import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';

import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

// Generate fixtures first using bluray_ffmpeg_native_test.dart with
// FUSHI_BLURAY_FIXTURE_ROOT, then pass that root as a dart-define here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('disc title and exported card open in the real video player', (
    WidgetTester tester,
  ) async {
    const String root = String.fromEnvironment('FUSHI_BLURAY_FIXTURE_ROOT');
    expect(root, isNotEmpty, reason: 'A native-verified fixture is required');
    final FlutterExceptionHandler? testErrorHandler = FlutterError.onError;
    addTearDown(() => FlutterError.onError = testErrorHandler);
    await launchFushiTestApp();
    final bool homeReady = await waitForHome(tester);
    // App startup installs its production error logger. Restore the test
    // handler before assertions so failures retain their actual diagnostics.
    FlutterError.onError = testErrorHandler;
    expect(homeReady, isTrue);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
    final VideoBookRepository repo = VideoBookRepository(
      container.read(appProvider).database,
    );
    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    for (final (String name, String path, int duration)
        in <(String, String, int)>[
          ('disc', '$root/BDMV/PLAYLIST/00001.mpls', 2800),
          ('export', '$root/card.mp4', 800),
        ]) {
      expect(File(path).existsSync(), isTrue);
      final String uid = 'video/itest-bluray-$name';
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value(name),
          videoPath: Value(path),
        ),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage(bookUid: uid, repo: repo),
          ),
        ),
      );
      VideoFushiTestHooks? hooks;
      for (int i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final Finder page = find.byWidgetPredicate(
          (Widget widget) => widget is VideoFushiPage && widget.bookUid == uid,
        );
        if (page.evaluate().isEmpty) continue;
        hooks =
            tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
        if ((hooks.debugDurationMs ?? 0) > 0) break;
      }
      expect(hooks, isNotNull);
      expect(hooks!.debugDurationMs, closeTo(duration, 100));
      expect(p.normalize(hooks.debugMiningSource!), p.normalize(path));
      await hooks.debugSeekMs(duration ~/ 2);
      await hooks.debugPlay();
      await tester.pump(const Duration(milliseconds: 150));
      expect(hooks.debugPositionMs, greaterThanOrEqualTo(duration ~/ 2 - 100));
      await hooks.debugPause();
      await navigator.maybePop();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
      }
      expect(find.byType(VideoFushiPage), findsNothing);
    }
  });
}
