// 词典管理按词典语言分组、组内独立排序（反馈 D_Nz5R4vSH）。
//
// 覆盖：分组规则、组内排序持久化（真 Drift 内存库 + DictionaryRepository）、
// 升级前后同组相对顺序不变、改语言后换组排最后，以及查词装载 / 结果集与分组
// 无关（所有者否决了「按语言过滤词典」，查词照旧查全部启用的词典）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

Dictionary _dict(
  String name,
  int order, {
  String? source,
  String? override,
  DictionaryType type = DictionaryType.term,
  Map<String, String> extra = const <String, String>{},
}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: type,
  metadata: <String, String>{
    if (source != null) 'sourceLanguage': source,
    ...extra,
  },
  languageOverride: override,
  hiddenLanguages: const <String>[],
  collapsedLanguages: const <String>[],
);

List<String> _names(Iterable<Dictionary> dictionaries) =>
    dictionaries.map((Dictionary d) => d.name).toList();

Map<String?, List<String>> _groupNames(
  List<Dictionary> section,
) => <String?, List<String>>{
  for (final DictionaryLanguageGroup g in groupDictionariesByLanguage(section))
    g.language: _names(g.dictionaries),
};

/// 与 `AppModel._rebuildDictPathsCache` 同一条分桶输入（目录一律当作存在）：
/// 查词引擎实际装载哪些词典、按什么顺序。
({List<String> term, List<String> freq, List<String> pitch, List<String> kanji})
_engineBuckets(List<Dictionary> dictionaries) =>
    bucketDictPaths(<DictPathEntry>[
      for (final Dictionary d in dictionaries)
        dictPathEntryOf(
          type: d.type,
          path: d.name,
          exists: true,
          hidden: d.isHidden(JapaneseLanguage.instance),
          metadata: d.metadata,
          order: d.order,
        ),
    ]);

FushiLookupResult _lookup(String expression, List<String> dictNames) =>
    FushiLookupResult(
      matched: expression,
      deinflected: expression,
      trace: const <FushiTransformGroup>[],
      preprocessorSteps: 0,
      term: FushiTermResult(
        expression: expression,
        reading: '',
        rules: '',
        glossaries: <FushiGlossaryEntry>[
          for (final String name in dictNames)
            FushiGlossaryEntry(
              dictName: name,
              glossary: 'gloss from $name',
              definitionTags: '',
              termTags: '',
            ),
        ],
        frequencies: const <FushiFrequencyEntry>[],
        pitches: const <FushiPitchEntry>[],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('grouping rules', () {
    test('manual override wins over the declared source language', () {
      final Dictionary d = _dict('A', 0, source: 'ja', override: 'en');
      expect(dictionaryLanguageGroupOf(d), 'en');
      expect(dictionaryLanguageGroupOf(_dict('B', 1, source: 'ja')), 'ja');
    });

    test('no language information falls into the unlabelled group, last', () {
      final List<Dictionary> section = <Dictionary>[
        _dict('none-1', 0),
        _dict('ja-1', 1, source: 'ja'),
        _dict('en-1', 2, source: 'en'),
        _dict('none-2', 3, override: '   '),
        _dict('ja-2', 4, source: 'ja'),
      ];
      final List<DictionaryLanguageGroup> groups = groupDictionariesByLanguage(
        section,
      );
      expect(
        groups.map((DictionaryLanguageGroup g) => g.language).toList(),
        <String?>['ja', 'en', null],
      );
      expect(_names(groups.last.dictionaries), <String>['none-1', 'none-2']);
    });

    test('tags are canonicalised so case variants share one group', () {
      expect(canonicalDictionaryLanguageTag('JA'), 'ja');
      expect(canonicalDictionaryLanguageTag('zh_hant'), 'zh-Hant');
      expect(canonicalDictionaryLanguageTag('en-us'), 'en-US');
      expect(canonicalDictionaryLanguageTag(''), isNull);
      expect(canonicalDictionaryLanguageTag(null), isNull);
      final Map<String?, List<String>> groups = _groupNames(<Dictionary>[
        _dict('a', 0, source: 'JA'),
        _dict('b', 1, override: 'ja'),
        _dict('c', 2, source: 'zh-hant'),
        _dict('d', 3, override: 'zh-Hant'),
      ]);
      expect(groups, <String?, List<String>>{
        'ja': <String>['a', 'b'],
        'zh-Hant': <String>['c', 'd'],
      });
    });
  });

  group('within-group reorder', () {
    final List<Dictionary> section = <Dictionary>[
      _dict('ja-1', 0, source: 'ja'),
      _dict('en-1', 1, source: 'en'),
      _dict('ja-2', 2, source: 'ja'),
      _dict('none-1', 3),
      _dict('en-2', 4, source: 'en'),
      _dict('ja-3', 5, source: 'ja'),
    ];

    test('only refills the slots the group already occupied', () {
      final List<Dictionary> ja = groupDictionariesByLanguage(section)
          .firstWhere((DictionaryLanguageGroup g) => g.language == 'ja')
          .dictionaries;
      final List<Dictionary> reordered = <Dictionary>[ja[2], ja[0], ja[1]];
      final List<Dictionary> merged = mergeLanguageGroupOrder(
        section,
        reordered,
      );
      expect(_names(merged), <String>[
        'ja-3',
        'en-1',
        'ja-1',
        'none-1',
        'en-2',
        'ja-2',
      ]);
      // 其它组的成员与位置一个都没动。
      expect(_groupNames(merged)['en'], <String>['en-1', 'en-2']);
      expect(_groupNames(merged)[null], <String>['none-1']);
    });

    test('rejects a partial or foreign group (would shift other groups)', () {
      expect(
        () => mergeLanguageGroupOrder(section, <Dictionary>[section[0]]),
        throwsArgumentError,
      );
      expect(
        () => mergeLanguageGroupOrder(section, <Dictionary>[
          section[0],
          section[2],
          section[1],
        ]),
        throwsArgumentError,
      );
    });
  });

  group('upgrade keeps relative order inside each group', () {
    // 旧版本只有一条全局顺序、英日混排。分组是这条序列的子序列，不需要任何
    // 数据迁移：升级后每组内的相对先后 == 旧全局顺序里的相对先后。
    test('groups are subsequences of the old global order', () {
      final List<Dictionary> legacy = <Dictionary>[
        _dict('OALDPE', 0, source: 'en'),
        _dict('JMdict', 1, source: 'ja'),
        _dict('wty-en-en', 2, source: 'en'),
        _dict('大辞林', 3, source: 'ja'),
        _dict('old-local', 4),
        _dict('三省堂', 5, override: 'ja'),
      ];
      final Map<String?, List<String>> groups = _groupNames(legacy);
      for (final MapEntry<String?, List<String>> entry in groups.entries) {
        final List<String> expected = <String>[
          for (final Dictionary d in legacy)
            if (dictionaryLanguageGroupOf(d) == entry.key) d.name,
        ];
        expect(entry.value, expected, reason: 'group ${entry.key}');
      }
      expect(groups['ja'], <String>['JMdict', '大辞林', '三省堂']);
      expect(groups['en'], <String>['OALDPE', 'wty-en-en']);
      // 引擎的术语桶顺序仍是旧全局顺序，逐字不变。
      expect(_engineBuckets(legacy).term, _names(legacy));
    });
  });

  group('DictionaryRepository (in-memory Drift)', () {
    late FushiDatabase db;
    late DictionaryRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = DictionaryRepository(db);
      await repo.loadFromDb();
      await repo.persistDictionaries(<Dictionary>[
        _dict('JMdict', 0, source: 'ja'),
        _dict('OALDPE', 1, source: 'en'),
        _dict('大辞林', 2, source: 'ja'),
        _dict('wty-en-en', 3, source: 'en'),
        _dict(
          'mixed-ja',
          4,
          source: 'ja',
          extra: const <String, String>{
            kDictHasKanjiKey: 'true',
            kDictKanjiOrderKey: '0',
          },
        ),
        _dict('KANJIDIC', 5, source: 'ja', type: DictionaryType.kanji),
        _dict('JPDB', 6, source: 'ja', type: DictionaryType.frequency),
        _dict('local-pack', 7),
      ]);
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('within-group order persists and survives a reload', () async {
      final List<Dictionary> section = repo.termDictionaries;
      final List<Dictionary> ja = groupDictionariesByLanguage(section)
          .firstWhere((DictionaryLanguageGroup g) => g.language == 'ja')
          .dictionaries;
      // 把 mixed-ja 拖到日语组第一位（与管理页 _reorderDictionaries 同一写法）。
      final List<Dictionary> merged = mergeLanguageGroupOrder(
        section,
        <Dictionary>[ja[2], ja[0], ja[1]],
      );
      await repo.updateDictionaryOrder(<Dictionary>[
        for (int i = 0; i < merged.length; i++) merged[i].copyWith(order: i),
      ]);
      await repo.loadFromDb();
      final Map<String?, List<String>> groups = _groupNames(
        repo.termDictionaries,
      );
      expect(groups['ja'], <String>['mixed-ja', 'JMdict', '大辞林']);
      expect(groups['en'], <String>['OALDPE', 'wty-en-en']);
      expect(groups[null], <String>['local-pack']);
    });

    test(
      'changing the language moves it to the end of the new group',
      () async {
        await repo.setDictionaryLanguageOverride(
          repo.dictionaries.firstWhere((Dictionary d) => d.name == 'JMdict'),
          'en',
        );
        await repo.loadFromDb();
        Map<String?, List<String>> groups = _groupNames(repo.termDictionaries);
        expect(groups['en'], <String>['OALDPE', 'wty-en-en', 'JMdict']);
        expect(groups['ja'], <String>['大辞林', 'mixed-ja']);

        // 混合词典改语言：「汉字」分区里也排到新组最后。
        await repo.setDictionaryLanguageOverride(
          repo.dictionaries.firstWhere((Dictionary d) => d.name == 'mixed-ja'),
          'zh-Hant',
        );
        await repo.setDictionaryLanguageOverride(
          repo.dictionaries.firstWhere((Dictionary d) => d.name == 'KANJIDIC'),
          'zh-Hant',
        );
        await repo.loadFromDb();
        expect(_groupNames(repo.kanjiSectionDictionaries)['zh-Hant'], <String>[
          'mixed-ja',
          'KANJIDIC',
        ]);
        groups = _groupNames(repo.termDictionaries);
        expect(groups['zh-Hant'], <String>['mixed-ja']);

        // 恢复「自动」= 回到包内声明的 ja 组，同样排最后。
        await repo.setDictionaryLanguageOverride(
          repo.dictionaries.firstWhere((Dictionary d) => d.name == 'JMdict'),
          null,
        );
        await repo.loadFromDb();
        expect(_groupNames(repo.termDictionaries)['ja'], <String>[
          '大辞林',
          'JMdict',
        ]);
      },
    );

    test('an override that keeps the same group does not move it', () async {
      final List<String> before = _names(repo.termDictionaries);
      await repo.setDictionaryLanguageOverride(
        repo.dictionaries.firstWhere((Dictionary d) => d.name == 'JMdict'),
        'JA',
      );
      await repo.loadFromDb();
      expect(_names(repo.termDictionaries), before);
      expect(
        repo.dictionaries
            .firstWhere((Dictionary d) => d.name == 'JMdict')
            .languageOverride,
        'JA',
      );
    });

    test(
      'lookup loads and returns the same dictionary set: no language filter',
      () async {
        Set<String> loaded() {
          final ({
            List<String> term,
            List<String> freq,
            List<String> pitch,
            List<String> kanji,
          })
          b = _engineBuckets(repo.dictionaries);
          return <String>{...b.term, ...b.freq, ...b.pitch, ...b.kanji};
        }

        Set<String> resultDictionaries() {
          final DictionaryLookupFilters filters = repo.lookupFilters;
          final DictionarySearchResult result = buildResultFromLookup(
            searchTerm: 'test',
            results: <FushiLookupResult>[
              _lookup('test', <String>[
                'JMdict',
                'OALDPE',
                '大辞林',
                'wty-en-en',
                'mixed-ja',
                'local-pack',
              ]),
            ],
            maximumTerms: 20,
            dictionaryOrder: filters.termDictionaryOrder,
            hiddenDictionaries: filters.hiddenDictionaryNames,
          );
          return <String>{
            for (final DictionaryEntry e in result.entries) e.dictionaryName,
          };
        }

        final Set<String> loadedBefore = loaded();
        final Set<String> resultsBefore = resultDictionaries();
        final Set<String> termOrderBefore = repo
            .lookupFilters
            .termDictionaryOrder
            .toSet();
        expect(loadedBefore, hasLength(8));
        expect(resultsBefore, hasLength(6));

        // 改语言、组内重排之后：装载集合、结果集合、查词顺序成员都不变。
        await repo.setDictionaryLanguageOverride(
          repo.dictionaries.firstWhere((Dictionary d) => d.name == '大辞林'),
          'en',
        );
        await repo.setDictionaryLanguageOverride(
          repo.dictionaries.firstWhere(
            (Dictionary d) => d.name == 'local-pack',
          ),
          'ko',
        );
        final List<Dictionary> section = repo.termDictionaries;
        final List<Dictionary> en = groupDictionariesByLanguage(section)
            .firstWhere((DictionaryLanguageGroup g) => g.language == 'en')
            .dictionaries;
        final List<Dictionary> merged = mergeLanguageGroupOrder(
          section,
          en.reversed.toList(),
        );
        await repo.updateDictionaryOrder(<Dictionary>[
          for (int i = 0; i < merged.length; i++) merged[i].copyWith(order: i),
        ]);
        await repo.loadFromDb();

        expect(loaded(), loadedBefore);
        expect(resultDictionaries(), resultsBefore);
        expect(repo.lookupFilters.termDictionaryOrder.toSet(), termOrderBefore);
        expect(repo.lookupFilters.hiddenDictionaryNames, isEmpty);
      },
    );
  });
}
