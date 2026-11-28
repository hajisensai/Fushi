import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 词典弹窗 Apple 设计系统视觉层（用户 2026-11-26「cupertino 词典弹窗按 Apple 设计重做，
/// 不要影响 material」）的源码守卫。popup.css 跑在 WebView 里，headless 测不到真实绘制，
/// 这里锁住三条契约：
///
/// - 隔离：凡是提到 `fushi-apple` 的规则都以 `html.fushi-glass-host.fushi-apple` 开头——
///   M3E / 墨水屏 / 桌面全局查词窗不挂这对 class；
/// - 浏览器扩展（用户 2026-11-26「一个 material 一个 cupertino」）：Cupertino 风格下 theme.js
///   给弹窗容器挂同一对 class，生成器把 Apple 层重根到 `:where(#entries-container)`，与 app 同一套；
/// - SF 图标：Apple 下 popup.js 出 CupertinoIcons 字形（制卡钮也是），Material 保持原样；
/// - 结构：词典卡是 inset grouped cell（单列并组、多列独立圆角），折叠指示是行尾 chevron，
///   只用 transform 换朝向（BUG-2049：布局盒不随展开状态变化）；
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

  test('cards are a translucent fill on the glass and rows are compact '
      '(user 11-27)', () {
    final String tokens = ruleBody('html.fushi-glass-host.fushi-apple');
    expect(tokens, contains('--fa-cell: rgba(255, 255, 255, 0.5)'));
    expect(tokens, contains('--fa-row-min: 24px'));
    expect(
      ruleBody('html.fushi-glass-host.fushi-apple.fushi-touch'),
      contains('--fa-row-min: 36px'),
      reason: '触屏保点按区',
    );
    final String label = ruleBody(
      'html.fushi-glass-host.fushi-apple .dict-label',
    );
    expect(label, contains('min-height: var(--fa-row-min)'));
    expect(label, contains('font-size: var(--fa-row-font)'));
    expect(
      ruleBody(
        'html.fushi-glass-host.fushi-apple.fushi-dict-multicol .glossary-section > .category-body > .glossary-group',
      ),
      contains('inset 0 1px 0 var(--fa-cell-rim)'),
      reason: '多列半透卡靠顶亮描边勾出卡缘',
    );
    final String injection = File(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    ).readAsStringSync();
    expect(
      injection,
      contains("classList.toggle('fushi-touch', \$touch)"),
      reason: '触屏判据由宿主注入（CSS 不能写 @media）',
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

  final String js = File('assets/popup/popup.js').readAsStringSync();

  String jsFunction(String signature) {
    final int at = js.indexOf(signature);
    expect(at, isNonNegative, reason: '缺少 $signature');
    return js.substring(at, js.indexOf('\n}\n', at));
  }

  test('multi-column geometry keys off the effective column count', () {
    final String body = jsFunction('function updateEffectiveDictColumns()');
    expect(
      body,
      contains("container.classList.toggle('fushi-dict-multicol', cols > 1)"),
    );
    expect(
      body,
      contains("doc.classList.contains('fushi-glass-host')"),
      reason: '扩展里 documentElement 是宿主页，只有 app 内弹窗文档带 fushi-glass-host',
    );
  });

  test('Apple design system renders SF glyphs, Material keeps its paths', () {
    final String table = js.substring(
      js.indexOf('const APPLE_ICON_PATHS = {'),
      js.indexOf('\n};\n', js.indexOf('const APPLE_ICON_PATHS = {')),
    );
    final int iconsAt = js.indexOf('const ICON_PATHS = {');
    final String material = js.substring(iconsAt, js.indexOf('\n};', iconsAt));
    for (final RegExpMatch m in RegExp(
      r'^    (\w+):',
      multiLine: true,
    ).allMatches(material)) {
      expect(table, contains('    ${m.group(1)}: {'), reason: m.group(1));
    }
    for (final String name in <String>['mined', 'latest', 'remote']) {
      expect(table, contains('    $name: {'), reason: name);
    }
    final String iconSvg = jsFunction('function iconSvg(name)');
    expect(iconSvg, contains('__fushiAppleIcons() ? APPLE_ICON_PATHS[name]'));
    expect(iconSvg, contains('ICON_PATHS[name]'));
    final String mine = jsFunction('function __fushiPaintMineGlyph(button)');
    expect(mine, contains('iconSvg(glyph)'));
    expect(mine, contains("'✓↩︎'"), reason: 'Material / 墨水屏保留 TODO-1325 的文本标记');
    expect(
      ruleBody(
        'html.fushi-glass-host.fushi-apple .header-buttons > .mine-button::after',
      ).trim(),
      'content: none;',
      reason: 'Apple 下不再用 ::before/::after 拼十字',
    );
  });

  test('extension Cupertino style re-roots the Apple layer onto the popup', () {
    final String theme = File(
      '../tools/browser-extension/theme.js',
    ).readAsStringSync();
    expect(theme, contains("container.classList.toggle('fushi-apple', apple)"));
    expect(
      theme,
      contains("container.classList.toggle('fushi-glass-host', apple)"),
    );
    for (final String path in <String>[
      'assets/browser_extension/vendor/content.css',
      '../tools/browser-extension/vendor/content.css',
    ]) {
      final String out = maskCssComments(File(path).readAsStringSync());
      expect(
        out,
        contains(
          ':where(#entries-container).fushi-glass-host.fushi-apple .glossary-group',
        ),
        reason: path,
      );
      expect(
        out,
        isNot(contains('html.fushi-glass-host.fushi-apple')),
        reason: path,
      );
    }
  });
}
