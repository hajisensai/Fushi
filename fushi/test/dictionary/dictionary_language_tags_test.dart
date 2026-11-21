// 词典内容语言只是标签：管理页行上的语言 tag 与语言筛选，不参与排序（拍板台
// zBzX4B7037，取代反馈 D_Nz5R4vSH 的「按语言分组、组内排序」——那会让自带语言
// 声明的新词典和没声明语言的老词典分在两组、彼此排不了先后）。
//
// 覆盖：标签规则、筛选项顺序、整个分区内任意移动（真 Drift 内存库 +
// DictionaryRepository 持久化）、改语言不动任何序号，以及查词装载 / 结果集与
// 语言无关（所有者否决了「按语言过滤词典」，查词照旧查全部启用的词典）。

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

  group('language tag rules', () {
    test('manual override wins over the declared source language', () {
      final Dictionary d = _dict('A', 0, source: 'ja', override: 'en');
      expect(dictionaryLanguageTagOf(d), 'en');
      expect(dictionaryLanguageTagOf(_dict('B', 1, source: 'ja')), 'ja');
      expect(dictionaryLanguageTagOf(_dict('C', 2)), isNull);
      expect(dictionaryLanguageTagOf(_dict('D', 3, override: '   ')), isNull);
    });

    test('tags are canonicalised so case variants are one language', () {
      expect(canonicalDictionaryLanguageTag('JA'), 'ja');
      expect(canonicalDictionaryLanguageTag('zh_hant'), 'zh-Hant');
      expect(canonicalDictionaryLanguageTag('en-us'), 'en-US');
      expect(canonicalDictionaryLanguageTag(''), isNull);
      expect(canonicalDictionaryLanguageTag(null), isNull);
    });

    test('filter options: first appearance order, unlabelled last', () {
      final List<Dictionary> section = <Dictionary>[
        _dict('none-1', 0),
        _dict('ja-1', 1, source: 'JA'),
        _dict('en-1', 2, source: 'en'),
        _dict('ja-2', 3, override: 'ja'),
        _dict('zh-1', 4, source: 'zh-hant'),
      ];
      expect(
        dictionaryLanguageTagsIn<Dictionary>(section, dictionaryLanguageTagOf),
        <String?>['ja', 'en', 'zh-Hant', null],
      );
      expect(
        dictionaryLanguageTagsIn<Dictionary>(<Dictionary>[
          _dict('a', 0, source: 'ja'),
        ], dictionaryLanguageTagOf),
        <String?>['ja'],
      );
    });
  });

  group('moving inside a section ignores languages', () {
    final List<Dictionary> section = <Dictionary>[
      _dict('ja-new', 0, source: 'ja'),
      _dict('old-1', 1),
      _dict('old-2', 2),
      _dict('en-1', 3, source: 'en'),
    ];
    List<String>? move(String name, int to) =>
        switch (moveDictionarySectionRow<Dictionary>(
          section,
          (Dictionary d) => d.name,
          name,
          to,
        )) {
          final List<Dictionary> next => _names(next),
          null => null,
        };

    test('a labelled dictionary moves past unlabelled ones (feedback)', () {
      // 反馈：自带 ja 声明的新词典和没声明语言的老词典以前在两组，无法互相排序。
      expect(move('ja-new', 2), <String>['old-1', 'old-2', 'ja-new', 'en-1']);
      expect(move('old-2', 0), <String>['old-2', 'ja-new', 'old-1', 'en-1']);
      expect(move('en-1', 1), <String>['ja-new', 'en-1', 'old-1', 'old-2']);
    });

    test('out of range clamps; no-op and missing return null', () {
      expect(move('ja-new', 99), <String>['old-1', 'old-2', 'en-1', 'ja-new']);
      expect(move('en-1', -5), <String>['en-1', 'ja-new', 'old-1', 'old-2']);
      expect(move('old-1', 1), isNull);
      expect(move('gone', 0), isNull);
      // 输入列表不被改动。
      expect(_names(section), <String>['ja-new', 'old-1', 'old-2', 'en-1']);
    });
  });

  group('DictionaryRepository (in-memory Drift)', () {
    late FushiDatabase db;
    late DictionaryRepository repo;

    Dictionary named(String name) =>
        repo.dictionaries.firstWhere((Dictionary d) => d.name == name);

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

    test('an unlabelled dictionary can be moved ahead of labelled ones and '
        'the order persists as the lookup order', () async {
      final List<Dictionary> moved = moveDictionarySectionRow<Dictionary>(
        repo.termDictionaries,
        (Dictionary d) => d.name,
        'local-pack',
        0,
      )!;
      await repo.updateDictionaryOrder(<Dictionary>[
        for (int i = 0; i < moved.length; i++) moved[i].copyWith(order: i),
      ]);
      await repo.loadFromDb();
      const List<String> expected = <String>[
        'local-pack',
        'JMdict',
        'OALDPE',
        '大辞林',
        'wty-en-en',
        'mixed-ja',
      ];
      expect(_names(repo.termDictionaries), expected);
      expect(repo.lookupFilters.termDictionaryOrder, expected);
      expect(
        _engineBuckets(repo.dictionaries).term,
        expected,
        reason: '引擎术语桶的装载顺序与管理页一致',
      );
    });

    test('changing the language never moves a dictionary', () async {
      final List<String> termBefore = _names(repo.termDictionaries);
      final List<String> kanjiBefore = _names(repo.kanjiSectionDictionaries);
      await repo.setDictionaryLanguageOverride(named('JMdict'), 'en');
      await repo.setDictionaryLanguageOverride(named('local-pack'), 'ko');
      // 混合词典改语言：「汉字」分区的位置也不动。
      await repo.setDictionaryLanguageOverride(named('mixed-ja'), 'zh-Hant');
      await repo.loadFromDb();
      expect(_names(repo.termDictionaries), termBefore);
      expect(_names(repo.kanjiSectionDictionaries), kanjiBefore);
      expect(named('JMdict').languageOverride, 'en');
      expect(dictionaryLanguageTagOf(named('mixed-ja')), 'zh-Hant');
      expect(repo.freqDictionaries.single.order, 6);

      // 恢复「自动」= 回到包内声明的 ja，位置同样不动。
      await repo.setDictionaryLanguageOverride(named('JMdict'), null);
      await repo.loadFromDb();
      expect(named('JMdict').languageOverride, isNull);
      expect(_names(repo.termDictionaries), termBefore);
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
        final List<String> termOrderBefore =
            repo.lookupFilters.termDictionaryOrder;
        expect(loadedBefore, hasLength(8));
        expect(resultsBefore, hasLength(6));

        // 改语言之后：装载集合、结果集合、查词顺序都不变。
        await repo.setDictionaryLanguageOverride(named('大辞林'), 'en');
        await repo.setDictionaryLanguageOverride(named('local-pack'), 'ko');
        await repo.loadFromDb();

        expect(loaded(), loadedBefore);
        expect(resultDictionaries(), resultsBefore);
        expect(repo.lookupFilters.termDictionaryOrder, termOrderBefore);
        expect(repo.lookupFilters.hiddenDictionaryNames, isEmpty);
      },
    );
  });
}
