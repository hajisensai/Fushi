import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-973 的**当前形态**守卫：macOS 上交通灯（红黄绿三个圆点）压住视频页返回按钮 /
/// 左上角 OSD 的根因，已经不是「视频页忘了隐藏」，而是「窗口上还有交通灯」。
///
/// macOS 改用自绘 MD3 顶栏（[FushiDesktopTitleBar]）后，`main()` 用
/// `setTitleBarStyle(hidden, windowButtonVisibility: false)` 在启动时就把三个按钮
/// 永久关掉，窗口控制全部由顶栏的 MD3 按钮提供。于是：
///  * 视频页不该再「进页隐藏 / 退页恢复」——恢复恰恰把 BUG-973 的症状放回来；
///  * 唯一仍需重申隐藏的时机是**退出原生全屏**（AppKit 的 `toggleFullScreen` 重建
///    标题栏视图时会复位 `standardWindowButton.isHidden`）。
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

  test('交通灯由启动时一次性隐藏，视频页不再进出页开关它（BUG-973）', () {
    final String main = File('lib/main.dart').readAsStringSync();
    expect(
      main.contains('windowButtonVisibility: false'),
      isTrue,
      reason: 'main() 必须在装自绘顶栏的同一次 setTitleBarStyle 里关掉交通灯，'
          '否则三个系统圆点会浮在自绘顶栏的标题上。',
    );

    // 掩掉注释：删除说明里会写到这个调用名，不掩就等于自己命中自己。
    final String video = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      ).readAsStringSync(),
    );
    expect(
      video.contains('setMacOSTrafficLightsHidden(false)'),
      isFalse,
      reason: '退出视频页恢复交通灯 = 把 BUG-973 的遮挡放回来（窗口已无系统标题栏，'
          '三个圆点会直接压在自绘顶栏上）。',
    );
  });

  test(
    'exiting native fullscreen re-asserts the traffic-light hide (BUG-973)',
    () {
      final String source = File(
        'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
      ).readAsStringSync();

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
      // rebuilds the titlebar; the desktop branch must re-hide AFTER exiting.
      final int defaultExit = body.indexOf('defaultExitNativeFullscreen()');
      final int reHide = body.indexOf('setMacOSTrafficLightsHidden(true)');
      expect(
        defaultExit,
        greaterThanOrEqualTo(0),
        reason: 'desktop branch still exits native fullscreen via media_kit.',
      );
      expect(
        reHide,
        greaterThan(defaultExit),
        reason:
            'The desktop branch must re-assert the traffic-light hide after '
            'defaultExitNativeFullscreen(), because AppKit can reset the '
            'button visibility when leaving fullscreen (BUG-973).',
      );
    },
  );
}
