import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/dictionary/dictionary_entry.dart';
import 'package:hibiki/src/dictionary/dictionary_search_result.dart';

void main() {
  group('DictionarySearchResult', () {
    test('round-trip serialization with entries', () {
      final result = DictionarySearchResult(
        searchTerm: '猫',
        bestLength: 1,
        scrollPosition: 42,
        entries: [
          DictionaryEntry(
            word: '猫',
            reading: 'ねこ',
            meaning: 'cat',
            dictionaryName: 'JMDict',
          ),
        ],
      );

      final json = result.toJson();
      final restored = DictionarySearchResult.fromJson(json);

      expect(restored.searchTerm, '猫');
      expect(restored.bestLength, 1);
      expect(restored.scrollPosition, 42);
      expect(restored.entries, hasLength(1));
      expect(restored.entries[0].word, '猫');
      expect(restored.entries[0].reading, 'ねこ');
    });

    test('round-trip with empty entries', () {
      final result = DictionarySearchResult(
        searchTerm: 'test',
        bestLength: 4,
      );

      final json = result.toJson();
      final restored = DictionarySearchResult.fromJson(json);

      expect(restored.searchTerm, 'test');
      expect(restored.entries, isEmpty);
      expect(restored.bestLength, 4);
      expect(restored.scrollPosition, 0);
    });

    test('fromJson handles missing optional fields', () {
      const json = '{"searchTerm":"hello"}';
      final result = DictionarySearchResult.fromJson(json);

      expect(result.searchTerm, 'hello');
      expect(result.bestLength, 0);
      expect(result.scrollPosition, 0);
      expect(result.entries, isEmpty);
    });

    test('round-trip with multiple entries', () {
      final result = DictionarySearchResult(
        searchTerm: '食べる',
        entries: [
          DictionaryEntry(
            word: '食べる',
            reading: 'たべる',
            meaning: 'to eat',
            dictionaryName: 'JMDict',
          ),
          DictionaryEntry(
            word: '食べる',
            reading: 'たべる',
            meaning: 'to live on',
            dictionaryName: 'Secondary',
          ),
        ],
      );

      final restored = DictionarySearchResult.fromJson(result.toJson());
      expect(restored.entries, hasLength(2));
      expect(restored.entries[1].dictionaryName, 'Secondary');
    });
  });
}
