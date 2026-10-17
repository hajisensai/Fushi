// 浏览器扩展查词弹窗的「玻璃」材质接线守卫。
//
// 液态玻璃是浏览器扩展唯一的材质（用户 2026-10-04 拍板，不再跟随 app 设计系统）。玻璃样式只在
// 扩展宿主里生效（弹窗在网页文档的 shadow root 里，backdrop-filter 能真模糊背后的网页；app 内
// 弹窗是独立 WebView，采样不到 Flutter 画面）。查词响应 theme 通道里的 --fushi-glass 只剩墨水屏
// 开关：browserExtensionThemeColors() 墨水屏下发 '0'，否则 '1'；content.js 只在 '0' 时关玻璃
// （行为与 CSS 由 tools/browser-extension/popup-glass.test.js 钉住，CI 的 node --test 跑）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browserExtensionThemeColors 的 --fushi-glass 只看墨水屏，不再跟随设计系统', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final int start = src.indexOf(
      'browserExtensionThemeColors(String? colorScheme)',
    );
    expect(start, greaterThanOrEqualTo(0));
    final String body = src.substring(start, src.indexOf('\n  }\n', start));
    expect(
      RegExp(
        r"'--fushi-glass':\s*einkMode\s*\?\s*'0'\s*:\s*'1'",
      ).hasMatch(body),
      isTrue,
      reason: '--fushi-glass 只表达墨水屏（墨水屏 0，否则 1）',
    );
    expect(
      body,
      isNot(contains('glassMaterial')),
      reason: '扩展材质恒为玻璃，不得再跟随 app 设计系统的 glassMaterial',
    );
  });

  test('打包镜像 content.js 只在 --fushi-glass=0（墨水屏）时关玻璃', () {
    final String js = File(
      'assets/browser_extension/content.js',
    ).readAsStringSync();
    expect(js, contains("theme['--fushi-glass'] !== '0'"));
    expect(js, contains('function fushiApplyGlass('));
    final String css = File(
      'assets/browser_extension/vendor/content.css',
    ).readAsStringSync();
    expect(css, contains(':host([data-fushi-glass])'));
    expect(css, contains('#entries-container.fushi-glass:not(.eink)'));
  });
}
