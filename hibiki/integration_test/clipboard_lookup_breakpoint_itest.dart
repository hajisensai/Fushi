import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

import 'helpers/library_fixture.dart' show readyAppModel;

/// BUG-700 / TODO-1385 真机验收（真 Windows 引擎 + 真 home_page 布局切换）：
/// 桌面剪贴板自动查词监听在窗口跨 600px 尺寸断点后必须仍存活。
///
/// 与 widget 守卫（home_dictionary_clipboard_watcher_breakpoint_test.dart，合成布局
/// 壳）互补：本用例跑**真 app**，经真 [HomePage] 的 LayoutBuilder + windowSizeClassReal
/// 在 compact(<600) 底栏布局 <-> medium(>=600) 侧栏布局间真实切换，强制真
/// [HomeDictionaryPage] dispose+重建，并用真 clipboard_watcher / hotkey_manager 插件。
/// 断言：跨断点重建后 [DesktopLookupService.isRunning] 仍为 true（修前会被旧页 stop 拆死）。
///
/// 不写 OS 剪贴板（系统级共享资源，会打断用户），端到端剪贴板->查词由 widget 守卫覆盖。
///
/// Run (PowerShell, from hibiki/)：
///   $env:HIBIKI_TEST_HIDDEN = "1"
///   flutter test integration_test/clipboard_lookup_breakpoint_itest.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'real home page: clipboard lookup watcher survives 600px window resize '
      'in both directions', (WidgetTester tester) async {
    if (!DesktopLookupService.isDesktop) return;

    app.main();
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    final AppModel appModel = await readyAppModel(tester);

    final bool originalEnabled = appModel.desktopClipboardEnabled;
    Size? restoreSize;
    try {
      // 开剪贴板监听：进入词典 tab 时 HomeDictionaryPage 才会真正 start() 服务。
      if (!originalEnabled) {
        await appModel.setDesktopClipboardEnabled(true);
      }

      // 切到查词 tab（经 HomePage 暴露的调试钩子，非坐标点击）。等 HomePage 挂载后
      // debugSelectTab 才非空。
      for (int i = 0; i < 40 && HomePage.debugSelectTab == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(HomePage.debugSelectTab, isNotNull,
          reason: 'HomePage 必须已挂载并暴露 debugSelectTab');
      HomePage.debugSelectTab!(HomeTab.dictionaries);
      await tester.pumpAndSettle(const Duration(milliseconds: 300));

      // 词典页挂载 -> 真 start()（unawaited；isRunning 在计数自增即为真）。
      expect(DesktopLookupService.instance.isRunning, isTrue,
          reason: '进入查词 tab 后桌面剪贴板/热键监听必须启动');

      // 跨断点 A：拖到 compact(<600) -> 真 home_page 切到底栏布局 -> 词典页 dispose+重建。
      restoreSize = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.binding.setSurfaceSize(const Size(480, 900));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(DesktopLookupService.instance.isRunning, isTrue,
          reason: '缩到小窗（跨 600px）重建词典页后 watcher 必须仍活（修前此处失效）');

      // 跨断点 B：拖回 medium(>=600) -> 真 home_page 切到侧栏布局 -> 词典页再次重建。
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(DesktopLookupService.instance.isRunning, isTrue,
          reason: '恢复大窗（再跨 600px）重建词典页后 watcher 必须仍活');
    } finally {
      await tester.binding.setSurfaceSize(restoreSize);
      if (!originalEnabled) {
        await appModel.setDesktopClipboardEnabled(false);
        await DesktopLookupService.instance.stop();
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
