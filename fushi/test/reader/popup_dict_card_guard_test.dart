import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 守卫（按用户「照抄 Niratan」决策，取代 TODO-1325 #7 的玻璃卡皮肤）：查词弹窗里每本
/// 词典的义项块 (`.glossary-group`) 逐字对齐 Niratan Features/Popup/popup.css 的
/// **描边卡**——1px 半透明描边 + 圆角 + 顶部 inset 白高光 + 薄贴地投影 + 内边距，**无
/// background 填充**（比玻璃卡更扁平，与 Niratan 一致）。皮肤挂在基类 `.glossary-group`
/// 上（四端共用），暗色变体单独一条（描边转白 + 加深投影）。
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

  test('每本词典义项块是 Niratan 描边卡：基类 .glossary-group 有描边/圆角/inset高光投影/内边距，无填充', () {
    final String body = ruleBody(r'\.glossary-group');
    expect(RegExp(r'(^|[;{\s])border\s*:').hasMatch(body), isTrue,
        reason: 'Niratan 描边卡靠 1px 描边定形（rgba 0,0,0,.14），非 background 填充');
    expect(RegExp(r'border-radius\s*:').hasMatch(body), isTrue,
        reason: '卡片要有圆角');
    expect(RegExp(r'box-shadow\s*:').hasMatch(body), isTrue,
        reason: '卡片要有薄贴地投影 + 顶部 inset 白高光');
    expect(body.contains('inset'), isTrue,
        reason: 'box-shadow 含 inset 顶部高光（照抄 Niratan）');
    expect(RegExp(r'padding\s*:').hasMatch(body), isTrue, reason: '卡片要有内边距');
    expect(RegExp(r'background\s*:').hasMatch(body), isFalse,
        reason: 'Niratan 描边卡无 background 填充；有填充即偏离本家、退回玻璃卡');
  });

  test('暗色主题有独立描边卡变体（描边转白 + 加深投影）', () {
    final String body = ruleBody(r'html\[data-theme="dark"\] \.glossary-group');
    expect(RegExp(r'border-color\s*:').hasMatch(body), isTrue,
        reason: '暗色卡片单独把描边转白（rgba 255,255,255,.09）');
    expect(RegExp(r'box-shadow\s*:').hasMatch(body), isTrue,
        reason: '暗色卡片单独加深贴地投影');
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

  test('首卡不被等高拉伸：.category-body grid 显式 align-items:start (BUG-683)', () {
    final int start = css.indexOf('.glossary-section > .category-body {');
    expect(start, isNonNegative, reason: 'in-app grid 容器规则必须存在');
    final int end = css.indexOf('}', start);
    expect(end, greaterThan(start));
    final String rule = maskCssComments(css.substring(start, end));
    expect(RegExp(r'align-items\s*:\s*start').hasMatch(rule), isTrue,
        reason: '首卡偏高根因 = grid 默认 align-items:stretch 把同行卡片拉到最高；'
            '必须显式 align-items:start 让卡片取自然内容高度');
    expect(RegExp(r'align-items\s*:\s*stretch').hasMatch(rule), isFalse,
        reason: '不得回退 stretch，否则首卡又被拉伸出空白玻璃盒');
    // 仍是 --dict-columns 驱动的多列 grid（TODO-776/1357 未被破坏）。
    expect(rule.contains('display: grid'), isTrue);
    expect(rule.contains('repeat(var(--dict-columns'), isTrue);
  });

  test('描边卡不钉死高度，取自然内容高度 (BUG-683)', () {
    final String body = maskCssComments(ruleBody(r'\.glossary-group'));
    expect(RegExp(r'(^|[;{\s])height\s*:').hasMatch(body), isFalse,
        reason: '卡片不能钉死 height，否则内容高度失真、又回到等高观感');
    expect(RegExp(r'min-height\s*:').hasMatch(body), isFalse,
        reason: '卡片不能设 min-height 强制等高');
  });

  // ─── merged verbatim from popup_css_inline_block_guard_test.dart ───
  /// TODO-350 守卫：三省堂等词典的 pitch inline SVG 不独占行，依赖 popup.css 里
  /// `.gloss-image-scroll` 的 `display: inline-block`（若改回 `block`，inline pitch SVG
  /// 会被推成独占行 = 复现 TODO-350）。此前只有 JS 守卫
  /// (test/utils/misc/popup_asset_behavior_test.js) 断言该不变量，但 JS 守卫不进 CI
  /// （CI 只跑 flutter test 的 .dart），改回 block 时 CI 仍假绿。本 Dart 守卫在 CI 真跑。
  test(
    'popup.css .gloss-image-scroll keeps display:inline-block + overflow-x:auto (TODO-350)',
    () {
      final RegExpMatch? rule =
          RegExp(r'\.gloss-image-scroll\s*\{([^}]*)\}').firstMatch(css);
      expect(rule, isNotNull,
          reason: '.gloss-image-scroll 规则块应存在于 assets/popup/popup.css');
      final String body = rule!.group(1)!;
      expect(
        RegExp(r'display\s*:\s*inline-block').hasMatch(body),
        isTrue,
        reason:
            'TODO-350: pitch SVG 不独占行需 display:inline-block；改回 block 会让三省堂音调标记独占行',
      );
      expect(
        RegExp(r'overflow-x\s*:\s*auto').hasMatch(body),
        isTrue,
        reason: '宽图横向滚动容器需保留 overflow-x:auto',
      );
    },
  );
}
