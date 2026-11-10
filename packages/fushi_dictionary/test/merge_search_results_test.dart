import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary_core.dart';

/// 本机 + 服务器查词结果合并（[mergeDictionarySearchResults]）。两边的输入都用真实的
/// 结果构建器（[buildResultFromLookup] / [buildPopupJsonFromLookup]）产出，守的是
/// 与引擎产物同形的合并。
void main() {
  FushiLookupResult row({
    required String expression,
    required String reading,
    String? matched,
    List<String> dicts = const <String>[],
    List<FushiFrequencyEntry> frequencies = const <FushiFrequencyEntry>[],
    List<FushiPitchEntry> pitches = const <FushiPitchEntry>[],
  }) => FushiLookupResult(
    matched: matched ?? expression,
    deinflected: expression,
    trace: const <FushiTransformGroup>[],
    preprocessorSteps: 0,
    term: FushiTermResult(
      expression: expression,
      reading: reading,
      rules: '',
      glossaries: <FushiGlossaryEntry>[
        for (final String d in dicts)
          FushiGlossaryEntry(
            dictName: d,
            glossary: jsonEncode('$expression（$d）'),
            definitionTags: '',
            termTags: '',
          ),
      ],
      frequencies: frequencies,
      pitches: pitches,
    ),
  );

  FushiFrequencyEntry freq(String dict, int value) => FushiFrequencyEntry(
    dictName: dict,
    frequencies: <FushiFrequency>[
      FushiFrequency(value: value, displayValue: '$value'),
    ],
  );

  DictionarySearchResult side(
    List<FushiLookupResult> rows, {
    int maximumTerms = 10,
    List<String> order = const <String>[],
    Map<String, String>? styles,
  }) {
    final DictionarySearchResult result = buildResultFromLookup(
      searchTerm: '食べる',
      results: rows,
      maximumTerms: maximumTerms,
      dictionaryOrder: order,
    );
    result.popupJson = buildPopupJsonFromLookup(
      results: rows,
      maximumTerms: maximumTerms,
      hiddenDictionaries: const <String>{},
      dictionaryOrder: order,
    );
    result.remoteDictionaryStyles = styles;
    return result;
  }

  List<Map<String, dynamic>> popup(DictionarySearchResult r) =>
      (jsonDecode(r.popupJson!) as List<dynamic>).cast<Map<String, dynamic>>();

  List<String> glossaryDicts(Map<String, dynamic> group) => <String>[
    for (final dynamic g in group['glossaries'] as List<dynamic>)
      (g as Map<String, dynamic>)['dictionary'] as String,
  ];

  List<String> frequencyDicts(Map<String, dynamic> group) => <String>[
    for (final dynamic f in group['frequencies'] as List<dynamic>)
      (f as Map<String, dynamic>)['dictionary'] as String,
  ];

  DictionarySearchResult merge({
    DictionarySearchResult? local,
    DictionarySearchResult? remote,
    List<String> order = const <String>[],
    Set<String> localNames = const <String>{},
    int maximumTerms = 10,
    Map<String, String>? localStyles,
  }) => mergeDictionarySearchResults(
    local: local,
    remote: remote,
    dictionaryOrder: order,
    localDictionaryNames: localNames,
    maximumTerms: maximumTerms,
    localDictionaryStyles: localStyles,
  )!;

  group('一边为空时原样返回另一边', () {
    final DictionarySearchResult only = side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['Jitendex']),
    ]);

    test('null', () {
      expect(identical(merge(local: only), only), isTrue);
      // 只有服务器那份：副本，释义带 remote 标记，词条原样。
      final DictionarySearchResult remoteOnly = merge(remote: only);
      expect(identical(remoteOnly.entries, only.entries), isTrue);
      expect(
        popup(remoteOnly).single['glossaries'].every(
          (dynamic g) => (g as Map<String, dynamic>)['remote'] == true,
        ),
        isTrue,
      );
      expect(
        mergeDictionarySearchResults(
          local: null,
          remote: null,
          dictionaryOrder: const <String>[],
          localDictionaryNames: const <String>{},
          maximumTerms: 10,
        ),
        isNull,
      );
    });

    test('没有词条也没有汉字', () {
      final DictionarySearchResult empty = DictionarySearchResult(
        searchTerm: '食べる',
      );
      expect(
        identical(merge(local: empty, remote: only).entries, only.entries),
        isTrue,
      );
      expect(identical(merge(local: only, remote: empty), only), isTrue);
    });
  });

  test('服务器里本机已启用的词典被丢掉，本机那份留下；同词头合成一组', () {
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(
        expression: '食べる',
        reading: 'たべる',
        dicts: <String>['Jitendex'],
        frequencies: <FushiFrequencyEntry>[freq('JPDB', 120)],
      ),
    ]);
    final DictionarySearchResult remote = side(<FushiLookupResult>[
      row(
        expression: '食べる',
        reading: 'たべる',
        dicts: <String>['Jitendex', '大辞林'],
        frequencies: <FushiFrequencyEntry>[
          freq('JPDB', 999),
          freq('Novels', 300),
        ],
      ),
    ]);

    final DictionarySearchResult merged = merge(
      local: local,
      remote: remote,
      order: const <String>['大辞林', 'Jitendex'],
      localNames: const <String>{'Jitendex', 'JPDB'},
    );

    final List<Map<String, dynamic>> groups = popup(merged);
    expect(groups, hasLength(1));
    expect(glossaryDicts(groups.single), <String>['大辞林', 'Jitendex']);
    // 频率按词典名并集：本机 JPDB 留本机的值，服务器只补 Novels。
    expect(frequencyDicts(groups.single), <String>['JPDB', 'Novels']);
    final Map<String, dynamic> jpdb =
        (groups.single['frequencies'] as List<dynamic>).first
            as Map<String, dynamic>;
    expect((jpdb['frequencies'] as List<dynamic>).single['value'], 120);

    // 词条与弹窗同序、同去重；Jitendex 词条是本机那条（本机 extra 带 JPDB=120）。
    expect(
      merged.entries.map((DictionaryEntry e) => e.dictionaryName).toList(),
      <String>['大辞林', 'Jitendex'],
    );
    expect(
      identical(merged.entries.last.meaning, local.entries.single.meaning),
      isTrue,
    );
    // 两边都有的组：每条词条 extra 的频率都换成同一份并集（制卡字段读它）。
    for (final DictionaryEntry e in merged.entries) {
      final Map<String, dynamic> extra =
          jsonDecode(e.extra) as Map<String, dynamic>;
      expect(
        (extra['frequencies'] as List<dynamic>)
            .map((dynamic f) => (f as Map<String, dynamic>)['dictName'])
            .toList(),
        <String>['JPDB', 'Novels'],
      );
    }
    expect(merged.headwordCount, 1);
    expect(merged.truncated, isFalse);
    expect(merged.scrollPosition, 0);
  });

  test('服务器组去重后一条释义不剩就整组丢掉', () {
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['Jitendex']),
    ]);
    final DictionarySearchResult remote = side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['大辞林']),
      row(
        expression: '食',
        reading: 'しょく',
        matched: '食',
        dicts: <String>['Jitendex'],
      ),
    ]);
    final DictionarySearchResult merged = merge(
      local: local,
      remote: remote,
      localNames: const <String>{'Jitendex'},
    );
    expect(
      popup(merged).map((Map<String, dynamic> g) => g['expression']).toList(),
      <String>['食べる'],
    );
    expect(merged.entries.map((DictionaryEntry e) => e.word).toSet(), <String>{
      '食べる',
    });
  });

  test('组序：匹配长度降序，同长度服务器组在只有本机的组之前；截断与计数', () {
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['Local']),
      row(
        expression: '食',
        reading: 'しょく',
        matched: '食',
        dicts: <String>['Local'],
      ),
    ]);
    final DictionarySearchResult remote = side(<FushiLookupResult>[
      row(
        expression: '食む',
        reading: 'はむ',
        matched: '食べ',
        dicts: <String>['Srv'],
      ),
      row(expression: '食べ', reading: 'たべ', dicts: <String>['Srv']),
      row(expression: '食', reading: 'くう', matched: '食', dicts: <String>['Srv']),
    ]);

    final DictionarySearchResult all = merge(local: local, remote: remote);
    expect(
      popup(all).map((Map<String, dynamic> g) => g['reading']).toList(),
      <String>['たべる', 'はむ', 'たべ', 'くう', 'しょく'],
    );
    expect(all.headwordCount, 5);
    expect(all.truncated, isFalse);
    expect(all.bestLength, 3);

    final DictionarySearchResult capped = merge(
      local: local,
      remote: remote,
      maximumTerms: 3,
    );
    expect(
      popup(capped).map((Map<String, dynamic> g) => g['reading']).toList(),
      <String>['たべる', 'はむ', 'たべ'],
    );
    expect(
      capped.entries.map((DictionaryEntry e) => e.reading).toList(),
      <String>['たべる', 'はむ', 'たべ'],
    );
    expect(capped.headwordCount, 3);
    expect(capped.truncated, isTrue);
  });

  test('任一边原本就被截断 ⇒ 合并结果也标截断', () {
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['A']),
      row(expression: '食べ', reading: 'たべ', dicts: <String>['A']),
    ], maximumTerms: 1);
    expect(local.truncated, isTrue);
    final DictionarySearchResult remote = side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['B']),
    ]);
    expect(merge(local: local, remote: remote).truncated, isTrue);
  });

  test('组内按混排词典顺序排，不在名单里的排最后且稳定', () {
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(
        expression: '食べる',
        reading: 'たべる',
        dicts: <String>['L-unknown', 'L1'],
      ),
    ]);
    final DictionarySearchResult remote = side(<FushiLookupResult>[
      row(
        expression: '食べる',
        reading: 'たべる',
        dicts: <String>['S-unknown', 'S1'],
      ),
    ]);
    final DictionarySearchResult merged = merge(
      local: local,
      remote: remote,
      order: const <String>['S1', 'L1'],
    );
    expect(glossaryDicts(popup(merged).single), <String>[
      'S1',
      'L1',
      'S-unknown',
      'L-unknown',
    ]);
    expect(
      merged.entries.map((DictionaryEntry e) => e.dictionaryName).toList(),
      <String>['S1', 'L1', 'S-unknown', 'L-unknown'],
    );
  });

  test('空读音组并进另一边该表记唯一的显式读音组（BUG-2753 同口径）', () {
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(expression: '取り戻す', reading: '', dicts: <String>['MDX']),
    ]);
    final DictionarySearchResult remote = side(<FushiLookupResult>[
      row(expression: '取り戻す', reading: 'とりもどす', dicts: <String>['Yomitan']),
    ]);
    final DictionarySearchResult merged = merge(local: local, remote: remote);
    final List<Map<String, dynamic>> groups = popup(merged);
    expect(groups, hasLength(1));
    expect(groups.single['reading'], 'とりもどす');
    expect(glossaryDicts(groups.single), <String>['Yomitan', 'MDX']);
    expect(
      merged.entries.map((DictionaryEntry e) => e.reading).toSet(),
      <String>{'とりもどす'},
    );
  });

  test('汉字结果并集按 (词典, 字) 去重，本机在前', () {
    FushiKanjiResult kanji(String dict) => FushiKanjiResult(
      character: '食',
      onyomi: 'ショク',
      kunyomi: 'た.べる',
      radical: '食',
      strokes: 9,
      meanings: const <String>['eat'],
      dictName: dict,
    );
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(expression: '食', reading: 'しょく', dicts: <String>['A']),
    ]).withKanjiResults(<FushiKanjiResult>[kanji('KANJIDIC')]);
    final DictionarySearchResult remote = side(<FushiLookupResult>[
      row(expression: '食', reading: 'しょく', dicts: <String>['B']),
    ]).withKanjiResults(<FushiKanjiResult>[kanji('KANJIDIC'), kanji('Other')]);
    final DictionarySearchResult merged = merge(local: local, remote: remote);
    expect(
      merged.kanjiResults.map((FushiKanjiResult k) => k.dictName).toList(),
      <String>['KANJIDIC', 'Other'],
    );
    expect(
      identical(merged.kanjiResults.first, local.kanjiResults.first),
      isTrue,
    );
  });

  test('样式：服务器样式 ∪ 本机样式（本机优先），同输入返回同一实例', () {
    final Map<String, String> remoteStyles = <String, String>{
      '大辞林': '.r{}',
      'Jitendex': '.remote-j{}',
    };
    final Map<String, String> localStyles = <String, String>{
      'Jitendex': '.local-j{}',
    };
    final DictionarySearchResult local = side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['Jitendex']),
    ]);
    DictionarySearchResult remote() => side(<FushiLookupResult>[
      row(expression: '食べる', reading: 'たべる', dicts: <String>['大辞林']),
    ], styles: remoteStyles);

    final DictionarySearchResult a = merge(
      local: local,
      remote: remote(),
      localStyles: localStyles,
    );
    expect(a.remoteDictionaryStyles, <String, String>{
      '大辞林': '.r{}',
      'Jitendex': '.local-j{}',
    });
    final DictionarySearchResult b = merge(
      local: local,
      remote: remote(),
      localStyles: localStyles,
    );
    expect(
      identical(a.remoteDictionaryStyles, b.remoteDictionaryStyles),
      isTrue,
    );
    // 老 host（没带样式）⇒ 仍是 null，弹窗用本机样式。
    expect(
      merge(
        local: local,
        remote: side(<FushiLookupResult>[
          row(expression: '食べる', reading: 'たべる', dicts: <String>['大辞林']),
        ]),
        localStyles: localStyles,
      ).remoteDictionaryStyles,
      isNull,
    );
  });

  // 审查发现：合并在 UI isolate 上整份编解码两份弹窗文档。大结果搬到后台 isolate，
  // 结果必须与就地合并逐字段相同（含样式表的实例身份：弹窗靠 identical 判断重发）。
  group('后台 isolate 合并 = 就地合并', () {
    String fingerprint(DictionarySearchResult? r) => r == null
        ? 'null'
        : jsonEncode(<String, Object?>{
            'json': r.toJson(),
            'popup': r.popupJson,
            'styles': r.remoteDictionaryStyles,
          });

    final Map<String, String> remoteStyles = <String, String>{
      '大辞林': '.r{}',
      'Jitendex': '.remote-j{}',
    };
    final Map<String, String> localStyles = <String, String>{
      'Jitendex': '.local-j{}',
    };
    DictionarySearchResult localSide() => side(<FushiLookupResult>[
      row(
        expression: '食べる',
        reading: 'たべる',
        dicts: <String>['Jitendex', 'JMdict'],
        frequencies: <FushiFrequencyEntry>[freq('JPDB', 120)],
      ),
      row(expression: '食べ', reading: 'たべ', dicts: <String>['JMdict']),
    ]);
    DictionarySearchResult remoteSide() => side(<FushiLookupResult>[
      row(
        expression: '食べる',
        reading: 'たべる',
        dicts: <String>['Jitendex', '大辞林'],
        frequencies: <FushiFrequencyEntry>[freq('BCCWJ', 300)],
      ),
      row(expression: '食', reading: 'しょく', dicts: <String>['大辞林']),
    ], styles: remoteStyles);

    Future<void> expectSame({
      DictionarySearchResult? local,
      DictionarySearchResult? remote,
    }) async {
      const List<String> order = <String>['JMdict', 'Jitendex', '大辞林'];
      const Set<String> names = <String>{'Jitendex', 'JMdict'};
      final DictionarySearchResult? inline = mergeDictionarySearchResults(
        local: local,
        remote: remote,
        dictionaryOrder: order,
        localDictionaryNames: names,
        maximumTerms: 10,
        localDictionaryStyles: localStyles,
      );
      final DictionarySearchResult? offThread =
          await mergeDictionarySearchResultsAsync(
            local: local,
            remote: remote,
            dictionaryOrder: order,
            localDictionaryNames: names,
            maximumTerms: 10,
            localDictionaryStyles: localStyles,
            isolateThreshold: 0,
          );
      expect(fingerprint(offThread), fingerprint(inline));
      expect(
        identical(
          offThread?.remoteDictionaryStyles,
          inline?.remoteDictionaryStyles,
        ),
        isTrue,
        reason: '样式表在调用方 isolate 上合并，实例身份与就地合并相同',
      );
    }

    test('两边都有结果', () async {
      await expectSame(local: localSide(), remote: remoteSide());
    });

    test('只有服务器那份（打 remote 标记）', () async {
      await expectSame(remote: remoteSide());
      final DictionarySearchResult remote = remoteSide();
      final DictionarySearchResult marked =
          await markRemoteDictionarySearchResultAsync(
            remote,
            isolateThreshold: 0,
          );
      expect(
        fingerprint(marked),
        fingerprint(markRemoteDictionarySearchResult(remote)),
      );
      expect(identical(marked.remoteDictionaryStyles, remoteStyles), isTrue);
    });

    test('popupJson 坏掉退化成拼接；服务器不带样式', () async {
      final DictionarySearchResult broken = localSide()..popupJson = '{oops';
      await expectSame(local: broken, remote: remoteSide());
      await expectSame(
        local: localSide(),
        remote: side(<FushiLookupResult>[
          row(expression: '食べる', reading: 'たべる', dicts: <String>['大辞林']),
        ]),
      );
    });

    test('低于阈值就地合并：返回的就是同步版的结果', () async {
      final DictionarySearchResult local = localSide();
      final DictionarySearchResult? result =
          await mergeDictionarySearchResultsAsync(
            local: local,
            remote: null,
            dictionaryOrder: const <String>[],
            localDictionaryNames: const <String>{},
            maximumTerms: 10,
          );
      expect(identical(result, local), isTrue);
    });
  });

  group('popupJson 坏掉时退化成不去重的拼接，绝不抛', () {
    for (final String bad in <String>['{not json', '{"a":1}', '[1]', '[{}]']) {
      test(bad, () {
        final DictionarySearchResult local = side(<FushiLookupResult>[
          row(expression: '食べる', reading: 'たべる', dicts: <String>['Jitendex']),
        ]);
        final DictionarySearchResult remote = side(<FushiLookupResult>[
          row(
            expression: '食べる',
            reading: 'たべる',
            dicts: <String>['Jitendex', '大辞林'],
          ),
        ])..popupJson = bad;
        final DictionarySearchResult merged = merge(
          local: local,
          remote: remote,
          localNames: const <String>{'Jitendex'},
        );
        expect(merged.popupJson, isNull);
        expect(
          merged.entries.map((DictionaryEntry e) => e.dictionaryName).toList(),
          <String>['Jitendex', '大辞林', 'Jitendex'],
        );
      });
    }

    test('一边 popupJson 为 null：词条照常合并，popupJson 为 null', () {
      final DictionarySearchResult local = side(<FushiLookupResult>[
        row(expression: '食べる', reading: 'たべる', dicts: <String>['Jitendex']),
      ]);
      final DictionarySearchResult remote = side(<FushiLookupResult>[
        row(
          expression: '食べる',
          reading: 'たべる',
          dicts: <String>['Jitendex', '大辞林'],
        ),
      ])..popupJson = null;
      final DictionarySearchResult merged = merge(
        local: local,
        remote: remote,
        localNames: const <String>{'Jitendex'},
      );
      expect(merged.popupJson, isNull);
      expect(
        merged.entries.map((DictionaryEntry e) => e.dictionaryName).toList(),
        <String>['大辞林', 'Jitendex'],
      );
    });

    test('词条 extra 坏掉不影响合并', () {
      final DictionarySearchResult local = DictionarySearchResult(
        searchTerm: '食べる',
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'L',
            word: '食べる',
            reading: 'たべる',
            meaning: 'x',
            extra: '{oops',
          ),
        ],
      );
      final DictionarySearchResult remote = DictionarySearchResult(
        searchTerm: '食べる',
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'S',
            word: '食べる',
            reading: 'たべる',
            meaning: 'y',
            extra: '[]',
          ),
        ],
      );
      final DictionarySearchResult merged = merge(local: local, remote: remote);
      expect(
        merged.entries.map((DictionaryEntry e) => e.dictionaryName).toList(),
        <String>['S', 'L'],
      );
      expect(merged.entries.last.extra, '{oops');
    });
  });

  group('弹窗释义的服务器来源标记', () {
    test('合并后只有服务器那份的释义带 remote: true，本机的不带', () {
      final DictionarySearchResult local = side(<FushiLookupResult>[
        row(expression: '食べる', reading: 'たべる', dicts: <String>['Jitendex']),
      ]);
      final DictionarySearchResult remote = side(<FushiLookupResult>[
        row(
          expression: '食べる',
          reading: 'たべる',
          dicts: <String>['Jitendex', '大辞林'],
        ),
      ]);
      final DictionarySearchResult merged = merge(
        local: local,
        remote: remote,
        order: const <String>['大辞林', 'Jitendex'],
        localNames: const <String>{'Jitendex'},
      );
      final Map<String, Object?> flags = <String, Object?>{
        for (final dynamic g
            in popup(merged).single['glossaries'] as List<dynamic>)
          (g as Map<String, dynamic>)['dictionary'] as String: g['remote'],
      };
      expect(flags, <String, Object?>{'大辞林': true, 'Jitendex': null});
      expect(
        (popup(merged).single['glossaries'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .firstWhere(
              (Map<String, dynamic> g) => g['dictionary'] == 'Jitendex',
            )
            .containsKey('remote'),
        isFalse,
        reason: '本机释义不带键：浏览器扩展与旧弹窗渲染不变',
      );
      // DictionaryEntry 不变：词条上没有任何来源标记。
      for (final DictionaryEntry e in merged.entries) {
        expect(e.extra.contains('"remote"'), isFalse);
      }
    });

    test('服务器一组只有一份 popup 时同样带标记；输入不被改写', () {
      final DictionarySearchResult local = side(<FushiLookupResult>[
        row(expression: '食べる', reading: 'たべる', dicts: <String>['Jitendex']),
      ]);
      final DictionarySearchResult remote = side(<FushiLookupResult>[
        row(
          expression: '食',
          reading: 'しょく',
          matched: '食',
          dicts: <String>['大辞林'],
        ),
      ]);
      final String remoteBefore = remote.popupJson!;
      final DictionarySearchResult merged = merge(local: local, remote: remote);
      final Map<String, dynamic> serverGroup = popup(
        merged,
      ).firstWhere((Map<String, dynamic> g) => g['expression'] == '食');
      expect(
        (serverGroup['glossaries'] as List<dynamic>).single['remote'],
        isTrue,
      );
      expect(remote.popupJson, remoteBefore);
    });

    test('popupJson 为 null 时只有服务器那份原样返回', () {
      final DictionarySearchResult remote = DictionarySearchResult(
        searchTerm: '食べる',
        entries: <DictionaryEntry>[
          DictionaryEntry(
            dictionaryName: 'S',
            word: '食べる',
            reading: 'たべる',
            meaning: 'y',
            extra: '[]',
          ),
        ],
      );
      expect(
        identical(markRemoteDictionarySearchResult(remote), remote),
        isTrue,
      );
    });
  });
}
