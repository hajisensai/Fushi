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
      // BUG-297 / TODO-393：换词复用热槽 WebView 时，renderPopup 之前必须先 (a) 复位
      // 视口滚动（热槽 DOM 残留旧滚动位置），(b) 归零 JS 句子上下文镜像标量（否则重建的
      // 「上 N / 下 N」选择器据残留值着色，与已清的宿主草稿不一致）。断言三者顺序：
      // __hoshiResetPopupScroll → resetSentenceContextMirror → renderPopup。
      final int scrollResetAt =
          source.indexOf('window.__hoshiResetPopupScroll();');
      final int mirrorResetAt =
          source.indexOf('window.resetSentenceContextMirror();');
      final int renderAt = source.indexOf('window.renderPopup();');
      expect(scrollResetAt, greaterThanOrEqualTo(0),
          reason:
              'A preserved warm popup WebView keeps its DOM scroll position. '
              'Fresh lookups must reset viewport scroll before renderPopup.');
      expect(mirrorResetAt, greaterThanOrEqualTo(0),
          reason:
              'Fresh lookups must zero the JS sentence-context mirror so the '
              'rebuilt picker matches the host-cleared draft (BUG-297).');
      expect(renderAt, greaterThan(mirrorResetAt));
      expect(mirrorResetAt, greaterThan(scrollResetAt));
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

  group('dictionary popup empty-result rendering', () {
    test('empty and kanji-only results are still injected into renderPopup',
        () {
      final source = File(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      ).readAsStringSync();

      expect(
        source,
        isNot(contains('if (widget.result.entries.isEmpty) return;')),
        reason: 'A warm popup WebView must not keep a blank/stale DOM when the '
            'lookup has zero term entries. Empty and kanji-only results must '
            'still reach popup.js renderPopup(), which renders no-results or '
            'the kanji card and emits popupRendered.',
      );

      final int pushStart = source.indexOf('void _pushResults()');
      expect(pushStart, greaterThanOrEqualTo(0));
      final String pushBody = source.substring(pushStart);

      final int entriesAt = pushBody.indexOf('window.lookupEntries =');
      final int kanjiAt = pushBody.indexOf('window.kanjiResults =');
      final int noResultsAt = pushBody.indexOf('window._noResultsMessage =');
      final int beforeRenderAt = pushBody.indexOf(r'$beforeRenderJs');

      expect(entriesAt, greaterThanOrEqualTo(0));
      expect(kanjiAt, greaterThan(entriesAt));
      expect(beforeRenderAt, greaterThan(kanjiAt));
      expect(beforeRenderAt, greaterThan(noResultsAt));
      expect(pushBody, contains('window.renderPopup();'));
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
