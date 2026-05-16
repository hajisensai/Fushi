import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/creator/fields/pitch_accent_field.dart';

void main() {
  group('PitchSvg.hiraToMora', () {
    test('simple hiragana splits into single characters', () {
      expect(PitchSvg.hiraToMora('はし'), ['は', 'し']);
    });

    test('small kana combiners are grouped with preceding char', () {
      expect(PitchSvg.hiraToMora('しゅんか'), ['しゅ', 'ん', 'か']);
    });

    test('complex word with multiple combiners', () {
      expect(
        PitchSvg.hiraToMora('しゅんかしゅうとう'),
        ['しゅ', 'ん', 'か', 'しゅ', 'う', 'と', 'う'],
      );
    });

    test('katakana small kana also combine', () {
      expect(PitchSvg.hiraToMora('キャット'), ['キャ', 'ッ', 'ト']);
    });

    test('empty string returns empty list', () {
      expect(PitchSvg.hiraToMora(''), isEmpty);
    });

    test('single character returns single mora', () {
      expect(PitchSvg.hiraToMora('あ'), ['あ']);
    });
  });

  group('PitchSvg.pitchValueToPatt', () {
    test('heiban (0) produces LHH...H pattern', () {
      expect(PitchSvg.pitchValueToPatt('はし', 0), 'LHH');
    });

    test('atamadaka (1) produces HLL...L pattern', () {
      expect(PitchSvg.pitchValueToPatt('はし', 1), 'HLL');
    });

    test('nakadaka (2 for 2-mora word) produces LHL', () {
      expect(PitchSvg.pitchValueToPatt('はし', 2), 'LHL');
    });

    test('longer word with pitch 3', () {
      // 3-mora word: ことば, pitch 3 = odaka = LHHL
      expect(PitchSvg.pitchValueToPatt('ことば', 3), 'LHHL');
    });

    test('empty reading returns empty pattern', () {
      expect(PitchSvg.pitchValueToPatt('', 0), '');
    });

    test('word with combiners counts morae correctly', () {
      // しゅんか = 3 morae [しゅ, ん, か]
      final patt = PitchSvg.pitchValueToPatt('しゅんか', 0);
      // heiban: LH * moraCount = LHHH
      expect(patt, 'LHHH');
    });
  });

  group('PitchSvg.pitchSvg', () {
    test('produces valid SVG string', () {
      final svg = PitchSvg.pitchSvg('はし', 'LHL');

      expect(svg, startsWith('<svg'));
      expect(svg, endsWith('</svg>'));
      expect(svg, contains('circle'));
      expect(svg, contains('text'));
    });

    test('contains mora characters as text elements', () {
      final svg = PitchSvg.pitchSvg('はし', 'LHL');

      expect(svg, contains('>は<'));
      expect(svg, contains('>し<'));
    });
  });

  group('PitchAccentField.getAllHtmlPitch', () {
    test('empty positions returns empty string', () {
      final result = PitchAccentField.getAllHtmlPitch(
        reading: 'はし',
        positions: [],
      );

      expect(result, isEmpty);
    });

    test('empty reading returns empty string', () {
      final result = PitchAccentField.getAllHtmlPitch(
        reading: '',
        positions: [1],
      );

      expect(result, isEmpty);
    });

    test('single position generates one SVG', () {
      final result = PitchAccentField.getAllHtmlPitch(
        reading: 'はし',
        positions: [1],
      );

      expect(result, contains('<svg'));
      expect(result.split('<svg').length, 2); // one SVG
    });

    test('duplicate positions are deduplicated', () {
      final result = PitchAccentField.getAllHtmlPitch(
        reading: 'はし',
        positions: [1, 1, 1],
      );

      expect(result.split('<svg').length, 2); // still one SVG
    });

    test('multiple distinct positions generate multiple SVGs', () {
      final result = PitchAccentField.getAllHtmlPitch(
        reading: 'はし',
        positions: [0, 1],
      );

      expect(result.split('<svg').length, 3); // two SVGs
    });
  });

  group('PitchAccentField.extraValuesFromMineFields', () {
    test('extracts pitch positions and categories from mine fields', () {
      final fields = {
        'pitchPositions': '<svg>...</svg>',
        'pitchCategories': 'heiban',
      };

      final result = PitchAccentField.extraValuesFromMineFields(fields);

      expect(result[PitchAccentField.pitchPositionsExtraKey], '<svg>...</svg>');
      expect(result[PitchAccentField.pitchCategoriesExtraKey], 'heiban');
    });

    test('missing keys default to empty strings', () {
      final fields = <String, String>{};

      final result = PitchAccentField.extraValuesFromMineFields(fields);

      expect(result[PitchAccentField.pitchPositionsExtraKey], '');
      expect(result[PitchAccentField.pitchCategoriesExtraKey], '');
    });
  });
}
