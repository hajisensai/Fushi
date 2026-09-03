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
}
