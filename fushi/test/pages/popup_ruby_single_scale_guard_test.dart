import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

// 查词浮窗振假名的字号（词头 + glossary 逐字 ruby）由**两条互相抵消的规则**共同决定，此前
// 没有任何测试锁住这个契约：
//
//   1. BUG-1487 把绝对定位的注音盒从 <rt> 挪到中性的 <span class="ruby-rt">（WebKit 在渲染器
//      层把 <rt> 的 position 强制重置成 static，作者 CSS 覆盖不掉），新盒子必须自带
//      `font-size: 0.5em`（BUG-1487 当时的值，BUG-1655 已调到 0.6em）——绝对定位盒的
//      strut 由它自己的 font-size 决定；
//   2. 而 <rt> 上原有的同值 font-size（给 postProcessRuby 没包裹到的 bare markup 兜底）
//      会与盒子那层相乘，所以同一个提交补了 `.ruby-rt rt { font-size: 1em }` 抵消回来。
//
// 任何一条被动过，注音就会静默缩水成倍率的平方——而且很难一眼看穿：BUG-1655 的调查里，一个漏掉
// 第 2 条抵消规则的 headless 探针就"测出"了 6.5px，看起来完全可信却完全错误（用完整
// popup.css 复测，26px 词头下 rt 实为 13px，rtW/reserveW/unitW 三者对齐在 26.0，代码无缺陷）。
// 双重缩放不只是变小：`.ruby-reserve` 与注音盒同字号驱动 .ruby-unit 的宽度，注音一旦缩水
// 一半，in-flow 孪生体仍按全尺寸预留，每个汉字的占位就被多撑一倍。
//
// 这里守不变量而不是某一种写法：**注音的 em 缩放必须恰好施加一次**。扫描 popup.css 里
// 每一条目标元素是 <rt> 且声明 font-size 的规则，只放行两种形态：
//   1. 选择器显式包含 .ruby-rt 且把字号归一化回 1em/inherit（当前实现）；
//   2. 选择器用子代组合器限定成 `ruby > rt`——包裹后的 rt 恒为
//      ruby > .ruby-unit > .ruby-rt > rt，永远匹配不到，于是它只命中 bare markup。
// Ruby 几何无法 headless 渲染，所以在源码层守 CSS 级联契约。Windows popup 通过 _winCss
// 内联同一份 popup.css，一条守卫覆盖全平台。
void main() {
  final String css = File('assets/popup/popup.css').readAsStringSync();

  /// 掩掉注释：popup.css 的注释里写着 `rt { line-height: normal }`、
  /// `.ruby-rt rt { font-size: 1em }` 这类规则示例，不掩掉就会被当成真声明读出来
  /// （本守卫早期版本就栽在这上面）。用 source_guard 的**等长**掩码而不是删除式
  /// replaceAll：删除会让下标与原文错位，也挡不住「把 needle 藏进注释」的欺骗。
  final String code = maskCssComments(css);

  /// 粗切成 `选择器 { 声明 }`。@media 等嵌套块的外层不会以 rt 结尾，内层规则照样能被切出来。
  final Iterable<RegExpMatch> rules =
      RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(code);

  /// 这条规则的目标元素是不是 <rt>（逗号分组里任意一支的最后一个 compound 是 rt）。
  bool targetsRt(String selector) => selector
      .split(',')
      .any((String part) => RegExp(r'(^|[\s>+~])rt$').hasMatch(part.trim()));

  String? fontSizeOf(String body) =>
      RegExp(r'font-size\s*:\s*([^;]+);').firstMatch(body)?.group(1)?.trim();

  String? bodyOfSelector(String selector) {
    final RegExp rule = RegExp(
      ':where\\([^)]*\\bglossary-group\\b[^)]*,[^)]*\\bglossary-content\\b[^)]*\\)'
      '\\s*${RegExp.escape(selector)}\\s*\\{([^}]*)\\}',
    );
    // 必须在**剥掉注释**的文本上取：popup.css 的注释里引用了
    // `.ruby-rt rt { font-size: 1em }` 这样的规则片段，在含注释的原文上跑
    // font-size 正则会把注释内容当成声明读出来。
    return rule.firstMatch(code)?.group(1);
  }

  test(
      '注音盒 .ruby-rt 自带 em 缩放（绝对定位盒的 strut 来自它自己的 font-size，'
      'BUG-1487）', () {
    final String? body = bodyOfSelector('.ruby-rt');
    expect(body, isNotNull,
        reason: 'popup.css 必须为 glossary 面把 .ruby-rt 作用域化——注音的定位与尺寸都在它身上');
    expect(fontSizeOf(body!), matches(RegExp(r'^[\d.]+em$')),
        reason: '注音盒的字号必须以 em 表达——它要跟着 popupContentZoom 等比缩放（BUG-363）；'
            '具体倍率是可调的产品值（BUG-1655 已从 0.5em 调到 0.6em），这里只锁单位');
  });

  test(
      '注音的缩放恰好施加一次：任何会落到被包裹 <rt> 上的字号，都必须有 '
      '.ruby-rt 内的归一化规则抵消', () {
    // 会落到「被 .ruby-rt 包裹的 rt」身上的字号声明。用 `ruby > rt` 限定的不算——那个子代
    // 组合器只匹配 bare markup（包裹后恒为 ruby > .ruby-unit > .ruby-rt > rt）。
    final List<String> reachesWrappedRt = <String>[];
    // 把被包裹的 rt 归一化回盒子尺寸的规则。特异性 (0,1,1) 高于 `:where(…) rt` 的 (0,0,1)，
    // 所以只要它在，裸 rt 那条就赢不了被包裹的 rt。
    bool normalised = false;

    for (final RegExpMatch rule in rules) {
      final String selector = rule.group(1)!.trim();
      final String? size = fontSizeOf(rule.group(2)!);
      if (!targetsRt(selector) || size == null) continue;

      if (selector.contains('.ruby-rt')) {
        if (RegExp(r'^(1em|inherit)$').hasMatch(size)) {
          normalised = true;
        } else {
          reachesWrappedRt.add('`$selector` { font-size: $size }');
        }
        continue;
      }
      if (RegExp(r'ruby\s*>\s*rt$').hasMatch(selector)) continue;
      reachesWrappedRt.add('`$selector` { font-size: $size }');
    }

    if (reachesWrappedRt.isEmpty) {
      // 没有任何字号能落到被包裹的 rt 上——缩放只由 .ruby-rt 提供，结构上就只有一次。
      return;
    }
    expect(
      normalised,
      isTrue,
      reason: 'popup.css 里这些字号声明会落到被 .ruby-rt 包裹的 <rt> 上，与注音盒自己的 em '
          '缩放相乘（0.6em x 0.6em = 0.36em），同时让 .ruby-reserve 按全尺寸预留宽度把汉字撑开：\n'
          '  ${reachesWrappedRt.join('\n  ')}\n'
          '必须保留 `:where(…) .ruby-rt rt { font-size: 1em }` 这类归一化规则把盒子那层 em '
          '抵消掉（或把上面的选择器收窄成 `ruby > rt`，只命中 postProcessRuby 没包裹的 '
          'bare markup）',
    );
  });

  test(
      'bare markup 仍有与注音盒同值的 fallback：postProcessRuby 只走 '
      '`.glossary-content ruby, .expression ruby`，.glossary-group 下的裸 ruby 到不了',
      () {
    final String? body = bodyOfSelector('rt') ?? bodyOfSelector('ruby > rt');
    expect(body, isNotNull,
        reason: 'popup.css 必须保留一条命中未包裹 <rt> 的字号 fallback，否则 postProcessRuby '
            '没走到的裸 <ruby>（.glossary-group 下非 .glossary-content 的结构化内容）注音会按 '
            '1em 渲染，和正文一样大');
    expect(fontSizeOf(body!), equals(fontSizeOf(bodyOfSelector('.ruby-rt')!)),
        reason: 'bare fallback 的字号必须与注音盒一致，包裹与未包裹两种结构渲染尺寸才一致');
  });

  test(
      '.ruby-unit 的上方预留带容得下注音盒（放大振假名时必须同步抬高，'
      '否则注音顶出预留带撞上一行 BUG-108/363）', () {
    final String? unit = bodyOfSelector('.ruby-unit');
    expect(unit, isNotNull, reason: 'popup.css 必须为 glossary 面作用域化 .ruby-unit');
    final String? band =
        RegExp(r'padding-top\s*:\s*([\d.]+)em').firstMatch(unit!)?.group(1);
    expect(band, isNotNull,
        reason: '预留必须内生于单元且以 em 表达，才能随 popupContentZoom 等比缩放');
    final String? boxSize = fontSizeOf(bodyOfSelector('.ruby-rt')!);
    final double? boxEm = double.tryParse(
        RegExp(r'^([\d.]+)em$').firstMatch(boxSize ?? '')?.group(1) ?? '');
    expect(boxEm, isNotNull, reason: '注音盒字号必须是 em');
    expect(double.parse(band!), greaterThanOrEqualTo(boxEm!),
        reason: '注音盒 line-height:1，所以它占满自身字号的高度；预留带 ${band}em 必须 >= '
            '注音盒 ${boxEm}em，否则注音会顶出预留带、撞上上一行文字。调大振假名时'
            '这两个值必须一起调（BUG-1655: 0.6em 盒 / 0.66em 带）');
  });

  test('.ruby-reserve 与注音盒同字号，宽度预留才等于实际渲染宽度（BUG-850）', () {
    final String? reserve = bodyOfSelector('.ruby-reserve');
    expect(reserve, isNotNull,
        reason: 'popup.css 必须为 glossary 面作用域化 .ruby-reserve');
    expect(
        fontSizeOf(reserve!), equals(fontSizeOf(bodyOfSelector('.ruby-rt')!)),
        reason: 'in-flow 孪生体必须与注音盒同字号；两者一旦分叉，unit 预留的宽度就不等于注音'
            '真正渲染的宽度，汉字会被撑开或注音会溢出');
  });
}
