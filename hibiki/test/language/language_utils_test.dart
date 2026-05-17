import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

void main() {
  group('RegExpExtension.allMatchesWithSep', () {
    test('splits and preserves delimiters', () {
      final re = RegExp(r'\d+');
      final result = re.allMatchesWithSep('abc123def456ghi');
      expect(result, ['abc', '123', 'def', '456', 'ghi']);
    });

    test('empty string returns single empty element', () {
      final re = RegExp(r'\d+');
      final result = re.allMatchesWithSep('');
      expect(result, ['']);
    });

    test('no match returns original text', () {
      final re = RegExp(r'\d+');
      final result = re.allMatchesWithSep('abcdef');
      expect(result, ['abcdef']);
    });

    test('delimiter at start produces leading empty string', () {
      final re = RegExp(r'\d+');
      final result = re.allMatchesWithSep('123abc');
      expect(result, ['', '123', 'abc']);
    });

    test('delimiter at end produces trailing empty string', () {
      final re = RegExp(r'\d+');
      final result = re.allMatchesWithSep('abc123');
      expect(result, ['abc', '123', '']);
    });

    test('consecutive delimiters have empty strings between', () {
      final re = RegExp(r'[,]');
      final result = re.allMatchesWithSep('a,,b');
      expect(result, ['a', ',', '', ',', 'b']);
    });
  });

  group('StringExtension.splitWithDelim', () {
    test('delegates to allMatchesWithSep', () {
      final result = 'hello123world'.splitWithDelim(RegExp(r'\d+'));
      expect(result, ['hello', '123', 'world']);
    });
  });

  group('FuriganaDistributionGroup', () {
    test('stores fields correctly', () {
      final g = FuriganaDistributionGroup(
        isKana: true,
        text: 'あ',
        textNormalized: 'あ',
      );
      expect(g.isKana, isTrue);
      expect(g.text, 'あ');
      expect(g.textNormalized, 'あ');
    });

    test('fields are mutable', () {
      final g = FuriganaDistributionGroup(
        isKana: false,
        text: '',
        textNormalized: null,
      );
      g.text = '猫';
      g.isKana = true;
      expect(g.text, '猫');
      expect(g.isKana, isTrue);
    });
  });

  group('LanguageUtils.isCodePointInRange', () {
    test('returns true for code point within range', () {
      expect(
          LanguageUtils.isCodePointInRange(0x3041, [0x3040, 0x309f]), isTrue);
    });

    test('returns true for code point at range boundaries', () {
      expect(
          LanguageUtils.isCodePointInRange(0x3040, [0x3040, 0x309f]), isTrue);
      expect(
          LanguageUtils.isCodePointInRange(0x309f, [0x3040, 0x309f]), isTrue);
    });

    test('returns false for code point outside range', () {
      expect(
          LanguageUtils.isCodePointInRange(0x3000, [0x3040, 0x309f]), isFalse);
      expect(
          LanguageUtils.isCodePointInRange(0x30a0, [0x3040, 0x309f]), isFalse);
    });
  });

  group('LanguageUtils.isCodePointInRanges', () {
    test('returns true when in any range', () {
      // Katakana range
      expect(
        LanguageUtils.isCodePointInRanges(
          0x30a1,
          [
            [0x3040, 0x309f],
            [0x30a0, 0x30ff]
          ],
        ),
        isTrue,
      );
    });

    test('returns false when in no range', () {
      expect(
        LanguageUtils.isCodePointInRanges(
          0x4e00,
          [
            [0x3040, 0x309f],
            [0x30a0, 0x30ff]
          ],
        ),
        isFalse,
      );
    });
  });

  group('LanguageUtils.isCodePointKana', () {
    test('hiragana is kana', () {
      expect(LanguageUtils.isCodePointKana('あ'.codeUnitAt(0)), isTrue);
      expect(LanguageUtils.isCodePointKana('ん'.codeUnitAt(0)), isTrue);
    });

    test('katakana is kana', () {
      expect(LanguageUtils.isCodePointKana('ア'.codeUnitAt(0)), isTrue);
      expect(LanguageUtils.isCodePointKana('ン'.codeUnitAt(0)), isTrue);
    });

    test('kanji is not kana', () {
      expect(LanguageUtils.isCodePointKana('猫'.codeUnitAt(0)), isFalse);
    });

    test('ASCII is not kana', () {
      expect(LanguageUtils.isCodePointKana('a'.codeUnitAt(0)), isFalse);
    });
  });

  group('LanguageUtils.getFuriganaKanaSegments', () {
    test('identical text and reading produce single segment with empty ruby',
        () {
      final segments =
          LanguageUtils.getFuriganaKanaSegments(text: 'あいう', reading: 'あいう');
      expect(segments, hasLength(1));
      expect(segments[0].text, 'あいう');
      expect(segments[0].ruby, '');
    });

    test('different text and reading produce segment with ruby', () {
      final segments =
          LanguageUtils.getFuriganaKanaSegments(text: 'アイ', reading: 'あい');
      expect(segments, hasLength(1));
      expect(segments[0].text, 'アイ');
      expect(segments[0].ruby, 'あい');
    });
  });
}
