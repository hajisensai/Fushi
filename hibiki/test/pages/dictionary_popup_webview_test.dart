import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

void main() {
  group('dictionary popup scroll lifecycle', () {
    test('resets viewport scroll before rendering a new lookup', () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(source, contains('final String beforeRenderJs = isLoadMore'));
      expect(
        source,
        contains('window.__hoshiResetPopupScroll();\n'
            '          window.renderPopup();'),
        reason: 'A preserved warm popup WebView keeps its DOM scroll position. '
            'Fresh lookups must reset before renderPopup replaces the content.',
      );
      expect(
        source,
        contains("? 'window.updatePopupIncremental();'"),
        reason: 'Loading more results for the same query must keep the current '
            'scroll position instead of jumping back to the top.',
      );
    });

    test('injects popup instant-scroll preference into the caret runtime', () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(source, contains('Future<void> _pushInstantScrollPreference()'));
      expect(
        source,
        contains(
            'final bool enabled = ref.read(appProvider).popupInstantScroll'),
        reason: 'Theme/dependency changes must re-push the current preference '
            'into the already-loaded popup WebView.',
      );
      expect(source, contains('appModel.popupInstantScroll'));
      expect(source,
          contains('final popupInstantScroll = appModel.popupInstantScroll'));
      expect(
        source,
        contains('ReaderCaretScripts.instantScrollInvocation('),
        reason: 'The persisted e-ink setting must be pushed into the popup '
            'WebView through the shared caret invocation builder so LB/RB and '
            'edge-follow scroll without animation when enabled.',
      );
      expect(
        source,
        contains(
            '      \${ReaderCaretScripts.instantScrollInvocation(popupInstantScroll)};\n'
            '      window.__hoshiResetPopupScroll = function() {'),
        reason:
            'Initial result injection must set the caret scroll mode before '
            'rendering or resetting the warm popup DOM.',
      );
    });
  });

  group('DictionaryPopupWebViewState.buildLookupEntriesJson', () {
    test('merges frequency and pitch metadata across grouped entries', () {
      final result = DictionarySearchResult(
        searchTerm: '食べる',
        entries: [
          DictionaryEntry(
            dictionaryName: 'TermDict',
            word: '食べる',
            reading: 'たべる',
            meaning: jsonEncode(['to eat']),
          ),
          DictionaryEntry(
            dictionaryName: 'MetadataDict',
            word: '食べる',
            reading: 'たべる',
            meaning: jsonEncode(['metadata carrier']),
            extra: jsonEncode({
              'frequencies': [
                {
                  'dictName': 'BCCWJ',
                  'values': [
                    {'value': 500, 'display': '500'},
                  ],
                },
              ],
              'pitches': [
                {
                  'dictName': 'NHK',
                  'positions': [2],
                },
              ],
            }),
          ),
        ],
      );

      final json = DictionaryPopupWebViewState.buildLookupEntriesJson(result);
      final entries = jsonDecode(json) as List<dynamic>;
      final entry = entries.single as Map<String, dynamic>;

      expect(entry['frequencies'], [
        {
          'dictionary': 'BCCWJ',
          'frequencies': [
            {'value': 500, 'displayValue': '500'},
          ],
        },
      ]);
      expect(entry['pitches'], [
        {
          'dictionary': 'NHK',
          'pitchPositions': [2],
        },
      ]);
    });

    test('deduplicates identical frequencies from multiple entries', () {
      final result = DictionarySearchResult(
        searchTerm: '見る',
        entries: [
          DictionaryEntry(
            dictionaryName: 'DictA',
            word: '見る',
            reading: 'みる',
            meaning: jsonEncode(['to see']),
            extra: jsonEncode({
              'frequencies': [
                {
                  'dictName': 'BCCWJ',
                  'values': [
                    {'value': 100, 'display': '100'},
                  ],
                },
              ],
              'pitches': [],
            }),
          ),
          DictionaryEntry(
            dictionaryName: 'DictB',
            word: '見る',
            reading: 'みる',
            meaning: jsonEncode(['to look']),
            extra: jsonEncode({
              'frequencies': [
                {
                  'dictName': 'BCCWJ',
                  'values': [
                    {'value': 100, 'display': '100'},
                  ],
                },
              ],
              'pitches': [],
            }),
          ),
        ],
      );

      final json = DictionaryPopupWebViewState.buildLookupEntriesJson(result);
      final entries = jsonDecode(json) as List<dynamic>;
      final entry = entries.single as Map<String, dynamic>;

      expect(entry['glossaries'], hasLength(2));
      expect(entry['frequencies'], hasLength(1));
    });
  });

  group('buildPopupJsonFromLookup parity', () {
    List<HoshiLookupResult> makeLookupResults() {
      return [
        HoshiLookupResult(
          matched: '食べた',
          deinflected: '食べる',
          trace: [],
          preprocessorSteps: 0,
          term: HoshiTermResult(
            expression: '食べる',
            reading: 'たべる',
            rules: '',
            glossaries: [
              HoshiGlossaryEntry(
                dictName: 'JMdict',
                glossary: jsonEncode(['to eat', 'to consume']),
                definitionTags: 'v1',
                termTags: 'common',
              ),
              HoshiGlossaryEntry(
                dictName: '大辞泉',
                glossary: jsonEncode({
                  'tag': 'div',
                  'content': [
                    {'tag': 'span', 'content': '食べること'}
                  ],
                }),
                definitionTags: '',
                termTags: '',
              ),
            ],
            frequencies: [
              HoshiFrequencyEntry(
                dictName: 'BCCWJ',
                frequencies: [
                  HoshiFrequency(value: 500, displayValue: '500'),
                  HoshiFrequency(value: 0, displayValue: 'Top 500'),
                ],
              ),
            ],
            pitches: [
              HoshiPitchEntry(dictName: 'NHK', pitchPositions: [2]),
            ],
          ),
        ),
        HoshiLookupResult(
          matched: '食べた',
          deinflected: '食べる',
          trace: [],
          preprocessorSteps: 0,
          term: HoshiTermResult(
            expression: '食べる',
            reading: 'たべる',
            rules: '',
            glossaries: [
              HoshiGlossaryEntry(
                dictName: 'Kenkyusha',
                glossary: jsonEncode('eat; consume'),
                definitionTags: '',
                termTags: '',
              ),
            ],
            frequencies: [
              HoshiFrequencyEntry(
                dictName: 'JPDB',
                frequencies: [
                  HoshiFrequency(value: 120, displayValue: '#120'),
                ],
              ),
            ],
            pitches: [
              HoshiPitchEntry(dictName: 'NHK', pitchPositions: [2]),
            ],
          ),
        ),
      ];
    }

    test('produces structurally equivalent JSON to buildLookupEntriesJson', () {
      final lookupResults = makeLookupResults();
      const maxTerms = 100;

      final newJson = buildPopupJsonFromLookup(
        results: lookupResults,
        maximumTerms: maxTerms,
      );
      final oldResult = buildResultFromLookup(
        searchTerm: '食べた',
        results: lookupResults,
        maximumTerms: maxTerms,
      );
      final oldJson =
          DictionaryPopupWebViewState.buildLookupEntriesJson(oldResult);

      final newParsed = jsonDecode(newJson) as List;
      final oldParsed = jsonDecode(oldJson) as List;

      expect(newParsed.length, oldParsed.length);

      for (var i = 0; i < newParsed.length; i++) {
        final n = newParsed[i] as Map<String, dynamic>;
        final o = oldParsed[i] as Map<String, dynamic>;

        expect(n['expression'], o['expression']);
        expect(n['reading'], o['reading']);
        expect(n['matched'], o['matched']);

        final nGloss = n['glossaries'] as List;
        final oGloss = o['glossaries'] as List;
        expect(nGloss.length, oGloss.length);
        for (var j = 0; j < nGloss.length; j++) {
          expect(nGloss[j]['dictionary'], oGloss[j]['dictionary']);
          expect(nGloss[j]['content'], oGloss[j]['content']);
          expect(nGloss[j]['definitionTags'], oGloss[j]['definitionTags']);
          expect(nGloss[j]['termTags'], oGloss[j]['termTags']);
        }

        final nFreqs = n['frequencies'] as List;
        final oFreqs = o['frequencies'] as List;
        expect(nFreqs.length, oFreqs.length);
        for (var j = 0; j < nFreqs.length; j++) {
          expect(nFreqs[j]['dictionary'], oFreqs[j]['dictionary']);
          expect(nFreqs[j]['frequencies'], oFreqs[j]['frequencies']);
        }

        final nPitches = n['pitches'] as List;
        final oPitches = o['pitches'] as List;
        expect(nPitches.length, oPitches.length);
        for (var j = 0; j < nPitches.length; j++) {
          expect(nPitches[j]['dictionary'], oPitches[j]['dictionary']);
          expect(nPitches[j]['pitchPositions'], oPitches[j]['pitchPositions']);
        }
      }
    });

    test('respects maximumTerms limit', () {
      final lookupResults = makeLookupResults();
      final json = buildPopupJsonFromLookup(
        results: lookupResults,
        maximumTerms: 2,
      );
      final parsed = jsonDecode(json) as List;
      final entry = parsed.single as Map<String, dynamic>;
      final glossaries = entry['glossaries'] as List;
      expect(glossaries.length, 2);
    });

    test('returns empty array for empty results', () {
      final json = buildPopupJsonFromLookup(results: [], maximumTerms: 100);
      expect(json, '[]');
    });
  });
}
