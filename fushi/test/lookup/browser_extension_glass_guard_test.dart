// 浏览器扩展查词弹窗的「玻璃」材质接线守卫。
//
// 玻璃样式只在扩展宿主里生效（弹窗在网页文档的 shadow root 里，backdrop-filter 能真模糊
// 背后的网页；app 内弹窗是独立 WebView，采样不到 Flutter 画面）。开关走查词响应 theme
// 通道：browserExtensionThemeColors() 下发 --fushi-glass（'1'/'0'），content.js 据此挂钩子，
// 样式在 content-css-overlay.css 的 @supports 段（行为与 CSS 由
// tools/browser-extension/popup-glass.test.js 钉住，CI 的 node --test 跑）。
// 这里钉 Dart 侧：取值来自 glassMaterial 且墨水屏下恒关；打包镜像的 content.js 读这个 key。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browserExtensionThemeColors 按玻璃材质下发 --fushi-glass，墨水屏恒关', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final int start =
        src.indexOf('browserExtensionThemeColors(String? colorScheme)');
    expect(start, greaterThanOrEqualTo(0));
    final String body = src.substring(start, src.indexOf('\n  }\n', start));
    expect(
      RegExp(
        r"'--fushi-glass':\s*glassMaterial\s*!=\s*FushiGlassMaterial\.off\s*"
        r"&&\s*!einkMode\s*\?\s*'1'\s*:\s*'0'",
      ).hasMatch(body),
      isTrue,
      reason: '--fushi-glass 必须取自 glassMaterial（非 off）且墨水屏下为 0',
    );
  });

  test('打包镜像 content.js 读 --fushi-glass 并挂玻璃钩子', () {
    final String js =
        File('assets/browser_extension/content.js').readAsStringSync();
    expect(js, contains("theme['--fushi-glass'] === '1'"));
    expect(js, contains('function fushiApplyGlass('));
    final String css =
        File('assets/browser_extension/vendor/content.css').readAsStringSync();
    expect(css, contains(':host([data-fushi-glass])'));
    expect(css, contains('#entries-container.fushi-glass:not(.eink)'));
  });
}
