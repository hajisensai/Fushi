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

  test('BUG-1343 windowed macOS reader exposes a draggable titlebar strip', () {
    // 默认 auto=MD3 时根部不会挂 MacosWindow/ToolBar，但 NSWindow 仍是透明标题栏 +
    // full-size content。Reader 必须自己提供稳定可抓区，不能让 WebView 吞满顶边。
    expect(reader, contains('package:window_manager/window_manager.dart'));
    expect(reader, contains('DragToMoveArea('));
    expect(reader, contains("'fushi_reader_window_drag_area'"));
    expect(reader, contains('kMacTitleBarHeight'));
    expect(reader, contains('_macosWindowTitlebarInset'));
    expect(reader, contains('_readerTopOffset =>'));
    // BUG-1381：这两条原本钉的是 `_lyricsMode || _spreadDocumentLoaded` 和局部变量名
    // `top: independentDocumentTopInset` 两个**实现拼写**——与它们同一方法体里那条
    // `EdgeInsets.only(bottom: _readerBottomReserve)` 守卫同属 B 类「要求型」锚点，
    // `_buildBody` 一重构就凭空变红（行为分毫未变）。独立文档缩进多少现由纯函数
    // `independentDocumentInsets` 承载，「歌词/spread 缩进标题栏高、正文不缩进」的数值
    // 契约由 test/pages/reader_lyrics_progress_bottom_reserve_static_test.dart 的行为
    // 断言钉死；这里只钉一件本文件该管的事：reader 页确实把标题栏高喂进了那个真相源。
    final String buildBody = methodBody(reader, '  Widget _buildBody()');
    expect(
      containsIdentifierCall(buildBody, 'independentDocumentInsets'),
      isTrue,
      reason: '不注入正文引擎的歌词/spread 文档也必须避开顶部拖拽区，'
          '缩进量走单一真相源 independentDocumentInsets',
    );
    expect(
      containsCodeLine(buildBody, 'titlebarInset: _macosWindowTitlebarInset'),
      isTrue,
      reason: '独立文档由 Flutter 侧真实缩进标题栏高，不能只改正文 CSS inset',
    );
    expect(
      readerChrome,
      contains('_stableTopInset + _macosWindowTitlebarInset'),
      reason: '顶部进度 pill 必须落在 drag strip 下方，不能盖住拖动区或交通灯',
    );
  });

  // BUG-1744：用户报的「阅读器顶部横带」。BUG-1343 引入的 28pt 拖拽带唯一条件是
  // Platform.isMacOS——进原生全屏后既没有标题栏也没有交通灯、窗口也拖不动，这条
  // 不透明带和它同高的正文让位却仍在，就是那条横带。
  test('BUG-1744 fullscreen drops the titlebar strip and its content inset',
      () {
    // 让位量必须由全屏态门控（单一真相源：_readerTopOffset / popupTopReserve /
    // independentDocumentInsets / 顶部进度 pill 全部读它）。
    expect(
      reader,
      contains(
          'Platform.isMacOS && !_macosFullscreen ? kMacTitleBarHeight : 0'),
      reason: '_macosWindowTitlebarInset 未按全屏态门控 → 全屏下正文仍被下压 28pt',
    );
    // 带子本身也必须整体不挂，只归零 inset 会留下一条盖住正文的不透明条。
    // （DragToMoveArea 挂在 build() 的 Stack 里，不在 _buildBody()。）
    final String pageBuild =
        methodBody(reader, '  Widget build(BuildContext context)');
    expect(
      containsCodeLine(pageBuild, 'if (Platform.isMacOS && !_macosFullscreen)'),
      isTrue,
      reason: '全屏下仍挂 DragToMoveArea 的 ColoredBox = 一条纯浪费的顶部横带',
    );
    expect(
      containsCodeLine(pageBuild, 'DragToMoveArea('),
      isTrue,
      reason: '守卫取错了窗口（DragToMoveArea 应在同一个 build 方法体内）',
    );
    // 状态来源必须是能覆盖**全部**入口的 NSWindowDelegate：绿灯按钮和「显示」
    // 菜单都不经过 app 自己的 F11 快捷键，只记快捷键状态会漏掉最常用的两条路。
    expect(
      reader,
      contains('MacosFullscreenState.instance'),
      reason: '全屏态必须取自单一真相源 MacosFullscreenState',
    );
    expect(
      fullscreenState,
      contains('windowDidEnterFullScreen'),
      reason: 'NSWindowDelegate 是唯一能覆盖绿灯/菜单/快捷键全部入口的信号',
    );
    expect(
      fullscreenState,
      contains('windowDidExitFullScreen'),
      reason: '只监听进入不监听退出，退出全屏后横带不会回来',
    );
    // 光 setState 不够：JS 的 --chrome-top-inset 由 _applyChromeInsets 单独推送，
    // 漏了它正文 padding-top 会停在旧的 28px 上（横带原样还在）。
    final String onChange =
        methodBody(reader, '  void _onMacosFullscreenChanged()');
    expect(containsCodeLine(onChange, '_applyChromeInsets'), isTrue,
        reason: '全屏翻转后必须把新 inset 回喂 WebView，否则 CSS 侧仍留 28px 空白');
    expect(containsCodeLine(onChange, 'setState'), isTrue);
    // 监听器必须摘掉，否则页面走了还在被全局 notifier 持有。
    expect(
      reader,
      contains('removeListener(_onMacosFullscreenChanged)'),
      reason: 'dispose 未摘监听 = 泄漏 + 已 dispose 的 State 上 setState',
    );
  });
}
