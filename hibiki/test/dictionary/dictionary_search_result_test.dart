import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

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

    test('round-trip preserves entry extra and popularity', () {
      final result = DictionarySearchResult(
        searchTerm: '猫',
        entries: [
          DictionaryEntry(
            word: '猫',
            reading: 'ねこ',
            meaning: 'cat',
            extra:
                '{"frequencies":[{"dictName":"BCCWJ","values":[{"value":500,"display":"500"}]}]}',
            popularity: 42.5,
          ),
        ],
      );

      final restored = DictionarySearchResult.fromJson(result.toJson());
      expect(restored.entries.single.extra, contains('BCCWJ'));
      expect(restored.entries.single.popularity, 42.5);
    });

    test('bestLength reflects longest matching prefix', () {
      final result = DictionarySearchResult(
        searchTerm: '食べられる',
        bestLength: 5,
        entries: [
          DictionaryEntry(word: '食べられる', meaning: 'can eat'),
          DictionaryEntry(word: '食べる', meaning: 'to eat'),
        ],
      );

      final restored = DictionarySearchResult.fromJson(result.toJson());
      expect(restored.bestLength, 5);
      expect(restored.entries[0].wordLength, 5);
      expect(restored.entries[1].wordLength, 3);
    });

    test('round-trip with entries from multiple dictionaries', () {
      final result = DictionarySearchResult(
        searchTerm: '走る',
        entries: [
          DictionaryEntry(
            word: '走る',
            reading: 'はしる',
            meaning: 'to run',
            dictionaryName: '明鏡国語',
          ),
          DictionaryEntry(
            word: '走る',
            reading: 'はしる',
            meaning: 'to run; to dash',
            dictionaryName: '大辞泉',
          ),
          DictionaryEntry(
            word: '走る',
            reading: 'はしる',
            meaning: 'courir',
            dictionaryName: 'JA-FR',
          ),
        ],
      );

      final restored = DictionarySearchResult.fromJson(result.toJson());
      expect(restored.entries, hasLength(3));
      final dictNames = restored.entries.map((e) => e.dictionaryName).toList();
      expect(dictNames, ['明鏡国語', '大辞泉', 'JA-FR']);
    });

    test('scrollPosition is mutable and preserved', () {
      final result = DictionarySearchResult(searchTerm: 'test');
      expect(result.scrollPosition, 0);

      result.scrollPosition = 150;
      final restored = DictionarySearchResult.fromJson(result.toJson());
      expect(restored.scrollPosition, 150);
    });
  });
}
