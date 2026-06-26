import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-849 守卫：查词弹窗里每本词典的义项块 (`.glossary-group`) 卡片化
/// （边框 / 圆角 / 浅底，折叠态与展开态都卡片化），标题行 (`.dict-label`)
/// 做成整条可点的大方块以扩大折叠/展开点击热区。
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

  test('每本词典卡片化：.glossary-group 有边框/圆角/底色 (TODO-849)', () {
    final String body = ruleBody(
        r'\.glossary-section\s*>\s*\.category-body\s*>\s*\.glossary-group');
    expect(RegExp(r'border\s*:').hasMatch(body), isTrue,
        reason: '卡片需要边框 (border)');
    expect(RegExp(r'border-radius\s*:').hasMatch(body), isTrue,
        reason: '卡片需要圆角 (border-radius)');
    expect(RegExp(r'background\s*:').hasMatch(body), isTrue,
        reason: '卡片需要浅底 (background)');
  });

  test('卡片用主题变量而非硬编码颜色，跟随浅色/深色/动态色 (TODO-849)', () {
    final String body = ruleBody(
        r'\.glossary-section\s*>\s*\.category-body\s*>\s*\.glossary-group');
    expect(body.contains('var(--outline-variant)'), isTrue,
        reason: '边框色须用 var(--outline-variant) 跟随主题，不能硬编码');
    expect(body.contains('var(--surface-container)'), isTrue,
        reason: '卡片底色须用 var(--surface-container) 跟随主题，不能硬编码');
  });

  test('间距仍走 margin-top + min-width，未破坏 TODO-776 grid 间距模型 (TODO-849)', () {
    final String body = ruleBody(
        r'\.glossary-section\s*>\s*\.category-body\s*>\s*\.glossary-group');
    expect(RegExp(r'margin-top\s*:').hasMatch(body), isTrue,
        reason: 'TODO-776 行距靠 margin-top，grid 不能改用 gap/row-gap 否则双倍间距');
    expect(RegExp(r'min-width\s*:\s*0').hasMatch(body), isTrue,
        reason: 'min-width:0 防止长义项把 grid track 撑宽溢出弹窗');
  });

  test('parent 仍只用 column-gap，不引入会双倍间距的 row-gap/gap (TODO-849)', () {
    final String body = ruleBody(r'\.glossary-section\s*>\s*\.category-body');
    expect(RegExp(r'column-gap\s*:').hasMatch(body), isTrue,
        reason: '多列布局只用 column-gap');
    expect(RegExp(r'(^|[^-])row-gap\s*:').hasMatch(body), isFalse,
        reason: 'row-gap 会与 .glossary-group 的 margin-top 叠成双倍行距');
    expect(RegExp(r'(^|[;{\s])gap\s*:').hasMatch(body), isFalse,
        reason: 'gap 简写含 row-gap，同样会双倍行距');
  });

  test('.dict-label 是整条可点大方块：display:flex + cursor:pointer (TODO-849)', () {
    final String body = ruleBody(r'\.dict-label');
    expect(RegExp(r'display\s*:\s*flex').hasMatch(body), isTrue,
        reason: '标题行须 display:flex 占满卡片宽，整条都是点击热区');
    expect(RegExp(r'cursor\s*:\s*pointer').hasMatch(body), isTrue,
        reason: '标题行须 cursor:pointer 提示可点击展开/折叠');
  });

  test('.dict-label.selected 长按选词典视觉语义保留 (TODO-849 不回归)', () {
    final String body = ruleBody(r'\.dict-label\.selected');
    expect(body.contains('var(--primary-color)'), isTrue,
        reason: '选为制卡首选词典时仍用 primary 色高亮，不能丢');
    expect(RegExp(r'font-weight\s*:\s*bold').hasMatch(body), isTrue,
        reason: '选中态仍加粗');
  });
}
