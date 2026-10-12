import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-3308：查词弹窗点「+」制卡按钮，按钮位置冒出一个差不多大的方形背景。
///
/// 根因：M3E 层的按压态把整圆图标按钮「收成圆角方块」——词条头按钮
/// `:active { border-radius: corner-medium (12px) }`、通用 inline-action-button
/// `:active { border-radius: corner-small }`、「调整上下文」`:active { 10px }`。
/// 制卡按钮自带实心 primary 底色，按住时整块底色变成 37px 的 12px 圆角方块
/// （Edge 无头 CDP 真鼠标按下实测 computed border-radius 999px → 12px）。
///
/// 修法：圆形图标按钮按下只缩放 + 叠状态层，形状恒为整圆。这里钉住两件事：
///  1. 任何命中圆形图标按钮的 `:active` 规则都不得把 border-radius 改成非整圆值；
///  2. M3E 静息态仍是整圆（corner-full），否则 1 的前提不成立。
/// 三镜像逐字节一致由 browser_extension_popup_parity_guard_test 另守。
void main() {
  final String css = maskCssComments(
    File('assets/popup/popup.css').readAsStringSync(),
  );

  const List<String> roundButtonClasses = <String>[
    '.inline-action-button',
    '.mine-button',
    '.audio-button',
    '.favorite-button',
    '.open-anki-button',
    '.clear-draft-button',
    '.ctx-adjust-button',
  ];

  /// 整圆的合法写法：corner-full 令牌、999px、50%，以及 32px 盒的 16px。
  final RegExp roundRadius = RegExp(
    r'^(var\(--md-sys-shape-corner-full\)|999px|9999px|50%|16px)$',
  );

  Iterable<({String selector, String body})> rules() sync* {
    for (final RegExpMatch m in RegExp(
      r'([^{}]*)\{([^{}]*)\}',
    ).allMatches(css)) {
      yield (selector: m.group(1)!.trim(), body: m.group(2)!);
    }
  }

  test('圆形图标按钮的按压态不把形状改成圆角方块', () {
    int checked = 0;
    for (final ({String selector, String body}) rule in rules()) {
      // 逐个选择器判，避免同一规则组里别的控件（如 .kanji-card-char）误伤。
      for (final String sel in rule.selector.split(',')) {
        if (!sel.contains(':active')) continue;
        if (!roundButtonClasses.any(sel.contains)) continue;
        checked++;
        for (final RegExpMatch d in RegExp(
          r'border-radius\s*:\s*([^;]+);',
        ).allMatches(rule.body)) {
          final String value = d.group(1)!.replaceAll('!important', '').trim();
          expect(
            roundRadius.hasMatch(value),
            isTrue,
            reason:
                '`${sel.trim()}` 按下把 border-radius 改成了 $value——'
                '圆形按钮会冒出方形背景（BUG-3308）',
          );
        }
      }
    }
    expect(checked, greaterThanOrEqualTo(3), reason: '扫描面不能是空的');
  });

  test('M3E 圆形图标按钮静息态是整圆', () {
    String? body(String selector) => RegExp(
      '(?:^|\\n)${RegExp.escape(selector)}\\s*\\{([^}]*)\\}',
    ).firstMatch(css)?.group(1);

    for (final String selector in <String>[
      'html.fushi-m3e .header-buttons > .inline-action-button',
      'html.fushi-m3e .inline-action-button',
    ]) {
      final String? b = body(selector);
      expect(b, isNotNull, reason: '缺少规则 `$selector`');
      expect(
        b,
        contains('border-radius: var(--md-sys-shape-corner-full)'),
        reason: '`$selector` 静息态必须整圆',
      );
    }
    expect(body('.ctx-adjust-button'), contains('border-radius: 16px'));
  });
}
