// en_irregular.json 结构守卫：英语不规则形规则表与 en.json 共用同一套条件位。
//
// Deinflector::load_transforms_json 的条件位是**每次调用从 bit 0 重新分配**、按
// `lang:cond` 去重的（deinflector.cpp）。两份文件只要条件块逐字相同，无论谁先加载
// 位图都一致；en_irregular.json 一旦引入新条件名，就会和 en.json 的既有条件撞位，
// 规则表悄悄失效而不报错。桌面/iOS 经 manifest.json 装载，Android 直接扫目录——
// 清单漏项只会让桌面端静默不生效，所以清单也一并钉住。
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

  test('manifest lists en_irregular right after en', () {
    final List<dynamic> manifest =
        jsonDecode(File('$_kTransformsDir/manifest.json').readAsStringSync())
            as List<dynamic>;
    final int enIndex = manifest.indexOf('en');
    expect(enIndex, isNonNegative);
    expect(manifest[enIndex + 1], 'en_irregular');
  });

  test('language and conditions are byte-identical copies of en.json', () {
    expect(irregular['language'], 'en');
    expect(jsonEncode(irregular['conditions']), jsonEncode(en['conditions']));
  });

  test(
    'every rule is lowercase ASCII, non-identity, unique and well-typed',
    () {
      final Set<String> knownConditions =
          (en['conditions'] as Map<String, dynamic>).keys.toSet();
      final Set<String> seen = <String>{};
      final Map<String, dynamic> transforms =
          irregular['transforms'] as Map<String, dynamic>;
      expect(transforms, isNotEmpty);
      final RegExp lowerAscii = RegExp(r"^[a-z']+$");
      for (final MapEntry<String, dynamic> group in transforms.entries) {
        final Map<String, dynamic> t = group.value as Map<String, dynamic>;
        expect(t['name'], group.key, reason: 'name must equal the map key');
        expect(
          (t['description'] as String).trim(),
          isNotEmpty,
          reason: '${group.key}: description feeds the zh-CN i18n guard',
        );
        for (final dynamic raw in t['rules'] as List<dynamic>) {
          final Map<String, dynamic> rule = raw as Map<String, dynamic>;
          final String type = rule['type'] as String;
          late final String from;
          late final String to;
          switch (type) {
            case 'wholeWord':
              from = rule['from'] as String;
              to = rule['to'] as String;
            case 'suffix':
              from = rule['fromSuffix'] as String;
              to = rule['toSuffix'] as String;
            default:
              fail('${group.key}: unexpected rule type $type');
          }
          expect(from, matches(lowerAscii), reason: '${group.key}: $from');
          expect(
            to,
            matches(RegExp(r"^[a-z']*$")),
            reason: '${group.key}: $to',
          );
          expect(from, isNot(to), reason: '${group.key}: identity rule $from');
          expect(
            // better -> well 同时是形容词与副词的比较级：同形对不同词性是两条规则。
            seen.add('$type|$from|$to|${rule['conditionsOut']}'),
            isTrue,
            reason: '${group.key}: duplicate rule $from -> $to',
          );
          for (final String key in <String>['conditionsIn', 'conditionsOut']) {
            final List<dynamic> conditions = rule[key] as List<dynamic>;
            expect(conditions, isNotEmpty, reason: '${group.key}: $from $key');
            for (final dynamic c in conditions) {
              expect(
                knownConditions,
                contains(c),
                reason:
                    '${group.key}: $from uses unknown condition $c — a '
                    'new condition name would collide with en.json bits',
              );
            }
          }
        }
      }
    },
  );

  test('the forms users reported are covered', () {
    final Map<String, String> wholeWord = <String, String>{};
    for (final dynamic t
        in (irregular['transforms'] as Map<String, dynamic>).values) {
      for (final dynamic raw in (t as Map<String, dynamic>)['rules'] as List) {
        final Map<String, dynamic> rule = raw as Map<String, dynamic>;
        if (rule['type'] == 'wholeWord') {
          wholeWord.putIfAbsent(
            rule['from'] as String,
            () => rule['to'] as String,
          );
        }
      }
    }
    expect(wholeWord['went'], 'go');
    expect(wholeWord['was'], 'be');
    expect(wholeWord['took'], 'take');
    expect(wholeWord['taken'], 'take');
    expect(wholeWord['better'], 'good');
    expect(wholeWord['people'], 'person');
  });
}
