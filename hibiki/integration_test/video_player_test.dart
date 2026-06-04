// 焦点驱动的视频播放器集成测试（骨架）。
//
// 运行条件：需真机/模拟器 + 测试视频素材 fixtures/<视频>.mp4（媒体解码依赖
// media_kit native，纯 widget test 跑不了）。本文件只保证 `flutter analyze`
// 通过（编译正确）；实际运行须在设备上 + 提供 fixture 视频，无设备环境不要跑。
//
// 范式照 integration_test/comprehensive_settings_test.dart：经
// ProviderContainer 取 AppModel，用 FocusDriver（只发合成按键，禁坐标点击）
// 遍历到播放控件 → activate → 断言播放态切换（以 play_arrow ↔ pause 图标
// 切换为可见证据，不触碰页面私有 state）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// 测试用视频素材路径（设备上需预置）。
const String _kVideoFixture = 'fixtures/sample.mp4';
const String _kVideoBookUid = 'video/itest-sample';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'video page: focus-driven play/pause toggles the control icon on real app',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[video-player] ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);

      // Seed a video book pointing at the device-side fixture.
      final File fixture = File(_kVideoFixture);
      await repo.saveVideoBook(VideoBooksCompanion(
        bookUid: const Value(_kVideoBookUid),
        title: const Value('itest sample'),
        videoPath: Value(fixture.absolute.path),
      ));

      // Open the video page directly (shelf wiring is covered by widget tests;
      // this test focuses on the player's focus-driven control).
      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => VideoHibikiPage(bookUid: _kVideoBookUid, repo: repo),
      )));

      // Allow load() to instantiate the native player; the play bar appears
      // (initially showing the play_arrow icon since playback is paused).
      bool barReady = false;
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byIcon(Icons.play_arrow).evaluate().isNotEmpty) {
          barReady = true;
          break;
        }
      }
      expect(barReady, isTrue, reason: 'play bar should render after load');

      final FocusDriver driver = FocusDriver(tester);

      // Tab to the play control and activate it via Space; the icon should
      // swap play_arrow → pause, proving the control fired and playback began.
      final bool reachedButton = await driver.focusUntil(
        () => FocusManager.instance.primaryFocus != null,
      );
      expect(reachedButton, isTrue,
          reason: 'should be able to Tab to a focusable control');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byIcon(Icons.pause), findsOneWidget,
          reason: 'activating play should swap the icon to pause');

      expect(errors, isEmpty,
          reason: errors.map((e) => e.exceptionAsString()).join('\n'));
    } finally {
      FlutterError.onError = oldHandler;
    }
  }, skip: true /* needs device + fixtures/sample.mp4 */);
}
