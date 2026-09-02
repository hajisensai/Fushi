// BUG-2037：查词弹窗的语法说明浮层背景半透明，透出下面的词典正文。
//
// 根因不是浮层自己的样式，而是 popup.css 的兜底块选择器写成了 `html, body`：
// 主题真值只声明在 `html[data-theme="light"|"dark"]` / `html.eink[...]` 上，而
// 自定义属性靠**继承**往下传，「元素自身的声明」永远优先于「继承来的值」。一旦
// 同一个自定义属性既在 `html[data-theme]` 上有真值、又在 `body` 上有兜底值，
// body 及其全部后代拿到的就永远是兜底值——`.grammar-tooltip` 的
// `background: var(--surface-container-high)` 于是恒为 rgba(128,128,128,0.14)。
//
// 这条守卫按**行为**判据钉住，不钉字面量：凡是被某个 `html...` 主题块重新定义过
// 的自定义属性，都不许再出现在任何命中 `body` 的规则里。新增主题变量、改名、调
// 兜底值都不会让它假红；把兜底块的选择器改回带 body 才会红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 一条 CSS 规则：选择器 + 声明块正文。
typedef _CssRule = ({String selector, String body});

/// 顶层规则切分。`@media` 一类的嵌套块会被整块当成一条「规则」，其正文里的
/// 声明不会被误当作顶层声明——这对本守卫足够：主题块与兜底块都在顶层。
List<_CssRule> _topLevelRules(String css) {
  final List<_CssRule> rules = <_CssRule>[];
  int i = 0;
  while (i < css.length) {
    final int open = css.indexOf('{', i);
    if (open < 0) break;
    final String selector = css.substring(i, open).trim();
    int depth = 1;
    int j = open + 1;
    while (j < css.length && depth > 0) {
      if (css[j] == '{') depth++;
      if (css[j] == '}') depth--;
      j++;
    }
    rules.add((selector: selector, body: css.substring(open + 1, j - 1)));
    i = j;
  }
  return rules;
}

/// 规则正文里直接声明的自定义属性名（`--foo: bar;` 的 `--foo`）。
Set<String> _declaredCustomProperties(String body) {
  return RegExp(
    r'(^|[;{])\s*(--[A-Za-z0-9_-]+)\s*:',
    multiLine: true,
  ).allMatches(body).map((RegExpMatch m) => m.group(2)!).toSet();
}

/// 选择器列表里是否有一项会命中 `body` 元素本身。
bool _matchesBodyElement(String selectorList) {
  for (final String raw in selectorList.split(',')) {
    final String sel = raw.trim();
    if (sel.isEmpty) continue;
    // 只看最后一个复合选择器（后代选择器里前面的部分是祖先，不是被声明的元素）。
    final String last = sel.split(RegExp(r'[\s>+~]+')).last;
    if (last == 'body' ||
        last.startsWith('body.') ||
        last.startsWith('body[')) {
      return true;
    }
  }
  return false;
}

void main() {
  final File cssFile = File('assets/popup/popup.css');

  test('popup.css: 主题变量不得在 body 上被兜底值遮住（BUG-2037）', () {
    expect(
      cssFile.existsSync(),
      isTrue,
      reason: '找不到 ${cssFile.path}（工作目录应为 fushi/）',
    );
    final List<_CssRule> rules = _topLevelRules(
      maskCssComments(cssFile.readAsStringSync()),
    );

    // 1) 收集「被主题块重新定义过」的自定义属性 —— 这些属性的真值住在 html 上。
    final Set<String> themeOwned = <String>{};
    for (final _CssRule r in rules) {
      final bool isThemeBlock = r.selector.split(',').any((String s) {
        final String sel = s.trim();
        return sel.startsWith('html') && sel != 'html';
      });
      if (isThemeBlock) themeOwned.addAll(_declaredCustomProperties(r.body));
    }
    expect(
      themeOwned,
      isNotEmpty,
      reason:
          'popup.css 里没解析到任何 html[...] 主题块，守卫已失去判据——'
          '主题变量机制若真被改掉，这里要跟着改，而不是让断言空转',
    );
    expect(
      themeOwned,
      contains('--surface-container-high'),
      reason: '.grammar-tooltip 的背景就取自这个变量，它必须由主题块拥有',
    );

    // 2) 任何命中 body 的规则都不许再声明这些属性。
    final List<String> offenders = <String>[];
    for (final _CssRule r in rules) {
      if (!_matchesBodyElement(r.selector)) continue;
      final Set<String> shadowed = _declaredCustomProperties(
        r.body,
      ).intersection(themeOwned);
      if (shadowed.isEmpty) continue;
      offenders.add(
        '选择器 `${r.selector}` 遮住了 '
        '${(shadowed.toList()..sort()).join(', ')}',
      );
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '这些自定义属性的真值声明在 html 上（主题块 / Dart 注入的 --md-*），'
          '再在 body 上写一份兜底值就会把主题值对整棵 body 子树彻底屏蔽（BUG-2037：'
          '.grammar-tooltip 背景恒为半透明灰）。兜底值请只写在 `html` 选择器上：\n'
          '${offenders.join('\n')}',
    );
  });

  test('popup.css: 语法说明浮层仍是不透明卡片（BUG-2037）', () {
    final List<_CssRule> rules = _topLevelRules(
      maskCssComments(cssFile.readAsStringSync()),
    );
    final _CssRule tooltip = rules.firstWhere(
      (_CssRule r) => r.selector
          .split(',')
          .any((String s) => s.trim() == '.grammar-tooltip'),
      orElse: () => (selector: '', body: ''),
    );
    expect(
      tooltip.selector,
      isNotEmpty,
      reason: 'popup.css 里找不到 .grammar-tooltip 规则',
    );
    // 浮层盖在词典正文之上，必须有背景；直接写 transparent / 半透明 rgba 都会
    // 让正文透出来（这正是用户报的现象）。
    final RegExp bg = RegExp(r'background(-color)?\s*:\s*([^;]+);');
    final RegExpMatch? m = bg.firstMatch(tooltip.body);
    expect(m, isNotNull, reason: '.grammar-tooltip 必须显式声明背景色');
    final String value = m!.group(2)!.trim();
    expect(
      value.contains('transparent'),
      isFalse,
      reason: '.grammar-tooltip 背景不能是 transparent：$value',
    );
    expect(
      RegExp(r'rgba\([^)]*,\s*0?\.\d+\s*\)').hasMatch(value),
      isFalse,
      reason: '.grammar-tooltip 背景不能是半透明 rgba（正文会透出来）：$value',
    );
  });
}
