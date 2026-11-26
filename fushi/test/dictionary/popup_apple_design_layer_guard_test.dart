import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 词典弹窗 Apple 设计系统视觉层（用户 2026-11-26「cupertino 词典弹窗按 Apple 设计重做，
/// 不要影响 material」）的源码守卫。popup.css 跑在 WebView 里，headless 测不到真实绘制，
/// 这里锁住三条契约：
///
/// - 隔离：凡是提到 `fushi-apple` 的规则都以 `html.fushi-glass-host.fushi-apple` 开头——
///   M3E / 墨水屏 / 桌面全局查词窗不挂这对 class，扩展生成器整条丢弃，Material 与浏览器
///   扩展零变化；
/// - 结构：词典卡是 inset grouped cell（单列并组、多列独立圆角），折叠指示是行尾 chevron，
///   只用 transform 换朝向（BUG-2049：布局盒不随展开状态变化）；
/// - 扩展产物 content.css 里没有任何 Apple 层规则。
void main() {
  final String css = maskCssComments(
    File('assets/popup/popup.css').readAsStringSync(),
  );

  String ruleBody(String selector) {
    final int at = css.indexOf('$selector {');
    expect(at, isNonNegative, reason: '缺少规则：$selector');
    final int open = css.indexOf('{', at);
    return css.substring(open + 1, css.indexOf('}', open));
  }

  test('every fushi-apple selector is scoped under the in-app glass host', () {
    final RegExp rule = RegExp(r'([^{}]+)\{');
    final List<String> leaks = <String>[];
    for (final RegExpMatch m in rule.allMatches(css)) {
      for (final String sel in m.group(1)!.split(',')) {
        final String s = sel.trim();
        if (!s.contains('fushi-apple')) continue;
        if (!s.startsWith('html.fushi-glass-host.fushi-apple')) leaks.add(s);
      }
    }
    expect(leaks, isEmpty);
  });

  test('dictionary cards are inset grouped cells', () {
    final String card = ruleBody(
      'html.fushi-glass-host.fushi-apple .glossary-group',
    );
    expect(card, contains('background-color: var(--fa-cell)'));
    expect(card, contains('border: none'));
    expect(card, contains('box-shadow: none'));
    expect(
      ruleBody(
        'html.fushi-glass-host.fushi-apple .glossary-section > .category-body > .glossary-group + .glossary-group',
      ),
      contains('linear-gradient(var(--fa-separator), var(--fa-separator))'),
      reason: '单列分组内的行间发丝分隔线',
    );
    expect(
      ruleBody(
        'html.fushi-glass-host.fushi-apple.fushi-dict-multicol .glossary-section > .category-body > .glossary-group',
      ),
      contains('border-radius: var(--fa-group-radius)'),
      reason: '多列（masonry / grid 回落）各自独立圆角',
    );
  });

  test('disclosure chevron sits at the row end and only rotates', () {
    final String collapsed = ruleBody(
      'html.fushi-glass-host.fushi-apple .glossary-group > summary::before',
    );
    expect(collapsed, contains('order: 1'));
    expect(collapsed, contains('width: 8px'));
    expect(collapsed, contains('height: 8px'));
    expect(collapsed, contains('transform: rotate(-45deg)'));
    final String open = ruleBody(
      'html.fushi-glass-host.fushi-apple .glossary-group[open] > summary::before',
    );
    expect(open.trim(), 'transform: rotate(45deg);');
  });

  test('multi-column geometry keys off the effective column count', () {
    final String js = File('assets/popup/popup.js').readAsStringSync();
    final int at = js.indexOf('function updateEffectiveDictColumns()');
    expect(at, isNonNegative);
    final String body = js.substring(at, js.indexOf('\n}\n', at));
    expect(
      body,
      contains("doc.classList.toggle('fushi-dict-multicol', cols > 1)"),
    );
    expect(
      body,
      contains('!window.__fushiRoot'),
      reason: '扩展里 documentElement 是宿主页，不能往上挂 class',
    );
  });

  test('extension content.css carries no Apple layer rules', () {
    for (final String path in <String>[
      'assets/browser_extension/vendor/content.css',
      '../tools/browser-extension/vendor/content.css',
    ]) {
      expect(
        maskCssComments(File(path).readAsStringSync()).contains('fushi-apple'),
        isFalse,
        reason: path,
      );
    }
  });
}
