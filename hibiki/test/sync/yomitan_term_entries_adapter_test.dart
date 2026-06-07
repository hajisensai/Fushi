import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/sync/yomitan_term_entries_adapter.dart';

DictionaryEntry _entry({
  String word = '分かる',
  String reading = 'わかる',
  String meaning = '[{"type":"structured-content","content":"to understand"}]',
  String dict = 'Jitendex',
}) {
  final extra = jsonEncode({
    'definitionTags': 'v5 vi',
    'termTags': 'P',
    'matched': 'わかる',
    'deinflected': 'わかる',
    'frequencies': [
      {
        'dictName': 'Freq',
        'values': [
          {'value': 1234, 'display': '1234'}
        ]
      }
    ],
    'pitches': [
      {
        'dictName': 'Pitch',
        'positions': [2]
      }
    ],
  });
  return DictionaryEntry(
    dictionaryName: dict,
    word: word,
    reading: reading,
    meaning: meaning,
    extra: extra,
    popularity: 0,
  );
}

void main() {
  group('buildYomitanTermEntriesResponse', () {
    test('wraps a result into termEntries top-level shape', () {
      final result = DictionarySearchResult(
        searchTerm: 'わかる',
        entries: [_entry()],
        bestLength: 3,
      );
      final out = buildYomitanTermEntriesResponse(result, 0);

      expect(out['index'], 0);
      expect(out['originalTextLength'], 3);
      final entries = out['dictionaryEntries'] as List;
      expect(entries.length, 1);
    });

    test('maps display fields truthfully', () {
      final result = DictionarySearchResult(
          searchTerm: 'わかる', entries: [_entry()], bestLength: 3);
      final de =
          (buildYomitanTermEntriesResponse(result, 0)['dictionaryEntries']
                  as List)
              .first as Map<String, dynamic>;

      expect(de['type'], 'term');
      final hw = (de['headwords'] as List).first as Map<String, dynamic>;
      expect(hw['term'], '分かる');
      expect(hw['reading'], 'わかる');
      expect(hw['wordClasses'], ['v5', 'vi']);
      final src = (hw['sources'] as List).first as Map<String, dynamic>;
      expect(src['deinflectedText'], 'わかる');
      expect(src['matchType'], 'exact');

      final def = (de['definitions'] as List).first as Map<String, dynamic>;
      expect(def['dictionary'], 'Jitendex');
      expect(def['entries'], isA<List>());

      final freq = (de['frequencies'] as List).first as Map<String, dynamic>;
      expect(freq['frequency'], 1234);
      expect(freq['displayValue'], '1234');
    });

    test('fills internal fields with sane defaults', () {
      final result = DictionarySearchResult(
          searchTerm: 'わかる', entries: [_entry()], bestLength: 3);
      final de =
          (buildYomitanTermEntriesResponse(result, 0)['dictionaryEntries']
                  as List)
              .first as Map<String, dynamic>;

      expect(de['isPrimary'], true);
      expect(de['score'], 0);
      final def = (de['definitions'] as List).first as Map<String, dynamic>;
      expect(def['sequences'], <int>[]);
      expect(def['tags'], <dynamic>[]);
    });

    test('plain-text meaning becomes a string entry, not parsed', () {
      final result = DictionarySearchResult(
          searchTerm: 'x',
          entries: [_entry(meaning: 'to understand')],
          bestLength: 1);
      final def =
          ((buildYomitanTermEntriesResponse(result, 0)['dictionaryEntries']
                  as List)
              .first as Map<String, dynamic>)['definitions'] as List;
      expect((def.first as Map)['entries'], ['to understand']);
    });

    test('null result yields empty dictionaryEntries', () {
      final out = buildYomitanTermEntriesResponse(null, 3);
      expect(out['index'], 3);
      expect(out['dictionaryEntries'], <dynamic>[]);
    });
  });
}
