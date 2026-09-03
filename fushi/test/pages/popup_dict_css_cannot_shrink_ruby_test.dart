import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1897：某些词典的振假名小到看不清（用户 2026-08-28 报「小学館例解学習国語
/// 第十二版 怎么振假名这么小」）。
///
/// 根因是**双重缩放**，不是尺寸调小了：
/// * 弹窗把 ruby 拆成 `.ruby-unit > .ruby-rt > rt` 三层手工模拟，字号由 `.ruby-rt`
///   这个盒统一承担（`0.6em`，BUG-1655），内层 `<rt>` 由
///   `.ruby-rt rt { font-size: 1em }` 归一化，防止再缩一次；
/// * 词典 zip 自带的 `styles.css` 经 `constructDictCss` 逐规则加前缀后注入进该词典
///   的 dictWrapper 内部，于是词典里一条**裸** `rt { font-size: 0.5em }` 变成
///   `[data-dictionary="X"] rt {...}` —— 特异度 (0,1,1)，与那条归一化规则**打平**，
///   却注入得更晚，靠文档顺序赢；
/// * 结果 `0.6em × 0.5 = 0.3em`：15px 正文下振假名只剩 4.5px。
///
/// 实测证据（2026-08-28，`[JA-JA] 小学館例解学習国語 第十二版[2025-08-18].zip`）：
/// 其 `styles.css` 第 328 行正是 `rt { font-size: 0.5em; font-weight: normal; }`，
/// 另有 `rt[data-sc-small] { font-size: 0.4em }`。对照组「明鏡国語辞典 第三版」不设
/// 裸 `rt` 字号（只有一条 `span[data-sc-rt]`，选择器命不中 `<rt>` 元素）——正好对上
/// 用户「小学館小、明鏡不小」的区分。
///
/// 修复：归一化声明加 `!important`。振假名几何归弹窗所有——词典作者写 `rt` 字号时
/// 假设的是**原生 ruby**（只作用一次），在这套三层模拟下没有正确语义；rt 的颜色 /
/// 字重等非几何声明不受影响。
void main() {
  test(
    'popup.css normalises the inner <rt> font-size with !important so '
    'dictionary-supplied `rt {}` cannot compound with .ruby-rt (BUG-1897)',
    () {
      final String css = File('assets/popup/popup.css').readAsStringSync();

      final RegExp normaliser = RegExp(
        r':where\([^)]*\bglossary-group\b[^)]*\)\s*\.ruby-rt\s+rt\s*\{([^}]*)\}',
      );
      final RegExpMatch? match = normaliser.firstMatch(css);
      expect(
        match,
        isNotNull,
        reason: 'popup.css must keep the `.ruby-rt rt` normaliser — without it '
            'every dictionary rt size compounds with the .ruby-rt box',
      );
      final String body = match!.group(1)!;

      final RegExpMatch? decl = RegExp(
        r'font-size\s*:\s*([^;]+);',
      ).firstMatch(body);
      expect(decl, isNotNull, reason: '`.ruby-rt rt` must declare a font-size');
      final String value = decl!.group(1)!.trim();

      expect(
        value.startsWith('1em'),
        isTrue,
        reason: '内层 <rt> 必须恒为 1em —— 尺寸的唯一承担者是 .ruby-rt 盒（BUG-1655），'
            '现为 "$value"',
      );
      expect(
        value.contains('!important'),
        isTrue,
        reason: '必须带 !important：词典 styles.css 被加前缀后是 '
            '`[data-dictionary="X"] rt`（特异度 0,1,1），与本条打平且注入更晚，'
            '不加就会被词典的 `rt{font-size:0.5em}` 覆盖成 0.6em×0.5=0.3em（BUG-1897）',
      );
    },
  );

  test(
    'the .ruby-rt box remains the single em-scale site (BUG-1655 invariant)',
    () {
      final String css = File('assets/popup/popup.css').readAsStringSync();
      final RegExp boxRule = RegExp(
        r':where\([^)]*\bglossary-group\b[^)]*\)\s*\.ruby-rt\s*\{([^}]*)\}',
      );
      final RegExpMatch? box = boxRule.firstMatch(css);
      expect(box, isNotNull, reason: 'popup.css must scope the .ruby-rt box');
      final RegExpMatch? size = RegExp(
        r'font-size\s*:\s*([\d.]+em)',
      ).firstMatch(box!.group(1)!);
      expect(
        size,
        isNotNull,
        reason: '.ruby-rt 必须用 em 声明字号，才能随 popupContentZoom 等比缩放'
            '（BUG-363）',
      );
      // 不钉死具体数值：它是可调的产品值（0.5em → 0.6em，BUG-1655）。这里只锁
      // 「盒是唯一缩放点」这个结构不变量。
    },
  );
}
