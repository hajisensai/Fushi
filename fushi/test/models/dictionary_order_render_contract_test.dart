import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

void main() {
  const List<String> managedOrder = <String>['OALDPE', 'wty-en-en'];
  final List<FushiLookupResult> nativeOldOrder = <FushiLookupResult>[
    FushiLookupResult(
      matched: 'sorry',
      deinflected: 'sorry',
      trace: const <FushiTransformGroup>[],
      preprocessorSteps: 0,
      term: FushiTermResult(
        expression: 'sorry',
        reading: '',
        rules: '',
        glossaries: const <FushiGlossaryEntry>[
          FushiGlossaryEntry(
            dictName: 'wty-en-en',
            glossary: 'old first',
            definitionTags: '',
            termTags: '',
          ),
          FushiGlossaryEntry(
            dictName: 'OALDPE',
            glossary: 'managed first',
            definitionTags: '',
            termTags: '',
          ),
        ],
        frequencies: const <FushiFrequencyEntry>[],
        pitches: const <FushiPitchEntry>[],
      ),
    ),
  ];

  test('full result follows managed dictionary order', () {
    final DictionarySearchResult result = buildResultFromLookup(
      searchTerm: 'sorry',
      results: nativeOldOrder,
      maximumTerms: 10,
      dictionaryOrder: managedOrder,
    );

    expect(
      result.entries.map((DictionaryEntry entry) => entry.dictionaryName),
      managedOrder,
    );
  });

  test('popup JSON follows managed dictionary order', () {
    final List<dynamic> decoded =
        jsonDecode(
              buildPopupJsonFromLookup(
                results: nativeOldOrder,
                maximumTerms: 10,
                hiddenDictionaries: const <String>{},
                dictionaryOrder: managedOrder,
              ),
            )
            as List<dynamic>;
    final List<dynamic> glossaries =
        (decoded.single as Map<String, dynamic>)['glossaries'] as List<dynamic>;

    expect(
      glossaries.map(
        (dynamic item) =>
            (item as Map<String, dynamic>)['dictionary'] as String,
      ),
      managedOrder,
    );
  });

  // BUG-2579：引擎只合并 (expression, reading) 完全相同的行，MDX 这类 simple dict
  // 读音恒空，与 Yomitan 的显式读音行是两条结果；Dart 侧按词头把它们拼成同一张卡
  // 时，词典顺序必须跨行生效，否则后一行（恒是 MDX）无论管理页排第几都挂在卡尾。
  group('BUG-2579 dictionary order spans engine rows of one headword', () {
    const List<String> mixedOrder = <String>['明鏡', 'MDX辞典', '大辞林'];
    FushiLookupResult row({
      required String expression,
      required String reading,
      required List<String> dictionaries,
    }) {
      return FushiLookupResult(
        matched: expression,
        deinflected: expression,
        trace: const <FushiTransformGroup>[],
        preprocessorSteps: 0,
        term: FushiTermResult(
          expression: expression,
          reading: reading,
          rules: '',
          glossaries: <FushiGlossaryEntry>[
            for (final String dictionary in dictionaries)
              FushiGlossaryEntry(
                dictName: dictionary,
                glossary: '"$dictionary:$expression"',
                definitionTags: '',
                termTags: '',
              ),
          ],
          frequencies: const <FushiFrequencyEntry>[],
          pitches: const <FushiPitchEntry>[],
        ),
      );
    }

    // 引擎顺序：Yomitan 行（显式读音）在前，MDX 行（空读音）在后；第二个词头夹在
    // 中间，钉住「只在词头组内重排、组间顺序不动」。
    final List<FushiLookupResult> rows = <FushiLookupResult>[
      row(
        expression: 'しんどい',
        reading: 'しんどい',
        dictionaries: const <String>['明鏡', '大辞林'],
      ),
      row(
        expression: 'しんど',
        reading: 'しんど',
        dictionaries: const <String>['大辞林'],
      ),
      row(
        expression: 'しんどい',
        reading: '',
        dictionaries: const <String>['MDX辞典'],
      ),
    ];

    test('full result keeps MDX where the management page put it', () {
      final DictionarySearchResult result = buildResultFromLookup(
        searchTerm: 'しんどい',
        results: rows,
        maximumTerms: 10,
        dictionaryOrder: mixedOrder,
      );

      expect(
        result.entries
            .map(
              (DictionaryEntry entry) =>
                  '${entry.word}/${entry.dictionaryName}',
            )
            .toList(),
        <String>['しんどい/明鏡', 'しんどい/MDX辞典', 'しんどい/大辞林', 'しんど/大辞林'],
      );
      expect(result.headwordCount, 2);
    });

    test('popup JSON keeps MDX where the management page put it', () {
      final List<dynamic> decoded =
          jsonDecode(
                buildPopupJsonFromLookup(
                  results: rows,
                  maximumTerms: 10,
                  hiddenDictionaries: const <String>{},
                  dictionaryOrder: mixedOrder,
                ),
              )
              as List<dynamic>;

      expect(decoded.length, 2, reason: '空读音的 MDX 行归入 しんどい 卡，不另开卡');
      final Map<String, dynamic> shindoi =
          decoded.first as Map<String, dynamic>;
      expect(shindoi['expression'], 'しんどい');
      expect(
        (shindoi['glossaries'] as List<dynamic>).map(
          (dynamic item) =>
              (item as Map<String, dynamic>)['dictionary'] as String,
        ),
        mixedOrder,
      );
      final Map<String, dynamic> shindo = decoded.last as Map<String, dynamic>;
      expect(shindo['expression'], 'しんど');
    });
  });
}
