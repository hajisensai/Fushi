// BUG-2038：查词弹窗上的词形变化语法说明只有英文，不跟界面语言走。
//
// 说明原文来自 assets/transforms/<lang>.json 的 description（上游 Yomitan 文案），
// 译文表是 assets/transforms/i18n/<localeTag>.json，键 = 英文原文**逐字**。
// 这里钉三件事：
//  1. 查表/回落语义（含幂等，显示路径上多处各调一次必须安全）；
//  2. 显示路径真的翻译了、持久化路径**没有**翻译（换界面语言不会留下旧语言残渣）；
//  3. 译文资产与 transforms 资产不漂移：键都还存在、且英文原文全被覆盖。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

const String _kTransformsDir = 'assets/transforms';

/// transforms 资产里出现过的全部英文说明原文。
Set<String> _allDescriptions() {
  final Set<String> out = <String>{};
  for (final FileSystemEntity e in Directory(_kTransformsDir).listSync()) {
    if (e is! File || !e.path.endsWith('.json')) continue;
    if (e.uri.pathSegments.last == 'manifest.json') continue;
    final Object? decoded = jsonDecode(e.readAsStringSync());
    if (decoded is! Map) continue;
    final Object? transforms = decoded['transforms'];
    if (transforms is! Map) continue;
    for (final Object? t in transforms.values) {
      if (t is! Map) continue;
      final Object? d = t['description'];
      if (d is String && d.isNotEmpty) out.add(d);
    }
  }
  return out;
}

Map<String, String> _loadTable(String tag) {
  final File f = File('$_kTransformsDir/i18n/$tag.json');
  expect(f.existsSync(), isTrue, reason: '找不到译文资产 ${f.path}');
  final Object? decoded = jsonDecode(f.readAsStringSync());
  expect(decoded, isA<Map>());
  return <String, String>{
    for (final MapEntry<Object?, Object?> e in (decoded as Map).entries)
      e.key as String: e.value as String,
  };
}

void main() {
  tearDown(TransformDescriptionCatalog.clear);

  group('TransformDescriptionCatalog', () {
    test('未装载译文时原样返回英文', () {
      TransformDescriptionCatalog.clear();
      expect(
        TransformDescriptionCatalog.localize('Plural form of a noun'),
        'Plural form of a noun',
      );
      expect(TransformDescriptionCatalog.localeTag, isNull);
    });

    test('查得到就换成译文，查不到原样回落', () {
      TransformDescriptionCatalog.apply(
        localeTag: 'zh-CN',
        translations: const <String, String>{
          'Plural form of a noun': '名词的复数形式',
        },
      );
      expect(TransformDescriptionCatalog.localeTag, 'zh-CN');
      expect(
        TransformDescriptionCatalog.localize('Plural form of a noun'),
        '名词的复数形式',
      );
      // 上游改了英文原文 → 查不到 → 回落英文，而不是给出过期的错译。
      expect(
        TransformDescriptionCatalog.localize('Plural form of a NOUN'),
        'Plural form of a NOUN',
      );
      expect(TransformDescriptionCatalog.localize(''), '');
    });

    test('幂等：对译文再翻一次不会二次替换', () {
      TransformDescriptionCatalog.apply(
        localeTag: 'zh-CN',
        translations: const <String, String>{
          'Plural form of a noun': '名词的复数形式',
        },
      );
      final String once = TransformDescriptionCatalog.localize(
        'Plural form of a noun',
      );
      expect(TransformDescriptionCatalog.localize(once), once);
    });

    test('换语言整表替换，不保留上一种语言的残渣', () {
      TransformDescriptionCatalog.apply(
        localeTag: 'zh-CN',
        translations: const <String, String>{'a': '甲', 'b': '乙'},
      );
      TransformDescriptionCatalog.apply(
        localeTag: 'de',
        translations: const <String, String>{'a': 'Eins'},
      );
      expect(TransformDescriptionCatalog.localize('a'), 'Eins');
      expect(
        TransformDescriptionCatalog.localize('b'),
        'b',
        reason: '换语言后不该还留着中文译文',
      );
    });
  });

  group('显示路径翻译 / 持久化路径不翻（BUG-2038）', () {
    const String english =
        'Describes the intention to make someone do '
        'something.';

    setUp(() {
      TransformDescriptionCatalog.apply(
        localeTag: 'zh-CN',
        translations: const <String, String>{english: '表示让某人做某事的意图。'},
      );
    });

    test('localizeDeinflectionTags 只改说明、不动变形名', () {
      final List<DeinflectionTag> out = localizeDeinflectionTags(
        <DeinflectionTag>[(name: 'causative', description: english)],
      );
      expect(out.single.name, 'causative', reason: '变形名是语言学标签，不翻译');
      expect(out.single.description, '表示让某人做某事的意图。');
    });

    test('buildDeinflectionTags 本身保持英文（它同时喂着持久化路径）', () {
      final List<DeinflectionTag> tags = buildDeinflectionTags(
        matched: 'colour',
        deinflected: 'color',
        trace: const <FushiTransformGroup>[],
      );
      // 回落分支没有说明；关键是这个函数不做本地化——真正的钉子在下一条。
      expect(tags.single.description, isEmpty);
    });

    test('deinflectionTagsFromExtra 读出来是译文（extra 里存英文）', () {
      final Map<String, dynamic> extra = <String, dynamic>{
        'deinflectionTrace': <Map<String, String>>[
          <String, String>{'name': 'causative', 'description': english},
        ],
      };
      final List<DeinflectionTag> tags = deinflectionTagsFromExtra(extra);
      expect(
        tags.single.description,
        '表示让某人做某事的意图。',
        reason: '原生弹窗 / buildLookupEntriesJson 都走这条读出路径',
      );
      expect(
        (extra['deinflectionTrace'] as List).first['description'],
        english,
        reason:
            'extra 是持久化载体，必须原样保留英文；否则换界面语言后旧缓存里'
            '腌着上一种语言的译文',
      );
    });
  });

  group('译文资产与 transforms 资产不漂移', () {
    test('zh-CN.json 的每个键都还是现存的英文原文', () {
      final Set<String> descriptions = _allDescriptions();
      expect(descriptions, isNotEmpty, reason: '没读到任何 transforms 说明，判据失效');
      final Map<String, String> table = _loadTable('zh-CN');
      final List<String> stale = table.keys
          .where((String k) => !descriptions.contains(k))
          .toList();
      expect(
        stale,
        isEmpty,
        reason:
            '这些键在 assets/transforms/*.json 里已经不存在了（上游改了原文？）。'
            '译文查不到就会静默回落英文，请重新对齐：\n'
            '${stale.map((String s) => s.split('\n').first).join('\n')}',
      );
    });

    test('每条英文说明都有中文译文', () {
      final Set<String> descriptions = _allDescriptions();
      final Map<String, String> table = _loadTable('zh-CN');
      final List<String> missing = descriptions
          .where((String d) => !table.containsKey(d))
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            '这些说明还没有中文译文（弹窗上会显示英文）：\n'
            '${missing.map((String s) => s.split('\n').first).join('\n')}',
      );
    });

    test('译文非空，且不是照抄英文', () {
      final Map<String, String> table = _loadTable('zh-CN');
      final List<String> bad = <String>[
        for (final MapEntry<String, String> e in table.entries)
          if (e.value.trim().isEmpty || e.value == e.key) e.key,
      ];
      expect(
        bad,
        isEmpty,
        reason:
            '空译文或与英文逐字相同 = 没翻：\n'
            '${bad.map((String s) => s.split('\n').first).join('\n')}',
      );
    });
  });
}
