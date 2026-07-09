import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1325 #7 守卫（超越 TODO-877/TODO-849 的往返，按用户 Niratan「卡片」决策）：查词
/// 弹窗里每本词典的义项块 (`.glossary-group`) 是一枚「玻璃卡片」——圆角(走 token
/// `--hibiki-radius-card`，与弹窗其余卡片统一) + 分层投影 + 顶部内高光 + 内边距。皮肤挂在
/// 基类 `.glossary-group` 上（四端共用），暗色变体单独一条。
///
/// 同时仍锁住原 TODO-877/TODO-776 的两个不变量不被卡片改动破坏：
///   * 间距模型：`.glossary-section > .category-body > .glossary-group` 仍走 margin-top +
///     min-width:0，父 `.category-body` 只用 column-gap（禁 row-gap/gap，否则双倍行距）；
///   * 长按选词典的 `.dict-label.selected` primary 高亮 + 扁平小标题 `.dict-label` 不丢。
///
/// 这些是纯 CSS 不变量；popup.js 的 node 守卫 CI 不跑，故在 Dart 层断言以进 CI 真跑。
void main() {
  late String css;

  setUpAll(() {
    css = File('assets/popup/popup.css').readAsStringSync();
  });

  /// 抽取选择器规则块内容（单层花括号，popup 这些规则无嵌套；box-shadow 的逗号在花括号内
  /// 不影响）。用行首锚定避免匹配到 `> .glossary-group {` 之类后代规则。
  String ruleBody(String selectorPattern) {
    final RegExp re = RegExp(r'(?:^|\n)' + selectorPattern + r'\s*\{([^}]*)\}');
    final RegExpMatch? m = re.firstMatch(css);
    expect(m, isNotNull,
        reason: '选择器规则块应存在于 assets/popup/popup.css: $selectorPattern');
    return m!.group(1)!;
  }

  test('每本词典义项块是玻璃卡片：基类 .glossary-group 有圆角/投影/底色/内边距 (TODO-1325 #7)', () {
    final String body = ruleBody(r'\.glossary-group');
    expect(RegExp(r'border-radius\s*:').hasMatch(body), isTrue,
        reason: '卡片要有圆角');
    expect(body.contains('var(--hibiki-radius-card'), isTrue,
        reason: '圆角走 --hibiki-radius-card token，与弹窗其余卡片统一，不硬编码');
    expect(RegExp(r'box-shadow\s*:').hasMatch(body), isTrue,
        reason: '卡片要有分层投影 + 内高光（玻璃质感）');
    expect(body.contains('inset'), isTrue,
        reason: 'box-shadow 含 inset 顶部高光营造玻璃质感');
    expect(RegExp(r'background\s*:').hasMatch(body), isTrue,
        reason: '卡片要有底色（--surface-container 分层）');
    expect(RegExp(r'padding\s*:').hasMatch(body), isTrue, reason: '卡片要有内边距');
  });

  test('暗色主题有独立卡片变体（降内高光 / 加深投影）(TODO-1325 #7)', () {
    final String body = ruleBody(r'html\[data-theme="dark"\] \.glossary-group');
    expect(RegExp(r'box-shadow\s*:').hasMatch(body), isTrue,
        reason: '暗色卡片单独调投影 / 内高光强度');
    expect(RegExp(r'background\s*:').hasMatch(body), isTrue,
        reason: '暗色卡片单独底色');
  });

  test('间距仍走 margin-top + min-width，未破坏 TODO-776 grid 间距模型', () {
    final String body = ruleBody(
        r'\.glossary-section\s*>\s*\.category-body\s*>\s*\.glossary-group');
    expect(RegExp(r'margin-top\s*:').hasMatch(body), isTrue,
        reason: 'TODO-776 行距靠 margin-top，grid 不能改用 gap/row-gap 否则双倍间距');
    expect(RegExp(r'min-width\s*:\s*0').hasMatch(body), isTrue,
        reason: 'min-width:0 防止长义项把 grid track 撑宽溢出弹窗');
  });

  test('parent 仍只用 column-gap，不引入会双倍间距的 row-gap/gap', () {
    final String body = ruleBody(r'\.glossary-section\s*>\s*\.category-body');
    expect(RegExp(r'column-gap\s*:').hasMatch(body), isTrue,
        reason: '多列布局只用 column-gap');
    expect(RegExp(r'(^|[^-])row-gap\s*:').hasMatch(body), isFalse,
        reason: 'row-gap 会与 .glossary-group 的 margin-top 叠成双倍行距');
    expect(RegExp(r'(^|[;{\s])gap\s*:').hasMatch(body), isFalse,
        reason: 'gap 简写含 row-gap，同样会双倍行距');
  });

  test('.dict-label 是扁平小标题：display:block + opacity:0.7，非 flex 大方块', () {
    final String body = ruleBody(r'\.dict-label');
    expect(RegExp(r'display\s*:\s*block').hasMatch(body), isTrue,
        reason: '标题行扁平态 display:block');
    expect(RegExp(r'display\s*:\s*flex').hasMatch(body), isFalse,
        reason: '标题不是整条 flex 大方块');
    expect(RegExp(r'opacity\s*:\s*0\.7').hasMatch(body), isTrue,
        reason: '半透明小标题 opacity:0.7');
  });

  test('.dict-label.selected 长按选词典视觉语义保留，不被一并删掉', () {
    final String body = ruleBody(r'\.dict-label\.selected');
    expect(body.contains('var(--primary-color)'), isTrue,
        reason: '选为制卡首选词典时仍用 primary 色高亮，hibiki 独有交互不能丢');
    expect(RegExp(r'font-weight\s*:\s*bold').hasMatch(body), isTrue,
        reason: '选中态仍加粗');
  });

  /// TODO-1325 / BUG-683：查词弹窗「第一个卡片比其他卡片高」。多词典时每部词典是一枚
  /// `.glossary-group` 玻璃卡片，作为 `.glossary-section > .category-body` 的 grid 项
  /// （桌面默认 2 列）。grid 默认 `align-items:stretch` 会把同一行的卡片全部拉到该行最高
  /// 卡片的高度：首行含义项最多的词典被拉高后，同行义项少的卡片下方留出空白玻璃盒，读作
  /// 「首卡特别高」。修复 = 显式 `align-items:start`，卡片取自然内容高度（对齐 Niratan 的
  /// 自然高度卡片，不等高拉伸）。
  ///
  /// 用 indexOf/substring 抽取规则块（与 popup_dictionary_columns_test 同法），再剥离
  /// /* ... */ 注释——popup.css 的解释性注释里也写了「align-items:stretch / start」字样，
  /// 只断言真实声明。
  String stripComments(String s) => s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

  test('首卡不被等高拉伸：.category-body grid 显式 align-items:start (BUG-683)', () {
    final int start = css.indexOf('.glossary-section > .category-body {');
    expect(start, isNonNegative, reason: 'in-app grid 容器规则必须存在');
    final int end = css.indexOf('}', start);
    expect(end, greaterThan(start));
    final String rule = stripComments(css.substring(start, end));
    expect(RegExp(r'align-items\s*:\s*start').hasMatch(rule), isTrue,
        reason: '首卡偏高根因 = grid 默认 align-items:stretch 把同行卡片拉到最高；'
            '必须显式 align-items:start 让卡片取自然内容高度');
    expect(RegExp(r'align-items\s*:\s*stretch').hasMatch(rule), isFalse,
        reason: '不得回退 stretch，否则首卡又被拉伸出空白玻璃盒');
    // 仍是 --dict-columns 驱动的多列 grid（TODO-776/1357 未被破坏）。
    expect(rule.contains('display: grid'), isTrue);
    expect(rule.contains('repeat(var(--dict-columns'), isTrue);
  });

  test('玻璃卡片不钉死高度，取自然内容高度 (BUG-683)', () {
    final String body = stripComments(ruleBody(r'\.glossary-group'));
    expect(RegExp(r'(^|[;{\s])height\s*:').hasMatch(body), isFalse,
        reason: '卡片不能钉死 height，否则内容高度失真、又回到等高观感');
    expect(RegExp(r'min-height\s*:').hasMatch(body), isFalse,
        reason: '卡片不能设 min-height 强制等高');
  });
}
