import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Windows HDR 直通宿主窗（`docs/plans/2026-08-30-video-hdr-passthrough.md` §4.1）
/// 的源码守卫。Phase 0 实测（`.codex-test/hdr-passthrough/RESULTS.md`）证明只有
/// 「独立顶层窗口钉在主窗正后方 + 主窗 blur-behind 空区域」这一条路能让 Flutter
/// 的透明洞透出 HDR 画面；这些断言咬住那几个一改就静默失效的点。
void main() {
  final String runnerDir = _runnerDir();
  final String host = _read('$runnerDir/hdr_video_host_window.cpp');
  final String window = _read('$runnerDir/flutter_window.cpp');
  final String cmake = _read('$runnerDir/CMakeLists.txt');

  test('宿主窗编进 runner', () {
    expect(cmake, contains('"hdr_video_host_window.cpp"'));
  });

  test('主窗透明 = blur-behind 空区域，且 enable / disable 成对（同一函数按参数切换）', () {
    expect(host, contains('DwmEnableBlurBehindWindow(main_, &bb)'));
    expect(host, contains('CreateRectRgn(0, 0, -1, -1)'));
    expect(host, contains('bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION'));
    // Create 开、Destroy 关：两处调用都必须在。
    expect(RegExp(r'SetMainTransparency\(true\)').allMatches(host).length, 1);
    expect(RegExp(r'SetMainTransparency\(false\)').allMatches(host).length, 1);
    // Destroy 里先拆窗再还原主窗（顺序：DestroyWindow → SetMainTransparency(false)）。
    final int destroyAt = host.indexOf('DestroyWindow(hwnd_)');
    final int restoreAt = host.indexOf('SetMainTransparency(false)');
    expect(destroyAt, greaterThan(0));
    expect(restoreAt, greaterThan(destroyAt));
  });

  test('ExtendFrame 不在宿主窗路径上（Win11 只透出边框材质，Phase 0 变体 1/13）', () {
    expect(host, isNot(contains('DwmExtendFrameIntoClientArea')));
  });

  // BUG-2964：主窗 DWM 合成状态只能由一处按 main_surface_composition.h 派生。
  // 边框延伸进客户区的像素会被画成边框 / 标题栏材质（不透明，盖在 blur-behind
  // 透出来的视频上）：隐藏标题栏阴影的 {0,0,1,0} 曾在 HDR 画面顶上画出一条
  // DWMWA_CAPTION_COLOR 横线（实测客户区第 0 行 = 主题底色）；窗口阴影伸到客户区
  // 第 0 行下方，透明像素会把它露出来（顶行暗 8-17%），全屏直通时要关掉 NC 渲染。
  test('主窗 DWM 合成只有一个写入者，随 HDR 直通 / 全屏进出重算（BUG-2964）', () {
    expect(
      'DwmExtendFrameIntoClientArea('.allMatches(window).length,
      1,
      reason: '边距写入必须只在 ApplyMainSurfaceComposition 一处',
    );
    expect(
      'DWMWA_NCRENDERING_POLICY'.allMatches(window).length,
      1,
      reason: 'NC 渲染策略写入必须只在 ApplyMainSurfaceComposition 一处',
    );
    final String body = _functionBody(
      window,
      'void FlutterWindow::ApplyMainSurfaceComposition(',
      mustContain: 'const fushi::MainSurfaceState& state',
    );
    expect(body, contains('fushi::MainFrameMargins(state)'));
    expect(body, contains('DwmExtendFrameIntoClientArea('));
    expect(body, contains('fushi::MainSurfaceNcRenderingDisabled(state)'));
    expect(body, contains('DWMWA_NCRENDERING_POLICY'));
    // 宿主窗切透明时通知主窗（不在宿主窗里私改主窗 DWM 状态）。
    expect(host, contains('on_main_passthrough_(enable);'));
    expect(window, contains('SetMainVideoPassthrough(enabled);'));
    final String setter = _functionBody(
      window,
      'void FlutterWindow::SetMainVideoPassthrough(',
    );
    expect(setter, contains('SetVideoPassthrough(enabled);'));
    expect(setter, contains('ApplyMainSurfaceComposition();'));
    // 全屏切换：退出时先按「非全屏」恢复 NC 渲染（边框还在屏外），再还原几何；
    // 进出之后都按真实状态再下发一次。
    final int leaving = window.indexOf('leaving.fullscreen = false;');
    final int setFullscreen = window.indexOf('SetFullscreen(enter);');
    expect(leaving, greaterThan(0));
    expect(setFullscreen, greaterThan(leaving));
    expect(
      window.substring(setFullscreen, setFullscreen + 120),
      contains('ApplyMainSurfaceComposition();'),
    );
  });

  test('z-order 只以主窗为锚插到其后，绝不对主窗设 TOPMOST', () {
    expect(host, contains('SetWindowPos(hwnd_, main_,'));
    expect(host, isNot(contains('HWND_TOPMOST')));
    expect(host, isNot(contains('SetWindowPos(main_')));
  });

  test('宿主窗 = 非激活工具窗 popup，不被主窗拥有（owned 窗永远在 owner 之上）', () {
    expect(host, contains('WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW'));
    expect(host, contains('WS_POPUP'));
    // 鼠标与触摸激活请求统一交给共用策略（MA_NOACTIVATE / PA_NOACTIVATE 在
    // window_activation_policy.h 里，BUG-2889）。
    expect(host, contains('return OverlayNoActivateReply(message);'));
    final RegExp create = RegExp(r'CreateWindowExW\([^;]*?\);', dotAll: true);
    final String call = create.firstMatch(host)!.group(0)!;
    // hWndParent 参数必须是 nullptr（第 8 个实参）。
    expect(call, contains('nullptr, nullptr,'));
  });

  test('主窗消息把移动 / 缩放 / 激活 / 显隐 / 销毁同步给宿主窗，且不消费消息', () {
    final int start = window.indexOf('hdr_video_host_->IsCreated()');
    expect(start, greaterThan(0));
    final String block = window.substring(start, start + 700);
    for (final String msg in <String>[
      'WM_WINDOWPOSCHANGED',
      'WM_ACTIVATE',
      'WM_SIZE',
      'WM_MOVE',
      'WM_SHOWWINDOW',
      'WM_DESTROY',
    ]) {
      expect(block, contains('case $msg:'), reason: msg);
    }
    expect(block, contains('SyncPlacement()'));
    expect(block, contains('Destroy()'));
    expect(block, isNot(contains('return')));
    expect(window, contains('WM_DISPLAYCHANGE'));
    expect(window, contains('"onDisplayChanged"'));
  });

  test('Windows 标题栏外壳：内容区底色听 hdrHostActiveGlobal，标题行自带底色', () {
    // 真机复现：外壳的 ColoredBox(surface) 包着整个 Navigator，视频洞下面就是它；
    // 一旦让整层透明，标题行也透了（能看到别的窗口）。两条都要咬住。
    final String bar = _read(
      '${_fushiDir()}/lib/src/utils/components/fushi_desktop_title_bar.dart',
    );
    expect(bar, contains('valueListenable: hdrHostActiveGlobal'));
    expect(bar, contains('hdrHost ? Colors.transparent : colors.surface'));
    // 标题行底色可以跟页面上报色（BUG-2833 阅读器纸色），但必须①与 HDR 无关、
    // ②恒不透明（叠到 surface 上）。行为侧见
    // test/desktop/fushi_title_bar_page_colors_test.dart 的 HDR 用例。
    final int rowStart = bar.indexOf('Widget _buildCaptionRow(');
    expect(rowStart, greaterThan(0), reason: '标题行必须是独立的 _buildCaptionRow');
    final int caption = bar.indexOf(
      'height: FushiDesktopTitleBar.height,',
      rowStart,
    );
    expect(caption, greaterThan(rowStart));
    // 掩掉注释：注释里写「不听 hdrHostActiveGlobal」不能被当成依赖它。
    final String rowHead = maskComments(bar).substring(rowStart, caption + 120);
    expect(
      rowHead,
      isNot(contains('hdrHost')),
      reason: '标题行底色不得听 hdrHostActiveGlobal（透明会露出后面的窗口）',
    );
    expect(
      rowHead,
      contains('Color.alphaBlend(page.background, colors.surface)'),
      reason: '页面上报色必须先叠到 surface 上，标题行恒不透明',
    );
    expect(rowHead, contains('color: captionFill,'));
  });

  test('字幕层 HDR 亮度归一：runner 回报 SDR 白电平、激活时重读、两层图形都包上', () {
    // SDR 白电平只有 DisplayConfig 给，DXGI GetDesc1 没有。
    expect(host, contains('DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL'));
    expect(host, contains('QuerySdrWhiteNits(desc.DeviceName)'));
    final String dart = _read(
      '${_fushiDir()}/lib/src/media/video/video_hdr_output.dart',
    );
    expect(window, contains('"sdrWhiteNits"'));
    expect(dart, contains("value['sdrWhiteNits']"));
    // 改「SDR 内容亮度」滑块没有窗口消息：主窗重新激活（宿主窗在时）也要通知重判。
    expect(window, contains('host_activated'));
    expect(window, contains('message == WM_DISPLAYCHANGE || host_activated'));
    // 弹幕与字幕都在视频平面上，必须都经 _hdrGraphicsWhiteLevel。
    final String layout = _read(
      '${_fushiDir()}/lib/src/pages/implementations/video_fushi/layout.part.dart',
    );
    for (final String overlay in <String>[
      'VideoDanmakuOverlay(',
      'VideoSubtitleOverlay(',
    ]) {
      final int at = layout.indexOf(overlay);
      expect(at, greaterThan(0), reason: overlay);
      expect(
        layout.substring(at - 120, at),
        contains('_hdrGraphicsWhiteLevel('),
        reason: overlay,
      );
    }
  });

  test('通道名与 Dart 侧一致', () {
    final String dart = _read(
      '${_fushiDir()}/lib/src/media/video/video_hdr_output.dart',
    );
    expect(dart, contains("'app.fushi/hdr_video_host'"));
    expect(window, contains('"app.fushi/hdr_video_host"'));
    for (final String method in <String>[
      'create',
      'setRect',
      'destroy',
      'displayInfo',
    ]) {
      expect(window, contains('method == "$method"'), reason: method);
      expect(dart, contains("'$method'"), reason: method);
    }
  });
}

String _fushiDir() {
  final Directory cwd = Directory.current;
  if (File('${cwd.path}/pubspec.yaml').existsSync() &&
      Directory('${cwd.path}/windows/runner').existsSync()) {
    return cwd.path;
  }
  return '${cwd.path}/fushi';
}

String _runnerDir() => '${_fushiDir()}/windows/runner';

String _read(String path) => File(path).readAsStringSync();

/// [source] 里以 [signature] 开头的 C++ 函数定义，截到第一个列首的 `}`。
/// [mustContain] 用来在同名重载里挑出目标那一个。
String _functionBody(String source, String signature, {String? mustContain}) {
  final RegExp end = RegExp(r'\r?\n\}\r?\n');
  int from = 0;
  while (true) {
    final int at = source.indexOf(signature, from);
    expect(at, greaterThanOrEqualTo(0), reason: signature);
    final Match? close = end.firstMatch(source.substring(at));
    expect(close, isNotNull, reason: signature);
    final String body = source.substring(at, at + close!.start);
    if (mustContain == null || body.contains(mustContain)) {
      return body;
    }
    from = at + signature.length;
  }
}
