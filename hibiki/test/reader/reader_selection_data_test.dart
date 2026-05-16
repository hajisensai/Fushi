import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';

void main() {
  group('ReaderSelectionData.fromJson', () {
    test('parses full JSON with all fields', () {
      final json = <String, dynamic>{
        'text': '猫',
        'sentence': '吾輩は猫である。',
        'rect': {'x': 10.0, 'y': 20.0, 'width': 100.0, 'height': 30.0},
        'normalizedOffset': 3,
        'normalizedLength': 1,
        'sentenceOffset': 5,
        'sentenceNormalizedOffset': 10,
        'sentenceNormalizedLength': 8,
      };

      final data = ReaderSelectionData.fromJson(json);

      expect(data.text, '猫');
      expect(data.sentence, '吾輩は猫である。');
      expect(data.rect, isNotNull);
      expect(data.rect!['x'], 10.0);
      expect(data.rect!['y'], 20.0);
      expect(data.rect!['width'], 100.0);
      expect(data.rect!['height'], 30.0);
      expect(data.normalizedOffset, 3);
      expect(data.normalizedLength, 1);
      expect(data.sentenceOffset, 5);
      expect(data.sentenceNormalizedOffset, 10);
      expect(data.sentenceNormalizedLength, 8);
    });

    test('missing optional fields default correctly', () {
      final json = <String, dynamic>{
        'text': 'hello',
        'sentence': 'hello world',
      };

      final data = ReaderSelectionData.fromJson(json);

      expect(data.text, 'hello');
      expect(data.sentence, 'hello world');
      expect(data.rect, isNull);
      expect(data.normalizedOffset, isNull);
      expect(data.normalizedLength, isNull);
      expect(data.sentenceOffset, 0);
      expect(data.sentenceNormalizedOffset, isNull);
      expect(data.sentenceNormalizedLength, isNull);
    });

    test('empty JSON defaults text and sentence to empty strings', () {
      final data = ReaderSelectionData.fromJson(<String, dynamic>{});

      expect(data.text, '');
      expect(data.sentence, '');
    });

    test('rect with int values converts to double', () {
      final json = <String, dynamic>{
        'text': 't',
        'sentence': 's',
        'rect': {'x': 1, 'y': 2, 'width': 3, 'height': 4},
      };

      final data = ReaderSelectionData.fromJson(json);

      expect(data.rect!['x'], 1.0);
      expect(data.rect!['y'], 2.0);
      expect(data.rect!['width'], 3.0);
      expect(data.rect!['height'], 4.0);
    });

    test('rect with null values defaults to zero', () {
      final json = <String, dynamic>{
        'text': 't',
        'sentence': 's',
        'rect': <String, dynamic>{},
      };

      final data = ReaderSelectionData.fromJson(json);

      expect(data.rect!['x'], 0.0);
      expect(data.rect!['y'], 0.0);
      expect(data.rect!['width'], 0.0);
      expect(data.rect!['height'], 0.0);
    });

    test('non-Map rect is treated as null', () {
      final json = <String, dynamic>{
        'text': 't',
        'sentence': 's',
        'rect': 'invalid',
      };

      final data = ReaderSelectionData.fromJson(json);
      expect(data.rect, isNull);
    });

    test('numeric fields accept int values', () {
      final json = <String, dynamic>{
        'text': 't',
        'sentence': 's',
        'normalizedOffset': 5,
        'normalizedLength': 10,
        'sentenceOffset': 3,
      };

      final data = ReaderSelectionData.fromJson(json);
      expect(data.normalizedOffset, 5);
      expect(data.normalizedLength, 10);
      expect(data.sentenceOffset, 3);
    });
  });

  group('ReaderSelectionData constructor', () {
    test('stores all fields', () {
      final data = ReaderSelectionData(
        text: '食べる',
        sentence: '猫が魚を食べる',
        normalizedOffset: 4,
        normalizedLength: 3,
        sentenceOffset: 2,
      );

      expect(data.text, '食べる');
      expect(data.sentence, '猫が魚を食べる');
      expect(data.normalizedOffset, 4);
      expect(data.normalizedLength, 3);
      expect(data.sentenceOffset, 2);
    });
  });
}
