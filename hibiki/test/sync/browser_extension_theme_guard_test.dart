// BUG-686：浏览器扩展查词弹窗「主题分裂」回归守卫。
//
// 根因：扩展弹窗容器 #entries-container 的正文色/底色由 content.css 的
// `color: var(--text-color)` / `background-color: var(--background-color)` 决定，而
// data-theme 专属块（[data-theme="dark|light"]）只提供这两个 var 的**默认**。历史 bug 是：
//   1) app 侧 browserExtensionThemeColors() 只下发 --md-* / --md-on-surface，**漏了**
//      content.css 真正读的 --text-color / --background-color；
//   2) content.js 的 data-theme 跟宿主网页 prefers-color-scheme，而 --md-* 跟 app 主题 →
//      app 浅色 + 宿主页深色时，dark 块黑底叠 app 浅色米白 surface = 崩坏（黑底 + 米卡 + 灰字）。
//
// 修复让弹窗主题**单一来源于 app**：provider 补齐 --text-color / --background-color /
// --hibiki-color-scheme，content.js 用 --hibiki-color-scheme 把 data-theme 对齐 app。
// 本测在源码层守住这两端契约，防止任一端被回退后重新分裂。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BUG-686 browser-extension popup theme single-source guard', () {
    test('browserExtensionThemeColors 下发 content.css 真正消费的核心色变量', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      // 这些 CSS 变量名在 app_model.dart 中仅由 browserExtensionThemeColors() 产生，
      // 故用全文断言（span 会被长注释推出方法体，反而假阴性）。
      expect(src, contains('browserExtensionThemeColors()'),
          reason: 'app_model.dart 应存在 browserExtensionThemeColors()');
      final String body = src;
      // 正文色 / 底色：content.css `color: var(--text-color)` /
      // `background-color: var(--background-color)` 直接读，漏则回落分裂。
      expect(body, contains("'--text-color'"),
          reason: 'provider 必须下发 --text-color（onSurface），否则弹窗字色回落宿主页');
      expect(body, contains("'--background-color'"),
          reason: 'provider 必须下发 --background-color，否则弹窗底色透明露宿主页');
      // app 明暗名，供 content.js 把 data-theme 对齐 app（而非宿主页）。
      expect(body, contains("'--hibiki-color-scheme'"),
          reason:
              'provider 必须下发 --hibiki-color-scheme 供 content.js 对齐 data-theme');
    });

    test('content.js 用 --hibiki-color-scheme 把 data-theme 对齐 app 主题', () {
      final String js =
          File('assets/browser_extension/content.js').readAsStringSync();
      // 读 app 下发的主题名并设到弹窗根的 data-theme（覆盖宿主页 prefers-color-scheme 初值）。
      expect(js, contains("theme['--hibiki-color-scheme']"),
          reason: 'content.js 应读取 app 下发的 --hibiki-color-scheme');
      expect(js, contains("setAttribute('data-theme', cs)"),
          reason: 'content.js 应用 app 主题名设 data-theme，根除主题分裂');
    });

    test('content.css 确实读 --text-color / --background-color（契约方向自证）', () {
      final String css = File('assets/browser_extension/vendor/content.css')
          .readAsStringSync();
      expect(css, contains('var(--text-color'),
          reason: 'content.css 以 var(--text-color) 决定正文色 → provider 必须下发它');
      expect(css, contains('var(--background-color'),
          reason:
              'content.css 以 var(--background-color) 决定底色 → provider 必须下发它');
    });
  });
}
