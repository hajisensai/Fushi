// en.json 短语动词数据守卫（BUG-2549）。
//
// Yomitan english-transforms.js 的短语动词规则是正则型 `other` 规则，JSON 表达不了，
// 所以拆成两半：词表（phrasalVerbParticles / phrasalVerbPrepositions）作为 en.json
// 顶层 `phrasalVerbs` 块进数据，匹配逻辑进引擎 `Deinflector::deinflect_phrasal`；
// 哪些变形组作用于动词头由组上的 `phrasalVerb: true` 标记决定（Yomitan 只给
// past / ing / 3sg 三组生成，本仓 en_irregular.json 的动词组也打标记，"gave up" 才
// 还原得到 "give up"）。引擎对缺失/写错的字段是静默不生效的（glaze 忽略未知键、
// 未声明的 condition 解析成 0 位），所以数据形状必须在这里钉死。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _kTransformsDir = 'assets/transforms';

Map<String, dynamic> _readJson(String name) {
  final File file = File('$_kTransformsDir/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final Map<String, dynamic> en = _readJson('en.json');
  final Map<String, dynamic> irregular = _readJson('en_irregular.json');
  final Map<String, dynamic> enConditions =
      en['conditions'] as Map<String, dynamic>;
  final Map<String, dynamic> enTransforms =
      en['transforms'] as Map<String, dynamic>;

  test('en.json declares the phrasal verb word lists and output condition', () {
    final Map<String, dynamic> phrasal =
        en['phrasalVerbs'] as Map<String, dynamic>;
    final String condition = phrasal['condition'] as String;
    expect(enConditions, contains(condition));
    // 输出条件必须是 v 的子条件，否则 rules "v" 的词条会被 filter_by_pos 挡掉。
    final Map<String, dynamic> verb = enConditions['v'] as Map<String, dynamic>;
    expect(verb['subConditions'], contains(condition));

    final RegExp lowerAscii = RegExp(r'^[a-z]+$');
    for (final String key in <String>['particles', 'prepositions']) {
      final List<String> words = (phrasal[key] as List<dynamic>).cast<String>();
      expect(words, isNotEmpty, reason: key);
      expect(words.toSet().length, words.length, reason: '$key has duplicates');
      for (final String word in words) {
        expect(word, matches(lowerAscii), reason: '$key: $word');
      }
    }
    // Yomitan 两张表的锚点：up 是小品词（宾语插入规则只认小品词），to 只是介词。
    expect(phrasal['particles'], contains('up'));
    expect(phrasal['prepositions'], contains('to'));
    expect(phrasal['particles'], isNot(contains('to')));
  });

  test('phrasal-flagged transform groups only carry verb-to-verb rules', () {
    final Set<String> flagged = <String>{};
    for (final Map<String, dynamic> file in <Map<String, dynamic>>[
      en,
      irregular,
    ]) {
      final Map<String, dynamic> transforms =
          file['transforms'] as Map<String, dynamic>;
      for (final MapEntry<String, dynamic> group in transforms.entries) {
        final Map<String, dynamic> t = group.value as Map<String, dynamic>;
        if (t['phrasalVerb'] != true) continue;
        flagged.add(group.key);
        for (final dynamic raw in t['rules'] as List<dynamic>) {
          final Map<String, dynamic> rule = raw as Map<String, dynamic>;
          expect(
            <String>['suffix', 'wholeWord'],
            contains(rule['type']),
            reason:
                '${group.key}: only suffix/wholeWord rules apply to a verb head',
          );
          expect(rule['conditionsIn'], <String>['v'], reason: group.key);
          expect(rule['conditionsOut'], <String>['v'], reason: group.key);
        }
      }
    }
    // Yomitan 的三组 + 本仓不规则表的动词组。
    expect(
      flagged,
      containsAll(<String>[
        'past',
        'ing',
        '3rd pers. sing. pres',
        'irregular past',
        'irregular past participle',
        'irregular past/participle',
        'irregular present',
      ]),
    );
  });

  test(
    'interposed object rule exists once and outputs the phrasal condition',
    () {
      final Map<String, dynamic> group =
          enTransforms['interposed object'] as Map<String, dynamic>;
      expect(group['name'], 'interposed object');
      expect((group['description'] as String).trim(), isNotEmpty);
      final List<dynamic> rules = group['rules'] as List<dynamic>;
      expect(rules, hasLength(1));
      final Map<String, dynamic> rule = rules.single as Map<String, dynamic>;
      expect(rule['type'], 'phrasalVerbInterposedObject');
      expect(rule['conditionsIn'], isEmpty);
      expect(rule['conditionsOut'], <String>[
        (en['phrasalVerbs'] as Map<String, dynamic>)['condition'],
      ]);
    },
  );
}
