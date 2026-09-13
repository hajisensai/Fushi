import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
  final String reader = File(
    'lib/src/pages/implementations/reader_fushi_page.dart',
  ).readAsStringSync();
  final String readerChrome = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  ).readAsStringSync();
  final String fullscreenState =
      File('lib/src/platform/macos_fullscreen_state.dart').readAsStringSync();

  test('macOS fullscreen toggles through the single NSWindow owner', () {
    // 根因：window_manager.setFullScreen 与 macos_window_utils（NSWindow.delegate
    // 所有者）抢同一 NSWindow。macOS 全屏必须由 delegate 所有者 WindowManipulator
    // 统一驱动；windowManager.setFullScreen 只留给非 macOS 桌面。
    final String toggle = methodBody(
      nav,
      'Future<void> _toggleWindowFullscreen() async {',
    );
    final String read = methodBody(
      nav,
      'Future<bool?> readDesktopWindowFullscreen() async {',
    );
    final String set = methodBody(
      nav,
      'Future<bool?> setDesktopWindowFullscreen(bool fullscreen) async {',
    );
    expect(
      toggle,
      contains('toggleDesktopWindowFullscreen()'),
      reason: 'the shortcut executor must delegate to the shared owner.',
    );
    expect(
      read,
      contains('Platform.isMacOS'),
      reason: 'fullscreen toggle must branch macOS onto the single owner.',
    );
    expect(read, contains('WindowManipulator.isWindowFullscreened'));
    expect(set, contains('Platform.isMacOS'));
    expect(set, contains('WindowManipulator.enterFullscreen'));
    expect(set, contains('WindowManipulator.exitFullscreen'));
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
    expect(body, contains('_selectTab(_previousVisibleTab)'),
        reason: 'back returns to the tab the user came from.');
    // 真正的不变量是「回不去就困死」，不是某个字面量。
    // 「功能模块」开关可以把 _previousTab 指向的 tab 藏掉，而 _selectTab
    // 对隐藏 tab 直接 return——那时返回键会变成空点击，用户困在设置页。
    // 所以返回目标必须经过一层可见性回落，而不能裸用 _previousTab。
    expect(home, contains('HomeTab get _previousVisibleTab'),
        reason: 'back target must go through a visibility fallback.');
    final int getterStart = home.indexOf('HomeTab get _previousVisibleTab');
    final String getterBody = home.substring(getterStart, getterStart + 200);
    expect(getterBody, contains('_activeTabs().contains(_previousTab)'),
        reason: 'the fallback must test the previous tab against the active '
            'tab set, otherwise a hidden module traps the user in settings.');
    expect(getterBody, contains('HomeTab.home'),
        reason: 'when the previous tab is hidden, fall back to a tab that is '
            'always present.');
    expect(body, isNot(contains('_selectTab(_previousTab)')),
        reason: 'the macOS back button must not bypass the visibility '
            'fallback.');
  });

  test('reader re-feeds chrome inset to pagination on viewport inset change',
      () {
    // 根因（症状②）：全屏 / 旋转 / notch 改 viewPadding(inset) 时，过去只更新
    // _stableTopInset/Bottom 两个 Dart 字段，却从不把新 inset 回喂 WebView 的分页
    // 几何（padding 的 --chrome-*-inset、竖排列高扣项）→ 列高 / 边距按 stale inset
    // 算，正文越出可视带、手调页边距被淹没。didChangeDependencies 必须在 inset 真
    // 变时回喂（_applyChromeInsets）。Mac 真机实测：全屏尺寸下 chromeBottomInset
    // 0→52.5px 被正确回喂、pitchDelta=0（几何无失配）。
    final int didChangeDeps = reader.indexOf('void didChangeDependencies()');
    expect(didChangeDeps, isNonNegative);
    final String body = reader.substring(didChangeDeps, didChangeDeps + 900);
    expect(body, contains('insetChanged'),
        reason: 'didChangeDependencies must detect a real inset change.');
    expect(body, contains('_applyChromeInsets'),
        reason: 'TODO-1375 (2): an inset change must re-feed the WebView '
            'pagination geometry so fullscreen re-layout uses the live inset.');
  });

  test('macOS 阅读器不再自绘标题栏拖拽带（BUG-1343 / BUG-1744 的形态已作废）', () {
    // macOS 改用应用级自绘 MD3 顶栏（FushiDesktopTitleBar，包在整个 Navigator 之上）
    // 后：交通灯在 main() 里被永久隐藏，窗口抓手由顶栏的 DragToMoveArea 提供。
    // 阅读器再留 BUG-1343 那条 28pt 拖拽带 + 同高让位，就是在顶栏底下又压一条
    // 不透明带 + 一条空白——所以整块必须消失，而不是「改成条件更严的分支」。
    // 掩掉注释：删除说明本身会提到这些名字，不掩就等于自己命中自己。
    final String readerCode = maskComments(reader);
    for (final String gone in <String>[
      '_macosWindowTitlebarInset',
      'fushi_reader_window_drag_area',
      'kMacTitleBarHeight',
      'DragToMoveArea(',
    ]) {
      expect(readerCode, isNot(contains(gone)),
          reason: '阅读器残留 macOS 顶部拖拽带痕迹（$gone）= 顶栏下面多一条带/空白');
    }
    expect(maskComments(readerChrome),
        isNot(contains('_macosWindowTitlebarInset')),
        reason: '顶部进度 pill 不该再为已删除的拖拽带让位');
  });

  test('窗口抓手与 macOS 全屏信号都归自绘顶栏所有', () {
    final String titleBar = maskComments(File(
      'lib/src/utils/components/fushi_desktop_title_bar.dart',
    ).readAsStringSync());
    final String mainCode = maskComments(main);

    // ① macOS 与 Windows 走同一条「隐藏系统标题栏 + 自绘顶栏」路径，且交通灯必须
    //    在同一次调用里关掉（windowButtonVisibility: false），否则三个圆点会浮在
    //    自绘顶栏的标题上（BUG-973 的根因）。
    expect(mainCode, contains('Platform.isWindows || Platform.isMacOS'));
    expect(mainCode, contains('windowButtonVisibility: false'));
    expect(mainCode, contains('FushiDesktopTitleBar.markEnabled()'),
        reason: '不置位启动闩 = 隐藏了系统标题栏却不挂替代顶栏（无标题无按钮）');

    // ② 窗口抓手：顶栏自己提供 DragToMoveArea。
    expect(titleBar, contains('DragToMoveArea('));

    // ③ macOS 原生全屏必须由 NSWindowDelegate 真相源驱动：window_manager 的
    //    WindowListener 在 macOS 上收不到全屏通知（macos_window_utils 占着
    //    NSWindow.delegate），只靠它顶栏会在全屏里留成一条横带。
    expect(titleBar, contains('MacosFullscreenState.instance'),
        reason: '全屏态必须取自单一真相源 MacosFullscreenState');
    expect(titleBar, contains('setContentFullscreen('),
        reason: '全屏时必须按所有者收起自绘顶栏');
    expect(titleBar, contains('removeListener('),
        reason: 'dispose 未摘监听 = 泄漏 + 已 dispose 的 State 上 setState');
    // ④ AppKit 退全屏会重建标题栏视图、复位 standardWindowButton.isHidden，
    //    退出时必须重申隐藏，否则交通灯回到自绘顶栏之上。
    expect(titleBar, contains('setMacOSTrafficLightsHidden(true)'),
        reason: '退出原生全屏后不重申隐藏 → 交通灯复现并压住自绘顶栏');
    expect(fullscreenState, contains('windowDidEnterFullScreen'),
        reason: 'NSWindowDelegate 是唯一能覆盖绿灯/菜单/快捷键全部入口的信号');
    expect(fullscreenState, contains('windowDidExitFullScreen'),
        reason: '只监听进入不监听退出，退出全屏后顶栏不会回来');
  });
}
