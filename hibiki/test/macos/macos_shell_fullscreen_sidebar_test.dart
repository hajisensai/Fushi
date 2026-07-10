import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1375 源码守卫：macOS 原生壳三症状根因修复不变式。
///
/// ① 小说全屏退出后 sidebar 消失、退出阅读界面跳设置页且无边栏可退（困死）；
/// ③ macOS 设置 tab 无返回出口。这些路径需真 macOS 窗口 / NSWindow delegate，
/// 无法在 headless widget test 里 pump（同 macos_shell_static_test 的理由），故
/// 按仓库 `*_static_test` 惯例断言源码级不变式；活的行为由 Mac 真机验收截图确认。
void main() {
  final String nav =
      File('lib/src/shortcuts/global_navigation.dart').readAsStringSync();
  final String main = File('lib/main.dart').readAsStringSync();
  final String home =
      File('lib/src/pages/implementations/home_page.dart').readAsStringSync();
  final String appModel =
      File('lib/src/models/app_model.dart').readAsStringSync();

  test('macOS fullscreen toggles through the single NSWindow owner', () {
    // 根因：window_manager.setFullScreen 与 macos_window_utils（NSWindow.delegate
    // 所有者）抢同一 NSWindow。macOS 全屏必须由 delegate 所有者 WindowManipulator
    // 统一驱动；windowManager.setFullScreen 只留给非 macOS 桌面。
    final int toggleStart =
        nav.indexOf('Future<void> _toggleWindowFullscreen()');
    expect(toggleStart, isNonNegative);
    final String body = nav.substring(toggleStart);
    final int end = body.indexOf('\n}');
    final String fn = end >= 0 ? body.substring(0, end) : body;
    expect(fn, contains('Platform.isMacOS'),
        reason: 'fullscreen toggle must branch macOS onto the single owner.');
    expect(fn, contains('WindowManipulator.enterFullscreen'));
    expect(fn, contains('WindowManipulator.exitFullscreen'));
    expect(fn, contains('WindowManipulator.isWindowFullscreened'));
  });

  test(
      'macOS root sidebar is driven by mediaOpenNotifier, not stale isMediaOpen',
      () {
    // 根因：openMedia/closeMedia 改 _currentMediaSource 却不 notifyListeners，
    // 退出阅读器后 MaterialApp.builder 不重跑 → sidebar 卡在上一次求值的 null
    // （永久消失 → 设置 tab 无 sidebar 出口 → 困死）。改由可靠通知源驱动。
    expect(main, contains('appModel.mediaOpenNotifier'),
        reason: 'sidebar visibility must listen to the reliable notifier.');
    expect(main, contains('ValueListenableBuilder<bool>'));
    expect(main, isNot(contains('sidebar: appModel.isMediaOpen')),
        reason: 'sidebar must NOT read the un-notified isMediaOpen directly.');
  });

  test('openMedia/closeMedia keep mediaOpenNotifier in sync', () {
    expect(appModel, contains('final ValueNotifier<bool> mediaOpenNotifier'));
    expect(appModel, contains('mediaOpenNotifier.value = true'),
        reason: 'openMedia must flag media open.');
    expect(appModel, contains('mediaOpenNotifier.value = false'),
        reason: 'closeMedia must flag media closed (restores sidebar).');
    expect(appModel, contains('mediaOpenNotifier.dispose()'));
  });

  test('macOS settings tab has a sidebar-independent back exit', () {
    final int layoutStart = home.indexOf('Widget _buildMacosLayout()');
    final int layoutEnd = home.indexOf('Widget _buildDesktopLayout(');
    expect(layoutStart, isNonNegative);
    expect(layoutEnd, greaterThan(layoutStart));
    final String body = home.substring(layoutStart, layoutEnd);
    expect(body, contains('HomeTab.settings'),
        reason: 'settings tab needs its own back affordance.');
    expect(body, contains('MacosBackButton'),
        reason: 'settings tab must expose a back button independent of the '
            'sidebar so it can never be trapped.');
    expect(body, contains('_selectTab(_previousTab)'),
        reason: 'back returns to the tab the user came from.');
  });
}
