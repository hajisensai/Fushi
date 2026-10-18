import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// BUG-2997 守卫：被用户关掉（隐藏）的词典在 `entries` 与 `popupJson` 两条出口上必须
/// 同口径过滤。
///
/// 此前只有 [buildPopupJsonFromLookup] 过滤隐藏词典，[buildResultFromLookup] 不过滤：
/// 一个只命中隐藏词典的词，宿主按 `entries.isNotEmpty` 判「有结果」去等 WebView
/// 渲染，页面拿到的 popupJson 却是 `[]`，于是画出页面自己的「No results」（彩色
/// emoji 放大镜），且弹窗按最大宽高铺成一大块空面板（真实空结果本该走 Flutter 的
/// 紧凑空态）。
void main() {
  FushiLookupResult makeResult({
    required String expression,
    required String reading,
    required List<String> dictNames,
  }) {
    return FushiLookupResult(
      matched: expression,
      deinflected: expression,
      trace: const [],
      preprocessorSteps: 0,
      term: FushiTermResult(
        expression: expression,
        reading: reading,
        rules: '',
        glossaries: <FushiGlossaryEntry>[
          for (final String dict in dictNames)
            FushiGlossaryEntry(
              dictName: dict,
              glossary: jsonEncode('$dict の $expression'),
              definitionTags: '',
              termTags: '',
            ),
        ],
        frequencies: const [],
        pitches: const [],
      ),
    );
  }

  test('只命中隐藏词典的词：entries 与 popupJson 同为空', () {
    final List<FushiLookupResult> results = <FushiLookupResult>[
      makeResult(
        expression: '永遠',
        reading: 'えいえん',
        dictNames: const <String>['隐藏词典'],
      ),
    ];
    const Set<String> hidden = <String>{'隐藏词典'};

    final DictionarySearchResult result = buildResultFromLookup(
      searchTerm: '永遠',
      results: results,
      maximumTerms: 10,
      hiddenDictionaries: hidden,
    );
    final String popupJson = buildPopupJsonFromLookup(
      results: results,
      maximumTerms: 10,
      hiddenDictionaries: hidden,
    );

    expect(jsonDecode(popupJson), isEmpty);
    expect(result.entries, isEmpty,
        reason: 'entries 与 popupJson 必须同口径：宿主据 entries 判有无结果');
    expect(result.bestLength, 0, reason: '隐藏词典的匹配不贡献高亮长度');
  });

  test('隐藏词典的词头不占 maximumTerms 预算，可见词典的释义照常保留', () {
    final List<FushiLookupResult> results = <FushiLookupResult>[
      makeResult(
        expression: '永遠',
        reading: 'えいえん',
        dictNames: const <String>['隐藏词典'],
      ),
      makeResult(
        expression: '永遠',
        reading: 'とわ',
        dictNames: const <String>['大辞林', '隐藏词典'],
      ),
    ];

    final DictionarySearchResult result = buildResultFromLookup(
      searchTerm: '永遠',
      results: results,
      maximumTerms: 1,
      hiddenDictionaries: const <String>{'隐藏词典'},
    );

    expect(
      result.entries
          .map((DictionaryEntry e) => '${e.reading}/${e.dictionaryName}')
          .toList(),
      <String>['とわ/大辞林'],
    );
    expect(result.truncated, isFalse);
  });

  test('不传隐藏集合时行为不变（默认空集）', () {
    final DictionarySearchResult result = buildResultFromLookup(
      searchTerm: '永遠',
      results: <FushiLookupResult>[
        makeResult(
          expression: '永遠',
          reading: 'えいえん',
          dictNames: const <String>['隐藏词典'],
        ),
      ],
      maximumTerms: 10,
    );
    expect(result.entries, hasLength(1));
  });
}
