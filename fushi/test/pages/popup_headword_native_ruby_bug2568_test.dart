// BUG-2568 — 查词弹窗**词头**的振假名不与基字居中对齐：读音贴着词的左边、整段向右
// 悬出，而不是像 Hoshi 那样把基字撑开、读音居中盖在词上。
//
// 根因不在「没对齐」的样式，而在词头**借用了释义体的紧凑基字方案**：
// BUG-1098 当年把 `.expression ruby` 一并塞进 postProcessRuby 和
// `:where(.glossary-group, .glossary-content, .expression)` 那组规则，为的是蹭到
// glossary 的 em 纵向预留（那部分是对的，见
// popup_headword_ruby_reserve_bug1098_test.dart）。但同一组规则还带着 BUG-345/1778
// 有意为之的**紧凑**：基字盒永远不为读音变宽，读音是 `position:absolute; left:0;
// right:0` 的盒子、宽度恒等于基字宽，读音更宽时只能悬出——而 Blink 把这段悬出锚在
// 基字的**起始边**（`text-align: center` 对溢出行盒不生效）。用本仓 popup.css 在
// 无头 Blink 实测 26px 词头 入寮/にゅうりょう：基字 [10.0,62.0]，读音 [10.0,73.8]，
// 左边齐平、右侧挂出 11.8px。整词一段是常态（segmentFurigana 无法把 にゅうりょう
// 拆给 入/寮），所以这是词头的日常形态，不是边角。
//
// 修法：词头换回**原生 <ruby>**——引擎自己的 ruby 算法会把基字串撑到注音宽度并让
// 两者互相居中（同一探针实测：基字串与读音同为 [10.0,73.8]，中心差 0.00px，入 与
// 寮 分摊读音宽度），与 Hoshi 的词头一致。释义体**保持**紧凑（逐字 ruby 不能拉花、
// 正文不能被长读音撑开，BUG-345/1778），两个面因此需要不同几何。
//
// 守的是这条分界不被重新抹掉：一旦有人把 `.expression` 塞回共享作用域或把
// `.expression ruby` 塞回 postProcessRuby，词头就又变回悬出态。ruby 几何无法 headless
// 渲染，故在源码层守 CSS 级联与 JS 选择器契约。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String rawCss = File('assets/popup/popup.css').readAsStringSync();
  final String css = maskCssComments(rawCss);
  final String js = File('assets/popup/popup.js').readAsStringSync();

  String? ruleBody(String selector) => RegExp(
        '(?:^|\n)${RegExp.escape(selector)}\\s*\\{([^}]*)\\}',
      ).firstMatch(css)?.group(1);

  test('词头走原生 ruby：`.expression ruby` 声明 display: ruby', () {
    final String? body = ruleBody('.expression ruby');
    expect(body, isNotNull,
        reason: '词头必须显式声明自己是 ruby 容器；缺了它，任何一条把 <ruby> 改成 '
            'inline-block 的规则都会让 Blink 退回「注音起始对齐悬在基字上方」');
    expect(RegExp(r'display\s*:\s*ruby\b').hasMatch(body!), isTrue,
        reason: '`display: ruby` 是原生 ruby 几何的开关');
  });

  test('共享的 glossary ruby 规则不得再把 .expression 纳入作用域', () {
    // 这组 `:where(...)` 规则实现的是紧凑基字 + 绝对定位注音盒（BUG-345/722/1778/
    // 1898）。词头一旦回到这个作用域，基字就不再被撑开，读音重新单侧悬出。
    final Iterable<RegExpMatch> shared =
        RegExp(r':where\(([^)]*)\)').allMatches(css);
    final List<String> leaked = <String>[
      for (final RegExpMatch m in shared)
        if (m.group(1)!.contains('glossary-content') &&
            m.group(1)!.contains('.expression'))
          m.group(0)!,
    ];
    expect(leaked, isEmpty,
        reason: '词头与释义体要的几何不同（BUG-2568 vs BUG-345/1778），作用域必须分开：\n'
            '  ${leaked.join('\n  ')}');
  });

  test('postProcessRuby 不再包裹词头 ruby', () {
    expect(js.contains("querySelectorAll('.glossary-content ruby')"), isTrue,
        reason: 'postProcessRuby 的 per-base 单元只服务释义体');
    expect(js.contains('.expression ruby\')'), isFalse,
        reason: '词头 ruby 一旦被包进 .ruby-unit/.ruby-rt，就又变成「紧凑基字 + 悬出读音」'
            '（BUG-2568）；词头要的是引擎原生的 ruby 布局');
  });

  test('词头注音字号用子代组合器限定，绝不会与注音盒的 em 相乘', () {
    // `.expression ruby > rt` 只可能命中 postProcessRuby **没有**包裹的 markup
    // （包裹后恒为 ruby > .ruby-unit > .ruby-rt > rt），所以它与 glossary 那层
    // 0.6em 的注音盒在结构上互斥——popup_ruby_single_scale_guard_test.dart 锁的
    // 「缩放只施加一次」因此照旧成立。
    final String? body = ruleBody('.expression ruby > rt');
    expect(body, isNotNull, reason: '词头注音字号必须落在 `.expression ruby > rt` 上');
    expect(RegExp(r'font-size\s*:\s*[\d.]+em').hasMatch(body!), isTrue);
    final String? shared = RegExp(
      r':where\([^)]*glossary-content[^)]*\)\s*\.ruby-rt\s*\{([^}]*)\}',
    ).firstMatch(css)?.group(1);
    expect(shared, isNotNull);
    expect(
      RegExp(r'font-size\s*:\s*([\d.]+)em').firstMatch(body)!.group(1),
      equals(
          RegExp(r'font-size\s*:\s*([\d.]+)em').firstMatch(shared!)!.group(1)),
      reason: '词头与释义体的振假名尺寸是同一个产品值（BUG-1655 的 0.6em），调一个必须调另一个',
    );
  });
}
