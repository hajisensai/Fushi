import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-877 守卫（反写 TODO-849 的卡片守卫）：查词弹窗里每本词典的义项块
/// (`.glossary-group`) 必须保持 Hoshi 的**扁平**形态——没有边框 / 圆角 / 浅底 /
/// padding，词典之间只靠 `margin-top` 空白分隔（对照 Hoshi
/// Features/Popup/popup.css `.glossary-group` :239-242 与 Pictures/popup_dict.PNG）。
/// 标题行 (`.dict-label`) 退回 Hoshi 的扁平小标题（display:block; opacity:0.7），
/// 不再做成带 padding/radius 的整条大方块。
///
/// 同时锁住 hibiki 自己的两个特性不被一并删掉：长按选词典的 `.selected` 主题色
/// 高亮，以及 TODO-776 的 grid 间距模型（margin-top + min-width:0）。
///
/// 这些是纯 CSS 不变量，只有 popup.js 的 node 守卫在 CI 不跑（CI 只跑 flutter
/// test 的 .dart），所以在 Dart 层断言以进 CI 真跑。
void main() {
  late String css;

  setUpAll(() {
    css = File('assets/popup/popup.css').readAsStringSync();
  });

  String ruleBody(String selectorPattern) {
    final RegExp re = RegExp(selectorPattern + r'\s*\{([^}]*)\}');
    final RegExpMatch? m = re.firstMatch(css);
    expect(m, isNotNull,
        reason: '选择器规则块应存在于 assets/popup/popup.css: $selectorPattern');
    return m!.group(1)!;
  }

  test('每本词典义项块扁平：.glossary-group 无边框/圆角/底色/padding (TODO-877)', () {
    final String body = ruleBody(
        r'\.glossary-section\s*>\s*\.category-body\s*>\s*\.glossary-group');
    expect(RegExp(r'border\s*:').hasMatch(body), isFalse,
        reason: '对齐 Hoshi 扁平态：词典块不应有边框 (border)');
    expect(RegExp(r'border-radius\s*:').hasMatch(body), isFalse,
        reason: '对齐 Hoshi 扁平态：词典块不应有圆角 (border-radius)');
    expect(RegExp(r'background\s*:').hasMatch(body), isFalse,
        reason: '对齐 Hoshi 扁平态：词典块不应有底色 (background)');
    expect(RegExp(r'padding\s*:').hasMatch(body), isFalse,
        reason: '对齐 Hoshi 扁平态：词典块不应有内边距 (padding)');
  });

  test('间距仍走 margin-top + min-width，未破坏 TODO-776 grid 间距模型 (TODO-877)', () {
    final String body = ruleBody(
        r'\.glossary-section\s*>\s*\.category-body\s*>\s*\.glossary-group');
    expect(RegExp(r'margin-top\s*:').hasMatch(body), isTrue,
        reason: 'TODO-776 行距靠 margin-top，grid 不能改用 gap/row-gap 否则双倍间距');
    expect(RegExp(r'min-width\s*:\s*0').hasMatch(body), isTrue,
        reason: 'min-width:0 防止长义项把 grid track 撑宽溢出弹窗');
  });

  test('parent 仍只用 column-gap，不引入会双倍间距的 row-gap/gap (TODO-877)', () {
    final String body = ruleBody(r'\.glossary-section\s*>\s*\.category-body');
    expect(RegExp(r'column-gap\s*:').hasMatch(body), isTrue,
        reason: '多列布局只用 column-gap');
    expect(RegExp(r'(^|[^-])row-gap\s*:').hasMatch(body), isFalse,
        reason: 'row-gap 会与 .glossary-group 的 margin-top 叠成双倍行距');
    expect(RegExp(r'(^|[;{\s])gap\s*:').hasMatch(body), isFalse,
        reason: 'gap 简写含 row-gap，同样会双倍行距');
  });

  test(
      '.dict-label 是 Hoshi 扁平小标题：display:block + opacity:0.7，非 flex 大方块 (TODO-877)',
      () {
    final String body = ruleBody(r'\.dict-label');
    expect(RegExp(r'display\s*:\s*block').hasMatch(body), isTrue,
        reason: '标题行回退到 Hoshi 扁平态 display:block');
    expect(RegExp(r'display\s*:\s*flex').hasMatch(body), isFalse,
        reason: '不再是整条 flex 大方块');
    expect(RegExp(r'opacity\s*:\s*0\.7').hasMatch(body), isTrue,
        reason: '对齐 Hoshi 半透明小标题 opacity:0.7');
    expect(RegExp(r'padding\s*:').hasMatch(body), isFalse,
        reason: '扁平小标题不应有 padding');
    expect(RegExp(r'border-radius\s*:').hasMatch(body), isFalse,
        reason: '扁平小标题不应有圆角');
  });

  test('.dict-label.selected 长按选词典视觉语义保留，不被一并删掉 (TODO-877)', () {
    final String body = ruleBody(r'\.dict-label\.selected');
    expect(body.contains('var(--primary-color)'), isTrue,
        reason: '选为制卡首选词典时仍用 primary 色高亮，hibiki 独有交互不能丢');
    expect(RegExp(r'font-weight\s*:\s*bold').hasMatch(body), isTrue,
        reason: '选中态仍加粗');
  });
}
