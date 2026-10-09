import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 查词弹窗「调整上下文」按钮（`.ctx-adjust-button`）M3 Expressive 化守卫。
///
/// 回归来源：#1971 把弹窗改成 MD3 / Apple 两套玻璃设计后，这个按钮仍是旧样式——
/// 继承正文色、UA 默认字号、只有一条 `opacity: 0.85`，与同排已跟主色的 ♪ / ☆ / +
/// 明显不是一套（用户「查词框的选择上下文按钮还不是 m3e」）。这里钉住：
///  1. MD3 基础样式是 tonal 图标按钮：主色淡染容器 + 主色图标、整圆、状态层
///     （hover / focus-visible / pressed）、按下形状变形 + 缩放、带过渡。
///  2. Apple 设计系统挂 `html.fushi-glass-host.fushi-apple`：胶囊灰填充、按下变暗、
///     不做形状变形；且生成的扩展 content.css 丢弃这段（扩展没有 Apple 设计系统）。
///  3. 墨水屏覆盖：描边 + 前景色，按下反色。
///  4. 减弱动态效果：popup.js 给按钮挂 `.no-motion`，CSS 把过渡 / 缩放归零。
///  5. Dart 注入 toggle `fushi-apple`。
///
/// flutter test cwd 是 fushi 包根。
void main() {
  const String popupCssPath = 'assets/popup/popup.css';
  const String popupJsPath = 'assets/popup/popup.js';
  const String contentCssPath = 'assets/browser_extension/vendor/content.css';
  const String injectionPath =
      'lib/src/pages/implementations/popup_settings_injection.dart';

  /// 取出选择器恰为 [selector] 的那条规则体（不含花括号）。
  String ruleBody(String css, String selector) {
    // 前面必须紧跟上一条规则的 `}`（注释已等长掩码成空白），这样
    // `.a:hover,\n.a:focus-visible {` 里的第二个选择器不会被当成独立规则命中。
    final RegExp re = RegExp(
      '\\}\\s*${RegExp.escape(selector)}\\s*\\{([^}]*)\\}',
    );
    final RegExpMatch? m = re.firstMatch(css);
    expect(m, isNotNull, reason: '缺少规则 `$selector {…}`');
    return m!.group(1)!;
  }

  late String css;
  setUpAll(() {
    css = maskCssComments(File(popupCssPath).readAsStringSync());
  });

  test('MD3：tonal 容器 + 主色图标 + 整圆 + 过渡', () {
    final String body = ruleBody(css, '.ctx-adjust-button');
    expect(body, contains('width: 32px'));
    expect(body, contains('height: 32px'));
    expect(body, contains('border-radius: 16px'));
    expect(body, contains('color: var(--md-primary, var(--primary-color))'));
    expect(
      body,
      contains(
        'background-color: color-mix(in srgb, '
        'var(--md-primary, var(--primary-color)) 14%, transparent)',
      ),
    );
    expect(body, contains('transition: transform'));
    expect(body, contains('border-radius 0.18s'));
    expect(body, isNot(contains('opacity: 0.85')), reason: '旧的「半透明正文色」样式不得回来');
  });

  test('MD3：状态层 hover / focus-visible / pressed 与焦点环', () {
    final String hover = ruleBody(
      css,
      '.ctx-adjust-button:hover,\n.ctx-adjust-button:focus-visible',
    );
    expect(hover, contains('22%'));
    final String focus = ruleBody(css, '.ctx-adjust-button:focus-visible');
    expect(focus, contains('box-shadow: 0 0 0 2px var(--md-primary'));
    final String active = ruleBody(css, '.ctx-adjust-button:active');
    expect(active, contains('border-radius: 10px'), reason: 'M3E 按下形状变形');
    expect(active, contains('transform: scale(0.92)'));
    expect(active, contains('26%'));
    expect(active, contains('transition-duration: 0.09s'));
  });

  test('减弱动态效果：.no-motion 归零，popup.js 按偏好挂类', () {
    final String body = ruleBody(
      css,
      '.ctx-adjust-button.no-motion,\n.ctx-adjust-button.no-motion:active',
    );
    expect(body, contains('transition: none'));
    expect(body, contains('transform: none'));
    final String js = File(popupJsPath).readAsStringSync();
    expect(
      js,
      contains(
        "if (__fushiPopupReducedMotion()) adjustBtn.classList.add('no-motion');",
      ),
    );
  });

  test('Apple：胶囊灰填充、按下变暗不变形', () {
    final String base = ruleBody(
      css,
      'html.fushi-glass-host.fushi-apple .ctx-adjust-button',
    );
    expect(base, contains('var(--text-color) 9%'));
    final String active = ruleBody(
      css,
      'html.fushi-glass-host.fushi-apple .ctx-adjust-button:active',
    );
    expect(active, contains('transform: none'));
    expect(active, contains('border-radius: 16px'));
    expect(active, contains('opacity: 0.55'));
    final String focus = ruleBody(
      css,
      'html.fushi-glass-host.fushi-apple .ctx-adjust-button:focus-visible',
    );
    expect(focus, contains('box-shadow: 0 0 0 3px'));
  });

  test('墨水屏：描边 + 前景色，按下反色', () {
    final String base = ruleBody(css, 'html.eink .ctx-adjust-button');
    expect(base, contains('border: 1px solid var(--text-color)'));
    expect(base, contains('background-color: transparent'));
    final String active = ruleBody(css, 'html.eink .ctx-adjust-button:active');
    expect(active, contains('background-color: var(--text-color)'));
    expect(active, contains('color: var(--background-color)'));
  });

  test('扩展 content.css：带 MD3 样式、丢弃 Apple 段', () {
    final String content = maskCssComments(
      File(contentCssPath).readAsStringSync(),
    );
    expect(
      ruleBody(content, '.ctx-adjust-button'),
      contains('border-radius: 16px'),
    );
    expect(content, isNot(contains('.fushi-apple')));
    expect(
      content,
      contains(':where(#entries-container).eink .ctx-adjust-button'),
    );
  });

  test('Dart 注入按 Apple 色板 toggle fushi-apple', () {
    final String src = File(injectionPath).readAsStringSync();
    expect(src, contains('theme.extension<FushiAppleColors>() != null'));
    expect(
      src,
      contains(
        r"document.documentElement.classList.toggle('fushi-apple', $appleDesign);",
      ),
    );
  });
}
