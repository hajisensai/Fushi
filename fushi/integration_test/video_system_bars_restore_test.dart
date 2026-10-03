import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_display_claim.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/media_fixtures.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BUG-2925：在独立 Android 测试包里走真实启动 / 播放 / Esc 退出。
/// 阶段文件供 adb 采集 dumpsys window 和含系统栏的屏幕截图；不改用户设备设置。
Future<void> _checkpoint(WidgetTester tester, String stage) async {
  debugPrint('[system-bars] $stage: top=${tester.view.padding.top}');
  await tester.runAsync(() async {
    await File(
      '${Directory.systemTemp.path}/system-bars-probe-stage.txt',
    ).writeAsString(stage);
    await Future<void>.delayed(const Duration(seconds: 5));
  });
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (int i = 0; i < 150 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(ready(), isTrue);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('startup and video exit keep system bars visible', (
    WidgetTester tester,
  ) async {
    UpdateChecker.disableAutoCheckForTesting = true;
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    final AppModel model = await enableFocusNavigation(tester);
    expect(tester.view.padding.top, greaterThan(0));
    await _checkpoint(tester, 'startup');

    final Directory fixture = await Directory.systemTemp.createTemp(
      'video_system_bars_',
    );
    final File video = await generateTestVideo(
      outPath: '${fixture.path}/probe.mp4',
      duration: const Duration(seconds: 30),
    );
    final VideoBookRepository repo = VideoBookRepository(model.database);
    const String bookUid = 'video/itest-system-bars';
    await repo.saveVideoBook(
      VideoBooksCompanion(
        bookUid: const Value(bookUid),
        title: const Value('system bars probe'),
        videoPath: Value(video.path),
      ),
    );
    unawaited(
      openLocalVideoBook(
        context: tester.element(find.byType(Scaffold).first),
        repo: repo,
        bookUid: bookUid,
      ),
    );
    await _until(tester, () {
      final Finder page = find.byType(VideoFushiPage);
      if (page.evaluate().isEmpty) return false;
      final VideoFushiTestHooks hooks =
          tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
      return hooks.debugIsPlaying && (hooks.debugPositionMs ?? 0) > 0;
    });
    expect(VideoDisplayClaim.held, isTrue);
    await _checkpoint(tester, 'playing');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _until(tester, () => find.byType(VideoFushiPage).evaluate().isEmpty);
    await _until(tester, () => !VideoDisplayClaim.held);
    await _until(tester, () => tester.view.padding.top > 0);
    await _checkpoint(tester, 'exited');

    // 通知栏 / 前后台交互产生的 resumed 不得让旧视频页再把状态栏隐藏。
    for (final String state in <String>['inactive', 'resumed']) {
      tester.binding.channelBuffers.push(
        'flutter/lifecycle',
        const StringCodec().encodeMessage('AppLifecycleState.$state'),
        (ByteData? _) {},
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.view.padding.top, greaterThan(0));
    await _checkpoint(tester, 'resumed_after_exit');
  }, skip: !Platform.isAndroid);
}
