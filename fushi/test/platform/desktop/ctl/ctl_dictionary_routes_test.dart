import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_dictionary_json.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_dictionary_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 路由表构建期不碰 ref；真正调用 handler 才读 app。
class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('路由构建期不应读 ref');
}

Dictionary _dict(
  String name, {
  int order = 0,
  DictionaryType type = DictionaryType.term,
  String? displayName,
  List<String> hidden = const <String>[],
  Map<String, String> metadata = const <String, String>{},
}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: type,
  displayName: displayName,
  hiddenLanguages: hidden,
  metadata: metadata,
);

void main() {
  group('路由表', () {
    final List<CtlRoute> routes = buildDictionaryCtlRoutes(
      DesktopCtlContext(ref: _UnusedRef(), focusMainWindow: () async {}),
    );

    test('路径都在 /api/admin/ 下，method+path 不重复', () {
      expect(routes, isNotEmpty);
      final Set<String> seen = <String>{};
      for (final CtlRoute route in routes) {
        expect(route.pattern, startsWith('/api/admin/'));
        expect(
          seen.add('${route.method} ${route.pattern}'),
          isTrue,
          reason: '${route.method} ${route.pattern} 重复',
        );
      }
    });

    test('固定子路径不会被 :name 路由抢走', () {
      CtlRoute? first(String method, String path) {
        for (final CtlRoute r in routes) {
          if (r.method == method && r.match(path) != null) return r;
        }
        return null;
      }

      expect(
        first('GET', '/api/admin/dictionaries/search')!.pattern,
        '/api/admin/dictionaries/search',
      );
      expect(
        first('POST', '/api/admin/dictionaries/import')!.pattern,
        '/api/admin/dictionaries/import',
      );
      expect(
        first(
          'PUT',
          '/api/admin/dictionaries/JMdict%20%5B1%5D',
        )!.match('/api/admin/dictionaries/JMdict%20%5B1%5D'),
        <String, String>{'name': 'JMdict [1]'},
      );
    });
  });

  group('resolveCtlDictionary', () {
    final List<Dictionary> dicts = <Dictionary>[
      _dict('JMdict [2024-01-01]', displayName: 'JMdict'),
      _dict('大辞林'),
      _dict('Alpha'),
      _dict('alpha'),
    ];

    test('真名 > 显示名 > 忽略大小写', () {
      expect(resolveCtlDictionary(dicts, '大辞林').name, '大辞林');
      expect(resolveCtlDictionary(dicts, 'JMdict').name, 'JMdict [2024-01-01]');
      expect(resolveCtlDictionary(dicts, 'jmdict').name, 'JMdict [2024-01-01]');
      expect(resolveCtlDictionary(dicts, 'Alpha').name, 'Alpha');
    });

    test('歧义报 400，找不到报 404', () {
      expect(
        () => resolveCtlDictionary(dicts, 'ALPHA'),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
      expect(
        () => resolveCtlDictionary(dicts, 'nope'),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
        ),
      );
    });
  });

  test('ctlReorderDictionaries 与管理页同语义：移动后整组改 order，越界钳位', () {
    final Dictionary a = _dict('a', order: 0);
    final Dictionary b = _dict('b', order: 1);
    final Dictionary c = _dict('c', order: 2);
    final List<Dictionary> moved = ctlReorderDictionaries(
      <Dictionary>[a, b, c],
      c,
      1,
    );
    expect(moved.map((Dictionary d) => d.name), <String>['c', 'a', 'b']);
    expect(moved.map((Dictionary d) => d.order), <int>[0, 1, 2]);
    final List<Dictionary> last = ctlReorderDictionaries(moved, c, 99);
    expect(last.map((Dictionary d) => d.name), <String>['a', 'b', 'c']);
  });

  test('ctlDictionaryJson / ctlSortedDictionaries', () {
    final Dictionary hidden = _dict(
      'freq',
      type: DictionaryType.frequency,
      hidden: <String>[JapaneseLanguage.instance.languageCode],
    );
    final Dictionary term = _dict('term', order: 1);
    final Dictionary term0 = _dict('term0');
    expect(
      ctlSortedDictionaries(<Dictionary>[
        hidden,
        term,
        term0,
      ]).map((Dictionary d) => d.name),
      <String>['term0', 'term', 'freq'],
    );
    final Map<String, Object?> json = ctlDictionaryJson(hidden);
    expect(json['enabled'], isFalse);
    expect(json['type'], 'frequency');
    expect(ctlDictionaryJson(term)['enabled'], isTrue);
  });

  test('ctlSearchResultJson 投影词条并可截断释义', () {
    final DictionarySearchResult result = DictionarySearchResult(
      searchTerm: '食べる',
      bestLength: 3,
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'JMdict',
          word: '食べる',
          reading: 'たべる',
          meaning: 'to eat; to live on',
        ),
      ],
    );
    final Map<String, Object?> json = ctlSearchResultJson(
      '食べる',
      result,
      maxMeaningChars: 6,
    );
    expect(json['bestLength'], 3);
    final Map<String, Object?> entry =
        (json['entries'] as List<Object?>).single as Map<String, Object?>;
    expect(entry['word'], '食べる');
    expect(entry['reading'], 'たべる');
    expect(entry['dictionary'], 'JMdict');
    expect(entry['meaning'], 'to eat…');
    expect(ctlSearchResultJson('x', null)['entries'], isEmpty);
  });

  group('buildCtlMineFields', () {
    final DictionarySearchResult lookup = DictionarySearchResult(
      searchTerm: '生',
      entries: <DictionaryEntry>[
        DictionaryEntry(
          dictionaryName: 'JMdict',
          word: '生',
          reading: 'なま',
          meaning: 'raw <b>',
        ),
        DictionaryEntry(
          dictionaryName: 'JMdict',
          word: '生',
          reading: 'せい',
          meaning: 'life',
        ),
        DictionaryEntry(
          dictionaryName: 'Other',
          word: '生き',
          reading: 'いき',
          meaning: 'living',
        ),
      ],
    );

    test('缺读音 / 释义时取同词头的第一条读音，并按读音过滤释义', () {
      final Map<String, String> fields = buildCtlMineFields(
        word: '生',
        sentence: '生で食べる',
        lookup: lookup,
      );
      expect(fields['expression'], '生');
      expect(fields['reading'], 'なま');
      expect(fields['sentence'], '生で食べる');
      expect(fields['glossary'], '【JMdict】<br>raw &lt;b&gt;');
      expect(fields.containsKey(AnkiMiningPayload.allowDuplicateKey), isFalse);
    });

    test('显式值优先，额外字段与 allowDuplicate 透传', () {
      final Map<String, String> fields = buildCtlMineFields(
        word: '生',
        reading: 'せい',
        glossary: 'custom',
        extra: const <String, String>{'notes': 'n'},
        lookup: lookup,
        allowDuplicate: true,
      );
      expect(fields['reading'], 'せい');
      expect(fields['glossary'], 'custom');
      expect(fields['notes'], 'n');
      expect(fields[AnkiMiningPayload.allowDuplicateKey], 'true');
    });

    test('没查词结果时字段留空，不臆造', () {
      final Map<String, String> fields = buildCtlMineFields(word: '猫');
      expect(fields['reading'], '');
      expect(fields['glossary'], '');
    });
  });
}
