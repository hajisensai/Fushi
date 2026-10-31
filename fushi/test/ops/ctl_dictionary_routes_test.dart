import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/recommended_dictionary_installer.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/ops/ctl_dictionary_pack_routes.dart';
import 'package:fushi/src/ops/ctl_dictionary_json.dart';
import 'package:fushi/src/ops/ctl_dictionary_routes.dart';
import 'package:fushi/src/ops/op_context.dart';
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
      OpContext(ref: _UnusedRef(), focusMainWindow: () async {}),
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

  test('ctlReorderDictionaries: position 在语言组内计算，其它组槽位不动 (D_Nz5R4vSH)', () {
    final Dictionary ja1 = _dict(
      'ja1',
      order: 0,
      metadata: const <String, String>{'sourceLanguage': 'ja'},
    );
    final Dictionary en1 = _dict(
      'en1',
      order: 1,
      metadata: const <String, String>{'sourceLanguage': 'en'},
    );
    final Dictionary ja2 = _dict(
      'ja2',
      order: 2,
      metadata: const <String, String>{'sourceLanguage': 'ja'},
    );
    final Dictionary none = _dict('none', order: 3);
    final Dictionary ja3 = _dict(
      'ja3',
      order: 4,
      metadata: const <String, String>{'sourceLanguage': 'ja'},
    );
    // ja3 移到日语组第 1 位：只在日语组原占的 0/2/4 槽位里重排。
    final List<Dictionary> moved = ctlReorderDictionaries(
      <Dictionary>[ja1, en1, ja2, none, ja3],
      ja3,
      1,
    );
    expect(moved.map((Dictionary d) => d.name), <String>[
      'ja3',
      'en1',
      'ja1',
      'none',
      'ja2',
    ]);
    expect(moved.map((Dictionary d) => d.order), <int>[0, 1, 2, 3, 4]);
    // 越界钳到组尾（日语组 3 本），不越过别组。
    final List<Dictionary> last = ctlReorderDictionaries(moved, ja3, 99);
    expect(last.map((Dictionary d) => d.name), <String>[
      'ja1',
      'en1',
      'ja2',
      'none',
      'ja3',
    ]);
    // 单本组：任何位置都原地不动。
    final List<Dictionary> single = ctlReorderDictionaries(last, en1, 1);
    expect(single.map((Dictionary d) => d.name), <String>[
      'ja1',
      'en1',
      'ja2',
      'none',
      'ja3',
    ]);
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

  group('BUG-3573：混合词典的汉字部分', () {
    final Dictionary mixed = Dictionary(
      name: 'mixed',
      formatKey: 'yomichan',
      order: 4,
      metadata: const <String, String>{
        kDictHasKanjiKey: 'true',
        kDictKanjiHiddenKey: 'true',
        kDictKanjiOrderKey: '0',
      },
      hiddenLanguages: const <String>[],
    );
    final Dictionary kanji = Dictionary(
      name: 'kanjidic',
      formatKey: 'yomichan',
      order: 1,
      type: DictionaryType.kanji,
    );
    final Dictionary term = Dictionary(
      name: 'term',
      formatKey: 'yomichan',
      order: 0,
    );

    test('ctlDictionaryJson 带出汉字部分的开关与位置，普通词典不带', () {
      final Map<String, Object?> json = ctlDictionaryJson(mixed);
      expect(json['enabled'], isTrue, reason: '术语部分');
      expect(json['kanjiEnabled'], isFalse, reason: '汉字部分独立开关');
      expect(json['kanjiOrder'], 0);
      expect(json['order'], 4);
      expect(ctlDictionaryJson(term).containsKey('kanjiEnabled'), isFalse);
      expect(ctlDictionaryJson(kanji).containsKey('kanjiEnabled'), isFalse);
    });

    test(
      'ctlCheckKanjiPartParams：kanjiEnabled 只给混合词典，kanjiPosition 只给汉字分区成员',
      () {
        Matcher status(int code) => throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', code),
        );
        ctlCheckKanjiPartParams(mixed, kanjiEnabled: true, kanjiPosition: 1);
        ctlCheckKanjiPartParams(kanji, kanjiPosition: 2);
        expect(
          () => ctlCheckKanjiPartParams(kanji, kanjiEnabled: true),
          status(400),
        );
        expect(
          () => ctlCheckKanjiPartParams(term, kanjiEnabled: false),
          status(400),
        );
        expect(
          () => ctlCheckKanjiPartParams(term, kanjiPosition: 1),
          status(400),
        );
        expect(
          () => ctlCheckKanjiPartParams(mixed, kanjiPosition: 0),
          status(400),
        );
      },
    );

    test('在「汉字」分区里排序：成员与顺序取 kanjiSectionDictionariesOf', () {
      final List<Dictionary> section = kanjiSectionDictionariesOf(<Dictionary>[
        term,
        kanji,
        mixed,
      ]);
      expect(section.map((Dictionary d) => d.name), <String>[
        'mixed',
        'kanjidic',
      ]);
      final List<Dictionary> moved = ctlReorderDictionaries(
        section,
        mixed,
        2,
        section: DictionaryType.kanji,
      );
      expect(moved.map((Dictionary d) => d.name), <String>[
        'kanjidic',
        'mixed',
      ]);
      expect(
        () => ctlReorderDictionaries(
          section,
          term,
          1,
          section: DictionaryType.kanji,
        ),
        throwsA(
          isA<CtlFailure>().having(
            (CtlFailure f) => f.message,
            'message',
            contains('kanji 分区'),
          ),
        ),
      );
    });
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

  test('新路由注册且与 :name / :id 路由互不抢占', () {
    final List<CtlRoute> routes = buildDictionaryCtlRoutes(
      OpContext(ref: _UnusedRef(), focusMainWindow: () async {}),
    );
    CtlRoute? first(String method, String path) {
      for (final CtlRoute r in routes) {
        if (r.method == method && r.match(path) != null) return r;
      }
      return null;
    }

    expect(
      first('GET', '/api/admin/dictionaries/recommended')!.pattern,
      '/api/admin/dictionaries/recommended',
    );
    expect(
      first('POST', '/api/admin/dictionaries/install')!.pattern,
      '/api/admin/dictionaries/install',
    );
    expect(
      first('GET', '/api/admin/anki/pending')!.pattern,
      '/api/admin/anki/pending',
    );
    expect(
      first('POST', '/api/admin/anki/pending/send')!.pattern,
      '/api/admin/anki/pending/send',
    );
    expect(
      first('POST', '/api/admin/anki/pending/discard-failed')!.pattern,
      '/api/admin/anki/pending/discard-failed',
    );
    expect(
      first(
        'POST',
        '/api/admin/anki/pending/ab12/retry',
      )!.match('/api/admin/anki/pending/ab12/retry'),
      <String, String>{'id': 'ab12'},
    );
    expect(
      first(
        'DELETE',
        '/api/admin/anki/pending/ab12',
      )!.match('/api/admin/anki/pending/ab12'),
      <String, String>{'id': 'ab12'},
    );
  });

  test('推荐包路由注册，状态投影按磁盘定阶段', () {
    final List<CtlRoute> routes = buildDictionaryCtlRoutes(
      OpContext(ref: _UnusedRef(), focusMainWindow: () async {}),
    );
    bool has(String method, String path) =>
        routes.any((CtlRoute r) => r.method == method && r.match(path) != null);
    expect(has('GET', '/api/admin/dictionary-pack'), isTrue);
    expect(has('POST', '/api/admin/dictionary-pack/download'), isTrue);
    expect(has('POST', '/api/admin/dictionary-pack/cancel'), isTrue);
    expect(has('POST', '/api/admin/dictionary-pack/import'), isTrue);
    expect(has('DELETE', '/api/admin/dictionary-pack'), isTrue);

    final Directory dir = Directory.systemTemp.createTempSync('ctl_pack_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final RecommendedPackDownloadController controller =
        RecommendedPackDownloadController(packDirectory: () => dir);
    addTearDown(controller.dispose);
    final Map<String, Object?> idle = ctlPackStatusJson(controller);
    expect(idle['stage'], 'idle');
    expect(idle['downloading'], isFalse);
    expect(idle['readyToImport'], isFalse);
    expect(idle.containsKey('error'), isFalse);
  });

  test('resolveCtlRecommendedDictionary 按 key / 名称定位', () {
    final List<RecommendedDictionary> catalog =
        DictionaryDownloader.catalogForLearningLang(
          learningLang: 'ja',
          glossLang: 'en',
        );
    final RecommendedDictionary first = catalog.first;
    expect(
      resolveCtlRecommendedDictionary(catalog, first.matchPrefix),
      same(first),
    );
    expect(
      resolveCtlRecommendedDictionary(catalog, first.matchPrefix.toUpperCase()),
      same(first),
    );
    expect(
      () => resolveCtlRecommendedDictionary(catalog, 'no-such-dict'),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
      ),
    );
    final Map<String, Object?> json = ctlRecommendedDictionaryJson(
      first,
      index: 0,
      installed: true,
      isDefault: false,
    );
    expect(json['key'], first.matchPrefix);
    expect(json['installed'], isTrue);
  });

  test('isRecommendedDictionaryInstalled 认真名 / 去版本基名 / 前缀+[版本]', () {
    const RecommendedDictionary rec = RecommendedDictionary(
      name: 'JMdict',
      url: 'https://example.com/JMdict.zip',
      description: '',
      matchPrefix: 'JMdict',
      category: DictionaryCategory.jaEn,
      sizeEstimate: '',
    );
    expect(
      isRecommendedDictionaryInstalled(<Dictionary>[_dict('JMdict')], rec),
      isTrue,
    );
    expect(
      isRecommendedDictionaryInstalled(<Dictionary>[
        _dict('JMdict [2024-01-01]'),
      ], rec),
      isTrue,
    );
    expect(
      isRecommendedDictionaryInstalled(<Dictionary>[_dict('JMnedict')], rec),
      isFalse,
    );
    expect(recommendedDictionarySourceOverride(rec)['downloadUrl'], rec.url);
  });

  test('ctlParseLanguageOverride / 字典 JSON 带上覆盖项', () {
    expect(ctlParseLanguageOverride('auto'), isNull);
    expect(ctlParseLanguageOverride(' - '), isNull);
    expect(ctlParseLanguageOverride('ja'), 'ja');
    expect(() => ctlParseLanguageOverride('  '), throwsA(isA<CtlFailure>()));
    final Dictionary d = _dict('x')
      ..displayName = '别名'
      ..languageOverride = 'en';
    final Map<String, Object?> json = ctlDictionaryJson(d);
    expect(json['customDisplayName'], '别名');
    expect(json['languageOverride'], 'en');
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

    test('补振假名 / 频率 / 音调字段（与弹窗制卡同名），空值不写', () {
      final DictionarySearchResult withExtra = DictionarySearchResult(
        searchTerm: '食べる',
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'JMdict',
            word: '食べる',
            reading: 'たべる',
            meaning: 'to eat',
            extra: jsonEncode(<String, Object?>{
              'frequencies': <Object?>[
                <String, Object?>{
                  'dictName': 'JPDB',
                  'values': <Object?>[
                    <String, Object?>{'value': 500, 'display': '500'},
                  ],
                },
              ],
              'pitches': <Object?>[
                <String, Object?>{
                  'dictName': 'NHK',
                  'positions': <int>[2],
                  'patterns': <String>[],
                  'transcriptions': <String>[],
                },
              ],
            }),
          ),
        ],
      );
      final Map<String, String> fields = buildCtlMineFields(
        word: '食べる',
        lookup: withExtra,
      );
      expect(fields['furiganaPlain'], '食[た]べる ');
      expect(fields['freqHarmonicRank'], '500');
      expect(fields['frequenciesHtml'], contains('JPDB: 500'));
      expect(fields['pitchCategories'], 'nakadaka');
      expect(fields['pitchPositions'], contains('<svg'));

      final Map<String, String> plain = buildCtlMineFields(
        word: '生',
        lookup: lookup,
      );
      expect(plain.containsKey('pitchPositions'), isFalse);
      expect(plain.containsKey('frequenciesHtml'), isFalse);
      expect(plain['furiganaPlain'], '生[なま]');
    });

    test('没查词结果时字段留空，不臆造', () {
      final Map<String, String> fields = buildCtlMineFields(word: '猫');
      expect(fields['reading'], '');
      expect(fields['glossary'], '');
    });
  });
}
