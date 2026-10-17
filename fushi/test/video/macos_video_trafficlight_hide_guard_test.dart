import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-973 的**当前形态**守卫：macOS 上交通灯（红黄绿三个圆点）压住视频页返回按钮 /
/// 左上角 OSD。
///
/// 用户 2026-10-04 拍板：macOS 无论设计系统一律用系统原生红绿灯。`main()` 用
/// `setTitleBarStyle(hidden, windowButtonVisibility: Platform.isMacOS)` 保留它们，
/// 自绘顶栏（[FushiDesktopTitleBar]）在左侧给它们留位，所以窗口化播放时它们落在顶栏
/// 留位里、不压视频页控件。会压住内容的只剩**内容全屏**（顶栏收起）——那时红绿灯的
/// 显隐统一由 `FushiDesktopTitleBar.reassertMacTrafficLights()` 按内容全屏真值决定：
///  * 视频页不得自己直接开关交通灯（进页隐藏 / 退页恢复会与顶栏真值打架）；
///  * **退出原生全屏**后必须经 `reassertMacTrafficLights()` 重申（AppKit 的
///    `toggleFullScreen` 重建标题栏视图时会复位 `standardWindowButton.isHidden`）。
///
/// 源码守卫是最强可落地层：行为门在 `dart:io` 的 `Platform.isMacOS` 与
/// `NSWindow.standardWindowButton` 平台通道上，`flutter test` 下两者都不存在。
void main() {
  test(
      'setMacOSTrafficLightsHidden gates on macOS and toggles all three '
      'traffic-light buttons (BUG-973)', () {
    final String source = File(
      'lib/src/platform/desktop/macos_traffic_lights.dart',
    ).readAsStringSync();

    expect(
      RegExp(r'if\s*\(\s*!\s*Platform\.isMacOS\s*\)').hasMatch(source),
      isTrue,
      reason: 'The helper must early-return on non-macOS so it is a no-op on '
          'Windows/Linux/mobile (no traffic lights there).',
    );

    for (final String call in <String>[
      'hideCloseButton',
      'hideMiniaturizeButton',
      'hideZoomButton',
      'showCloseButton',
      'showMiniaturizeButton',
      'showZoomButton',
    ]) {
      expect(
        source.contains('WindowManipulator.$call'),
        isTrue,
        reason: 'The helper must call WindowManipulator.$call so every traffic '
            'light is hidden/restored (a partial hide still leaves overlap).',
      );
    }
  });

  test('交通灯按平台保留，视频页不再自己开关它（BUG-973）', () {
    final String main = maskComments(File('lib/main.dart').readAsStringSync());
    expect(
      main.contains('windowButtonVisibility: Platform.isMacOS'),
      isTrue,
      reason: 'macOS 一律用系统原生红绿灯（用户 2026-10-04）：隐藏标题栏的同一次'
          'setTitleBarStyle 必须按平台保留它们。',
    );

    // 掩掉注释：删除说明里会写到这个调用名，不掩就等于自己命中自己。
    final String video = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      ).readAsStringSync(),
    );
    expect(
      video.contains('setMacOSTrafficLightsHidden('),
      isFalse,
      reason: '红绿灯显隐只有 FushiDesktopTitleBar 一个真值（内容全屏藏、否则显示）；'
          '视频页直接开关会与它打架——退页恢复时若仍在全屏，三个圆点会压回内容上。',
    );
  });

  test(
    'exiting native fullscreen re-asserts traffic lights via the title bar '
    'truth (BUG-973)',
    () {
      final String source = maskComments(
        File(
          'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
        ).readAsStringSync(),
      );

      // 锚定**定义**而非裸符号：BUG-2043 后同文件里更早处有一个调用点
      // （_releaseHandedOverNativeFullscreen），裸 indexOf 会先命中它、扫错方法体。
      final int exitFs = source.indexOf(
        'Future<void> _exitVideoNativeFullscreen()',
      );
      expect(exitFs, greaterThanOrEqualTo(0));
      // Scan the method body: from its declaration to the next method.
      final int nextMethod = source.indexOf('\n  Future<', exitFs + 1);
      final int nextAny = source.indexOf('\n  Widget ', exitFs + 1);
      int end = source.length;
      if (nextMethod > exitFs) end = nextMethod;
      if (nextAny > exitFs && nextAny < end) end = nextAny;
      final String body = source.substring(exitFs, end);

      // AppKit's toggleFullScreen can reset standardWindowButton.isHidden when it
      // rebuilds the titlebar; the desktop branch must re-assert AFTER exiting,
      // through the title bar's single source of truth (not a hard-coded value).
      final int defaultExit = body.indexOf('defaultExitNativeFullscreen()');
      final int reHide = body.indexOf(
        'FushiDesktopTitleBar.reassertMacTrafficLights()',
      );
      expect(
        body.contains('setMacOSTrafficLightsHidden('),
        isFalse,
        reason: 'Hard-coding the visibility here would fight the title bar '
            'truth (hidden only while content is fullscreen).',
      );
      expect(
        defaultExit,
        greaterThanOrEqualTo(0),
        reason: 'desktop branch still exits native fullscreen via media_kit.',
      );
      expect(
        reHide,
        greaterThan(defaultExit),
        reason:
            'The desktop branch must call '
            'FushiDesktopTitleBar.reassertMacTrafficLights() after '
            'defaultExitNativeFullscreen(), because AppKit can reset the '
            'button visibility when leaving fullscreen (BUG-973).',
      );
    },
  );
}
