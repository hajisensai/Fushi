import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// macOS / Windows 顶栏的源码守卫。
///
/// 当前语义（用户 2026-10-04 拍板）：窗口按钮**按平台、不按设计系统**——
///  * macOS 无论设计系统一律用系统原生红绿灯：`main()` 隐藏原生标题栏但保留三个
///    交通灯（`windowButtonVisibility: Platform.isMacOS`），自绘顶栏左侧给它们留位、
///    不画自绘窗口按钮；内容全屏收起顶栏时隐藏红绿灯，退出时经
///    `FushiDesktopTitleBar.reassertMacTrafficLights()` 重申显示。
///  * Windows / Linux 无论设计系统一律是原来 MD3 那组标题栏按钮（最小化 / 最大化 /
///    关闭三键）。
///
/// 真机行为门全在 `dart:io` 的 `Platform.isMacOS` 与 NSWindow 平台通道上
/// （`flutter test` 里两者都不存在，Linux CI 更没有 AppKit），所以按仓库
/// `*_guard_test` 惯例钉源码级不变式。
void main() {
  // 一律扫**掩掉注释后**的源码：注释本身会写到这些调用名，不掩会把说明文字当成
  // 实现命中。
  final String main = maskComments(File('lib/main.dart').readAsStringSync());
  final String titleBar = maskComments(
    File(
      'lib/src/utils/components/fushi_desktop_title_bar.dart',
    ).readAsStringSync(),
  );
  final String compactMain = main.replaceAll(RegExp(r'\s+'), ' ');

  test('macOS 与 Windows 走同一条「隐藏系统标题栏 + 自绘顶栏」路径，macOS 保留红绿灯', () {
    final int gate = main.indexOf('Platform.isWindows || Platform.isMacOS');
    expect(gate, greaterThanOrEqualTo(0));
    final int style = main.indexOf('TitleBarStyle.hidden', gate);
    final int buttons = main.indexOf(
      'windowButtonVisibility: Platform.isMacOS',
      gate,
    );
    final int latch = main.indexOf('FushiDesktopTitleBar.markEnabled()', gate);
    expect(style, greaterThan(gate));
    expect(
      buttons,
      greaterThan(style),
      reason: 'macOS 一律用系统原生红绿灯：隐藏标题栏的同一次调用里必须按平台保留'
          '它们（windowButtonVisibility: Platform.isMacOS）。',
    );
    expect(
      latch,
      greaterThan(buttons),
      reason: '闩必须在真正隐藏原生标题栏之后置位，否则会先画一帧「两条标题栏」',
    );
    expect(
      compactMain.contains('windowButtonVisibility: false'),
      isFalse,
      reason: '写死 false = macOS 窗口没有任何窗口按钮（自绘三键只给非 macOS）。',
    );
  });

  test('顶栏挂载只由启动闩决定，不再叠 Platform.isWindows', () {
    expect(
      RegExp(
        r'Platform\.isWindows\s*&&\s*FushiDesktopTitleBar\.isEnabled',
      ).hasMatch(compactMain),
      isFalse,
      reason: 'macOS 已经隐藏了系统标题栏；再用 Platform.isWindows 门控挂载 '
          '= macOS 窗口没有可拖动的顶栏。',
    );
    expect(
      main.contains('if (FushiDesktopTitleBar.isEnabled) {'),
      isTrue,
      reason: '自绘顶栏的唯一门控是启动闩（Windows / macOS 由 main() 置位）。',
    );
  });

  test('窗口按钮按平台：macOS 留位不画自绘按钮，非 macOS 画 MD3 三键', () {
    final String body = methodBody(titleBar, 'Widget _buildCaptionRow(');

    expect(
      body.contains('final bool trafficLights = Platform.isMacOS;'),
      isTrue,
      reason: '窗口按钮只按平台分流，不读设计系统（用户 2026-10-04）。',
    );
    expect(
      RegExp(
        r'if\s*\(\s*trafficLights\s*\)\s*const\s+SizedBox\(\s*width:\s*'
        r'_kTrafficLightsReserve\s*\)',
      ).hasMatch(body),
      isTrue,
      reason: 'macOS 顶栏左侧必须给系统红绿灯留位，否则它们压在拖动区 / 页面内容上。',
    );
    expect(
      RegExp(r'const double _kTrafficLightsReserve\s*=\s*\d+').hasMatch(
        titleBar,
      ),
      isTrue,
    );

    final int gate = body.indexOf('if (!trafficLights) ...<Widget>[');
    expect(
      gate,
      greaterThanOrEqualTo(0),
      reason: 'MD3 三键必须只在非 macOS 上画（macOS 用系统红绿灯）。',
    );
    final String gated = body.substring(gate);
    expect(
      '_FushiCaptionButton('.allMatches(gated).length,
      3,
      reason: '非 macOS 是原来 MD3 那组三键：最小化 / 最大化-还原 / 关闭。',
    );
    for (final String handler in <String>[
      '_minimize',
      '_toggleMaximize',
      '_close',
    ]) {
      expect(gated.contains('onPressed: $handler'), isTrue, reason: handler);
    }
    expect(
      '_FushiCaptionButton('.allMatches(body.substring(0, gate)).length,
      0,
      reason: '门控之外不得再画自绘窗口按钮（macOS 上会与系统红绿灯重复）。',
    );
    expect(
      titleBar.contains('_FushiTrafficLights'),
      isFalse,
      reason: '自绘红绿灯已删除：macOS 一律用系统原生红绿灯。',
    );
  });

  test('macOS 不挂 DragToResizeArea 的命中区（window_manager 没有 startResizing）', () {
    // window_manager 的 macOS 插件方法表里根本没有 `startResizing`（只有
    // Windows/Linux 实现），挂上去拖一下就是 MissingPluginException；而 AppKit 在
    // full-size content view 下仍自己拥有窗口四边的 resize 边框，本来就不需要代劳。
    expect(
      titleBar.contains('if (Platform.isMacOS) return const <ResizeEdge>[];'),
      isTrue,
      reason: 'macOS 必须返回空边表，把 resize 完全留给 AppKit。',
    );
  });

  test('红绿灯显隐只有一个真值：内容全屏隐藏、否则显示', () {
    final String reassert = methodBody(
      titleBar,
      'static void reassertMacTrafficLights() {',
    );
    expect(
      reassert.contains(
        'setMacOSTrafficLightsHidden(_contentFullscreen.value)',
      ),
      isTrue,
      reason: '显隐必须取自内容全屏真值：顶栏收起时藏，顶栏在时显示。',
    );
    expect(
      RegExp(r'setMacOSTrafficLightsHidden\(').allMatches(titleBar).length,
      1,
      reason: '只允许 reassertMacTrafficLights 一处写红绿灯；写死 true/false 会与'
          '全屏真值打架（顶栏在却没按钮 / 全屏时三个圆点浮在内容上）。',
    );

    final String setFs = methodBody(
      titleBar,
      'static void setContentFullscreen(',
    );
    final int publish = setFs.indexOf('_contentFullscreen.value =');
    final int sync = setFs.indexOf('reassertMacTrafficLights()');
    expect(publish, greaterThanOrEqualTo(0));
    expect(
      sync,
      greaterThan(publish),
      reason: '内容全屏真值每次变化后都要同步红绿灯（先发布再断言）。',
    );
  });

  test('macOS 原生全屏由 NSWindowDelegate 真相源驱动，退出后重申红绿灯', () {
    // window_manager 的 WindowListener 在 macOS 上收不到全屏通知（macos_window_utils
    // 占着 NSWindow.delegate），只靠它顶栏会在全屏里留成一条横带。
    expect(titleBar.contains('MacosFullscreenState.instance'), isTrue);
    expect(titleBar.contains('ensureRegistered()'), isTrue);

    final String onFs = methodBody(
      titleBar,
      'void _onMacosFullscreenChanged() {',
    );
    final int own = onFs.indexOf('FushiDesktopTitleBar.setContentFullscreen(');
    final int exitGate = onFs.indexOf('if (!fullscreen) {');
    final int reassert = onFs.indexOf(
      'FushiDesktopTitleBar.reassertMacTrafficLights()',
    );
    expect(own, greaterThanOrEqualTo(0));
    expect(exitGate, greaterThan(own));
    expect(
      reassert,
      greaterThan(exitGate),
      reason: 'AppKit 退全屏会重建标题栏视图、复位 standardWindowButton.isHidden；'
          '退出后必须经 reassertMacTrafficLights 按真值重申（所有者未变时 '
          'setContentFullscreen 不会触发它）。',
    );

    // initState 在 macOS 上立即跑一次，等于挂载时按真值初断言一次红绿灯。
    final String init = methodBody(titleBar, 'void initState() {');
    final int macGate = init.indexOf('if (Platform.isMacOS) {');
    expect(macGate, greaterThanOrEqualTo(0));
    expect(
      init.indexOf('_onMacosFullscreenChanged();', macGate),
      greaterThan(macGate),
      reason: '挂载时必须同步一次全屏态与红绿灯，否则要等第一次全屏切换才对。',
    );
  });
}
