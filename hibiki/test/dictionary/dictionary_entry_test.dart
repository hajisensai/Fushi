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

    test('isEmpty is true when word, reading, meaning all empty', () {
      expect(DictionaryEntry().isEmpty, isTrue);
      expect(DictionaryEntry(word: '猫').isEmpty, isFalse);
      expect(DictionaryEntry(reading: 'ねこ').isEmpty, isFalse);
      expect(DictionaryEntry(meaning: 'cat').isEmpty, isFalse);
    });

    test('wordLength for empty string is 0', () {
      expect(DictionaryEntry().wordLength, 0);
    });

    test('wordLength returns String.length (UTF-16 code units)', () {
      // 𠮷 is a surrogate pair (2 code units), 野 and 家 are 1 each → total 4
      final entry = DictionaryEntry(word: '𠮷野家');
      expect(entry.wordLength, 4);
    });

    test('toJson excludes id and workingArea', () {
      final entry = DictionaryEntry(word: '山', id: 42);
      entry.workingArea['temp'] = true;
      final json = entry.toJson();
      final map = jsonDecode(json) as Map<String, dynamic>;

      expect(map.containsKey('id'), isFalse);
      expect(map.containsKey('workingArea'), isFalse);
    });

    test('fromJson with numeric extra coerces to string', () {
      final json = jsonEncode({
        'word': '猫',
        'extra': 123,
      });
      final entry = DictionaryEntry.fromJson(json);
      expect(entry.extra, '123');
    });

    test('equality ignores dictionaryName, extra, popularity', () {
      final a = DictionaryEntry(
        word: '猫',
        reading: 'ねこ',
        meaning: 'cat',
        dictionaryName: 'Dict1',
        extra: '{"a":1}',
        popularity: 5.0,
      );
      final b = DictionaryEntry(
        word: '猫',
        reading: 'ねこ',
        meaning: 'cat',
        dictionaryName: 'Dict2',
        extra: '{"b":2}',
        popularity: 10.0,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('toString contains word, reading, meaning', () {
      final entry = DictionaryEntry(
        word: '猫',
        reading: 'ねこ',
        meaning: 'cat',
      );
      final str = entry.toString();
      expect(str, contains('猫'));
      expect(str, contains('ねこ'));
      expect(str, contains('cat'));
    });

    test('fromJson with very long meaning field round-trips', () {
      final longMeaning = 'a' * 10000;
      final entry = DictionaryEntry(word: '長', meaning: longMeaning);
      final restored = DictionaryEntry.fromJson(entry.toJson());
      expect(restored.meaning.length, 10000);
    });
  });
}
