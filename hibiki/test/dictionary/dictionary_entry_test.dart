import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

void main() {
  group('DictionaryEntry', () {
    test('default construction has empty fields', () {
      final entry = DictionaryEntry();

      expect(entry.word, '');
      expect(entry.reading, '');
      expect(entry.meaning, '');
      expect(entry.extra, '');
      expect(entry.dictionaryName, '');
      expect(entry.popularity, 0);
      expect(entry.id, isNull);
    });

    test('wordLength returns length of word', () {
      final entry = DictionaryEntry(word: '食べる');

      expect(entry.wordLength, 3);
    });

    test('toJson produces valid JSON with all fields', () {
      final entry = DictionaryEntry(
        dictionaryName: 'JMdict',
        word: '猫',
        reading: 'ねこ',
        meaning: 'cat',
        extra: '{"freq":1000}',
        popularity: 5.0,
      );

      final json = entry.toJson();
      final map = jsonDecode(json) as Map<String, dynamic>;

      expect(map['dictionaryName'], 'JMdict');
      expect(map['word'], '猫');
      expect(map['reading'], 'ねこ');
      expect(map['meaning'], 'cat');
      expect(map['extra'], '{"freq":1000}');
      expect(map['popularity'], 5.0);
    });

    test('fromJson round-trips correctly', () {
      final original = DictionaryEntry(
        dictionaryName: 'Dict',
        word: '犬',
        reading: 'いぬ',
        meaning: 'dog',
        extra: '{}',
        popularity: 3.5,
      );

      final restored = DictionaryEntry.fromJson(original.toJson());

      expect(restored.word, original.word);
      expect(restored.reading, original.reading);
      expect(restored.meaning, original.meaning);
      expect(restored.dictionaryName, original.dictionaryName);
      expect(restored.popularity, original.popularity);
    });

    test('fromJson handles missing fields gracefully', () {
      final json = jsonEncode({'word': '山'});

      final entry = DictionaryEntry.fromJson(json);

      expect(entry.word, '山');
      expect(entry.reading, '');
      expect(entry.meaning, '');
      expect(entry.dictionaryName, '');
    });

    test('equality based on word, reading, meaning', () {
      final a = DictionaryEntry(
        word: '猫',
        reading: 'ねこ',
        meaning: 'cat',
        dictionaryName: 'Dict1',
      );
      final b = DictionaryEntry(
        word: '猫',
        reading: 'ねこ',
        meaning: 'cat',
        dictionaryName: 'Dict2',
      );

      expect(a, equals(b));
    });

    test('different word means not equal', () {
      final a = DictionaryEntry(word: '猫', reading: 'ねこ', meaning: 'cat');
      final b = DictionaryEntry(word: '犬', reading: 'いぬ', meaning: 'dog');

      expect(a, isNot(equals(b)));
    });
  });
}
