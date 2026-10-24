import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'helpers/focus_driver.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// BD/DVD 原盘交互改造第 6 项的原路径（Windows，焦点驱动、只发按键，禁坐标点击）：
/// 进原盘菜单（自动全屏）→ 控制栏 3 秒无操作收起 → Esc 呼出控制栏 → 再按 Esc 退出
/// 原盘回到上一页 → 窗口退出全屏、恢复进入前的尺寸 / 位置 / 最大化状态。
///
/// 运行：tool/run_windows_itest.ps1，-DartDefine FUSHI_BLURAY_MENU_ROOT=<盘根>
/// FUSHI_BLURAY_MENU_ENTRY=<代表 MPLS，如 00001>。缺盘明确跳过，不计入验收。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const String root = String.fromEnvironment('FUSHI_BLURAY_MENU_ROOT');
  const String entry = String.fromEnvironment('FUSHI_BLURAY_MENU_ENTRY');
  final String? skipReason = !Platform.isWindows
      ? 'Windows disc session path'
      : root.isEmpty || entry.isEmpty
      ? 'Set FUSHI_BLURAY_MENU_ROOT and ENTRY for a real HDMV disc'
      : !File(p.join(root, 'BDMV', 'index.bdmv')).existsSync()
      ? 'Disc fixture is not mounted: $root'
      : null;
  if (skipReason != null) debugPrint('[disc-session] SKIP: $skipReason');

  testWidgets(
    'disc session: auto fullscreen, Esc summons bar, Esc again restores window',
    (WidgetTester tester) async {
      final String entryPath = p.join(root, 'BDMV', 'PLAYLIST', '$entry.mpls');
      expect(File(entryPath).existsSync(), isTrue);
      final FlutterExceptionHandler? errorHandler = FlutterError.onError;
      addTearDown(() => FlutterError.onError = errorHandler);
      expect(fushiTestRootPath(), isNotNull);
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue);
      FlutterError.onError = errorHandler;
      final AppModel appModel = await enableFocusNavigation(tester);
      expect(appModel.videoDiscAutoFullscreen, isTrue);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final String uid =
          'video/itest-disc-session-${DateTime.now().microsecondsSinceEpoch}';
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: const Value('BD session integration fixture'),
          videoPath: Value(entryPath),
        ),
      );

      final bool maximizedBefore = await windowManager.isMaximized();
      final Rect boundsBefore = await windowManager.getBounds();
      expect(await WindowCaptionChannel.isFullscreen(), isFalse);

      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage.neutralized(
              bookUid: uid,
              repo: repo,
              openBlurayMenu: true,
            ),
          ),
        ),
      );
      VideoFushiTestHooks? hooks() {
        final Finder page = find.byType(VideoFushiPage);
        if (page.evaluate().isEmpty) return null;
        return tester.state<State<VideoFushiPage>>(page) as VideoFushiTestHooks;
      }

      await _waitFor(tester, () {
        final VideoDiscNavigationState? state =
            hooks()?.debugDiscNavigationState;
        return state != null && state.menuActive && state.title == 0;
      }, 'authored top menu');
      await _waitForAsync(
        tester,
        WindowCaptionChannel.isFullscreen,
        'session auto fullscreen',
      );

      // 3 s idle hides the bar (entry reveals it once).
      await _waitFor(
        tester,
        () => hooks()?.debugDiscSessionBarVisible == false,
        'bar auto-hide',
      );
      expect(hooks()!.debugDiscLearningBlocked, isTrue);

      // Short Esc: summon the bar, stay in the session.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFor(tester, const Duration(milliseconds: 300));
      expect(hooks()?.debugDiscSessionBarVisible, isTrue);
      expect(find.byType(VideoFushiPage), findsWidgets);

      // Esc again with the bar open: leave the disc, restore the window.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _waitFor(
        tester,
        () => find.byType(VideoFushiPage).evaluate().isEmpty,
        'session exit',
      );
      await _waitForAsync(
        tester,
        () async => !await WindowCaptionChannel.isFullscreen(),
        'fullscreen restored',
      );
      await _pumpFor(tester, const Duration(milliseconds: 500));
      expect(await windowManager.isMaximized(), maximizedBefore);
      if (!maximizedBefore) {
        final Rect boundsAfter = await windowManager.getBounds();
        expect(boundsAfter.topLeft, boundsBefore.topLeft);
        expect(boundsAfter.size, boundsBefore.size);
      }
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final DateTime end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done,
  String what,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _waitForAsync(
  WidgetTester tester,
  Future<bool> Function() done,
  String what,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await tester.pump(const Duration(milliseconds: 100));
  }
}
