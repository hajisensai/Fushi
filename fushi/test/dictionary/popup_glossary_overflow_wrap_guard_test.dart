import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（BUG-1827）：查词弹窗的词典义项卡 `.glossary-group` 必须在**卡片层**声明
/// `overflow-wrap: anywhere`，让卡内找不到断点的短语能折行，而不是画到卡片外。
///
/// 根因：`somebody/something` 这类 `词/词` 短语在 UAX #14 下是**不可断单元**（`/` 是
/// SY 类，`SY × AL` 不允许断行），其 min-content 宽度 = 整串宽度。CSS grid 回落模式下
/// 撑破 `minmax(0, 1fr)` 的 track；masonry 模式下更直接——卡片是 `position:absolute`
/// + JS 硬设 `width: columnWidth`（popup.js `layoutMasonry`），盒子宽度钉死撑不大，
/// 内容整条**溢出到卡外、压在相邻列的正文上**（用户报「查词的字出了框」）。
///
/// headless Edge 实测（完整 popup.css + 170px 最窄列宽，`getClientRects()` 逐换行片段
/// 量右边界）：未修时 `somebody/something` 1 个片段、越界 +1.91px；加上本规则后折成
/// 2 个片段、最差 -15.41px。
///
/// BUG-860 当时只给 `<a>` 加了这条规则（那次的长串恰好是裸 URL），但「找不到断点」与
/// 元素是不是链接无关。故规则提到卡片层：`overflow-wrap` 是继承属性，一次声明覆盖卡内
/// 全部后代。
///
/// ⚠️ 断言必须**剥掉 CSS 注释**再执行：修复的注释里就写着「`anywhere` 而非
/// `break-word`」等字样，朴素子串匹配会被注释假阳性命中——删掉真实声明、只留注释也会绿。
///
/// 三镜像铁律：popup.css 是查词弹窗真值源，改动必须同步到浏览器扩展两份 vendored
/// 镜像；content.css 由 `tools/browser-extension/scripts/generate-content-css.mjs`
/// 从 popup.css 生成，故也必须带上（防止只改 popup.css 忘了重新生成）。
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// 剥掉 CSS 块注释（CSS 只有 `/* */` 一种），只留真实声明。
  String stripCssComments(String css) =>
      css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');

  /// 取剥注释后的顶层 `.glossary-group { ... }` 规则块。
  String extractGlossaryGroupRule(String path) {
    final String css = stripCssComments(read(path));
    final Match? m = RegExp(
      r'(?:^|\n)\.glossary-group\s*\{([^}]*)\}',
    ).firstMatch(css);
    expect(
      m,
      isNotNull,
      reason: '$path 应有顶层 .glossary-group { } 规则（规则被改名/删除时守卫需同步更新）',
    );
    return m!.group(1)!;
  }

  const List<String> popupMirrors = <String>[
    'assets/popup/popup.css',
    'assets/browser_extension/vendor/popup.css',
    '../tools/browser-extension/vendor/popup.css',
  ];

  const List<String> contentMirrors = <String>[
    'assets/browser_extension/vendor/content.css',
    '../tools/browser-extension/vendor/content.css',
  ];

  test('剥注释前置自检：注释里的 overflow-wrap 不算数，真实声明必须留下', () {
    // 本守卫自身的反例保护。修复注释里确实出现「overflow-wrap」「anywhere」字样，
    // 若 stripCssComments 失效，下面的断言会集体假绿（恒命中 = 恒不报警）。
    expect(
      stripCssComments('/* 用 overflow-wrap: anywhere 而非 break-word */'),
      isNot(contains('overflow-wrap')),
      reason: 'CSS 注释里的声明必须被剥掉，否则「只留注释」也能骗过守卫',
    );
    expect(
      stripCssComments('.x { overflow-wrap: anywhere; } /* 说明 */'),
      contains('overflow-wrap: anywhere'),
      reason: '真实声明必须保留，否则守卫恒不命中 = 恒假绿',
    );
  });

  test('BUG-1827：三镜像 popup.css 的 .glossary-group 都在卡片层声明断词', () {
    for (final String path in popupMirrors) {
      final String rule = extractGlossaryGroupRule(path);
      expect(
        RegExp(r'overflow-wrap:\s*anywhere').hasMatch(rule),
        isTrue,
        reason:
            '$path 的 .glossary-group 缺 overflow-wrap:anywhere —— 卡内 '
            '`somebody/something` 这类不可断短语会溢出卡片、压在相邻列正文上'
            '（BUG-1827 回归）。必须是 anywhere 而非 break-word：'
            '只有前者缩小 min-content，卡片才不会被撑宽。',
      );
    }
  });

  test('BUG-1827：扩展注入用的 content.css 也带上了同一条规则', () {
    for (final String path in contentMirrors) {
      final String rule = extractGlossaryGroupRule(path);
      expect(
        RegExp(r'overflow-wrap:\s*anywhere').hasMatch(rule),
        isTrue,
        reason:
            '$path 的 .glossary-group 缺断词规则'
            '（改了 popup.css 但忘了重跑 generate-content-css.mjs）',
      );
    }
  });

  test('BUG-860 未被回退：顶层 a 规则仍各自带断词（两条规则互不替代）', () {
    // 卡片层的继承覆盖了卡内的 <a>，但 popup 里还有卡外的链接；且 BUG-860 与本条
    // 分属两条不变量，这里只做一次交叉确认，防止有人「既然卡片层有了就把 a 那条删掉」
    // 而让卡外链接回归出框。
    for (final String path in popupMirrors) {
      final String css = stripCssComments(read(path));
      final Match? m = RegExp(
        r'(?:^|\n)a\s*\{([^}]*)\}',
        multiLine: true,
      ).firstMatch(css);
      expect(m, isNotNull, reason: '$path 应有顶层 a { } 规则');
      expect(
        RegExp(r'overflow-wrap:\s*anywhere').hasMatch(m!.group(1)!),
        isTrue,
        reason: '$path 的 a{} 断词规则被删了：卡片层的继承管不到卡外链接（BUG-860 回归）',
      );
    }
  });
}
