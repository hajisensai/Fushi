import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// BUG-4751 守卫：设置 › 外观（含页面背景）与导航速览卡（复习页「辞書」卡的
/// Open / Lookup history）用到的每个 i18n key，日文值里必须有假名或汉字。
///
/// 根因：`i18n_sync --add` 只收 en / zh 两份文本，日文先填英文占位，之后没人补译；
/// 改英文原文时日文也不跟着动，于是日文界面里挂着整页英文（反馈 R-GL8y9O_j 截图里
/// 的「Page background / Pure black dark / Jump history / Open / Lookup history」）。
/// 只比「日文 == 英文」会漏掉英文原文改过之后留下的旧英文（`app_ui_scale_hint`），
/// 所以这里直接查日文值里有没有日文字符。
///
/// 确实应与英文同形的 key（品牌名等）加进 [_allowLatinOnly] 并注明。
const Set<String> _allowLatinOnly = <String>{};

const List<String> _sources = <String>[
  'lib/src/settings/settings_schema_appearance.dart',
  'lib/src/settings/settings_schema_page_backdrop.dart',
  'lib/src/utils/adaptive/nav_rail/nav_rail_peek.part.dart',
  'lib/src/pages/implementations/home_nav_peek.dart',
];

void main() {
  test('BUG-4751：外观设置与导航速览卡的日文文案不是英文占位', () {
    final Set<String> keys = <String>{};
    final RegExp use = RegExp(r'\bt\.([a-z][a-z0-9_]*)');
    for (final String path in _sources) {
      final String src = File(path).readAsStringSync();
      for (final RegExpMatch m in use.allMatches(src)) {
        keys.add(m.group(1)!);
      }
    }
    expect(
      keys,
      containsAll(<String>[
        'page_backdrop_title',
        'theme_pure_black',
        'nav_peek_open',
        'lookup_history_title',
      ]),
      reason: '扫描面失效',
    );

    final Map<String, dynamic> en =
        jsonDecode(File('lib/i18n/strings.i18n.json').readAsStringSync())
            as Map<String, dynamic>;
    final Map<String, dynamic> ja =
        jsonDecode(File('lib/i18n/strings_ja.i18n.json').readAsStringSync())
            as Map<String, dynamic>;
    final RegExp japanese = RegExp('[぀-ヿ㐀-鿿]');
    final RegExp englishWord = RegExp('[A-Za-z]{3}');

    final List<String> untranslated = <String>[];
    for (final String key in keys.toList()..sort()) {
      final Object? enValue = en[key];
      // 非叶子（嵌套 / 复数表）与英文里本就没有单词的值不在本守卫面。
      if (enValue is! String || !englishWord.hasMatch(enValue)) continue;
      if (_allowLatinOnly.contains(key)) continue;
      final Object? jaValue = ja[key];
      if (jaValue is! String || !japanese.hasMatch(jaValue)) {
        untranslated.add('$key = $jaValue');
      }
    }
    expect(
      untranslated,
      isEmpty,
      reason: '这些日文文案仍是英文：\n${untranslated.join('\n')}',
    );
  });
}
