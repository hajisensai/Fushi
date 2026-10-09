import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2966 守卫：首页（dashboard + 展示件 + 更新横幅）用到的每个 i18n key，
/// 在每种非英文语言里都必须有真译文，不能是英文原值占位。
///
/// 根因：`i18n_sync --add` 给 zh 以外的语言先填英文值，后续没人补译——日文 UI
/// 首页就挂着「Daily Goal / Set Goal / Nothing to continue yet」三块英文。
/// Slang 只校验 key 齐全，不校验值是否翻译，所以只能在这里按「用到的 key ×
/// 语言」逐格查。
///
/// 允许与英文同值的只有真正跨语言同形的词（品牌名、纯数字占位）。新增首页文案
/// 时，若某语言确实与英文同形，把 (语言, key) 加进 [_allowSameAsEnglish] 并注明。
const Map<String, Set<String>> _allowSameAsEnglish = <String, Set<String>>{
  // 德语 / 荷兰语直接借用的英文词，译文本就同形。
  'de': <String>{
    'updates_center_title',
    'leaderboard_title',
    'home_remote_source',
  },
  'nl': <String>{'updates_center_title'},
  'pt-BR': <String>{'leaderboard_title'},
  // 法语「$n sessions」与英文同形。
  'fr': <String>{'home_session_count'},
};

const List<String> _sources = <String>[
  'lib/src/pages/implementations/home_dashboard_page.dart',
  'lib/src/pages/implementations/home_dashboard_widgets.dart',
  'lib/src/pages/implementations/updates_dashboard_banner.dart',
];

void main() {
  test('BUG-2966：首页可见文案在全部语言都有译文（不是英文占位）', () {
    final Set<String> keys = <String>{};
    final RegExp use = RegExp(r'\bt\.([a-z][a-z0-9_]*)');
    for (final String path in _sources) {
      final String src = File(path).readAsStringSync();
      for (final RegExpMatch m in use.allMatches(src)) {
        keys.add(m.group(1)!);
      }
    }
    expect(keys, contains('stat_goal_set'), reason: '扫描面失效');

    final Map<String, dynamic> en =
        jsonDecode(File('lib/i18n/strings.i18n.json').readAsStringSync())
            as Map<String, dynamic>;
    final List<File> locales = Directory('lib/i18n')
        .listSync()
        .whereType<File>()
        .where(
          (File f) => RegExp(
            r'strings_[A-Za-z-]+\.i18n\.json$',
          ).hasMatch(f.path.replaceAll(r'\', '/')),
        )
        .toList();
    expect(locales.length, greaterThanOrEqualTo(16));

    final List<String> untranslated = <String>[];
    for (final File f in locales) {
      final String locale = RegExp(
        r'strings_([A-Za-z-]+)\.i18n\.json$',
      ).firstMatch(f.path.replaceAll(r'\', '/'))!.group(1)!;
      final Map<String, dynamic> values =
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      for (final String key in keys) {
        final Object? enValue = en[key];
        // 非叶子（嵌套 / 复数表）与英文里本就没有字母的值不在本守卫面。
        if (enValue is! String || !RegExp('[A-Za-z]{3}').hasMatch(enValue)) {
          continue;
        }
        if (_allowSameAsEnglish[locale]?.contains(key) ?? false) continue;
        if (values[key] == enValue) untranslated.add('$locale:$key');
      }
    }
    expect(
      untranslated,
      isEmpty,
      reason: '这些首页文案仍是英文占位：${untranslated.join(', ')}',
    );
  });
}
