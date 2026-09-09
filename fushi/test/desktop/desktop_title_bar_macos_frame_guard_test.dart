import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// macOS 顶栏改造的源码守卫：用户拍板「mac 端去掉交通灯，改成跟 Windows 一样的原生
/// MD3 顶栏」。真机行为门全在 `dart:io` 的 `Platform.isMacOS` 与 NSWindow 平台通道上
/// （`flutter test` 里两者都不存在，Linux CI 更没有 AppKit），所以按仓库
/// `*_guard_test` 惯例钉源码级不变式。
void main() {
  // 一律扫**掩掉注释后**的源码：这些不变式的注释本身就会写「windowButtonVisibility:
  // false」「_macosWindowTitlebarInset」等字样，不掩会把说明文字当成实现命中。
  final String main = maskComments(File('lib/main.dart').readAsStringSync());
  final String titleBar = maskComments(
    File(
      'lib/src/utils/components/fushi_desktop_title_bar.dart',
    ).readAsStringSync(),
  );

  test('macOS 与 Windows 走同一条「隐藏系统标题栏 + 自绘顶栏」路径', () {
    final int gate = main.indexOf('Platform.isWindows || Platform.isMacOS');
    expect(gate, greaterThanOrEqualTo(0));
    final int style = main.indexOf('TitleBarStyle.hidden', gate);
    final int buttons = main.indexOf('windowButtonVisibility: false', gate);
    final int latch = main.indexOf('FushiDesktopTitleBar.markEnabled()', gate);
    expect(style, greaterThan(gate));
    expect(buttons, greaterThan(style));
    expect(
      latch,
      greaterThan(buttons),
      reason: '闩必须在真正隐藏原生标题栏之后置位，否则会先画一帧「两条标题栏」',
    );
  });

  test('顶栏挂载只由启动闩决定，不再叠 Platform.isWindows', () {
    expect(
      RegExp(
        r'Platform\.isWindows\s*&&\s*FushiDesktopTitleBar\.isEnabled',
      ).hasMatch(main.replaceAll(RegExp(r'\s+'), ' ')),
      isFalse,
      reason: 'macOS 已经隐藏了系统标题栏与交通灯；再用 Platform.isWindows 门控挂载 '
          '= macOS 窗口既没有标题也没有最小化/关闭按钮。',
    );
    expect(
      main.contains('if (FushiDesktopTitleBar.isEnabled) {'),
      isTrue,
      reason: '自绘顶栏的唯一门控是启动闩（Windows / macOS 由 main() 置位）。',
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

  test('macOS 原生全屏由 NSWindowDelegate 真相源驱动顶栏显隐', () {
    // window_manager 的 WindowListener 在 macOS 上收不到全屏通知（macos_window_utils
    // 占着 NSWindow.delegate），只靠它顶栏会在全屏里留成一条横带。
    expect(titleBar.contains('MacosFullscreenState.instance'), isTrue);
    expect(titleBar.contains('ensureRegistered()'), isTrue);
    expect(
      titleBar.contains('setMacOSTrafficLightsHidden(true)'),
      isTrue,
      reason: 'AppKit 退全屏会复位 standardWindowButton.isHidden，必须重申隐藏。',
    );
  });
}
