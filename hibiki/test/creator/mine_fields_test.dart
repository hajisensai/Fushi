import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/src/language/implementations/japanese_language.dart';

void main() {
  test('mine fields carry all popup card values into creator context', () {
    final values = CreatorFieldValues.fromMineFields(
      fields: {
        'expression': '山',
        'reading': 'やま',
        'glossary': '<div>mountain</div>',
        'furiganaPlain': ' 山[やま]',
        'freqHarmonicRank': '1500',
        'frequenciesHtml': '<ul><li>Freq: 1500</li></ul>',
        'pitchPositions': '<ol><li>[0]</li></ol>',
        'pitchCategories': '<ol><li>heiban</li></ol>',
        'popupSelectionText': '山',
        'singleGlossaries': '{"Dict":"mountain"}',
        'selectedDictionary': 'Dict',
      },
    );

    expect(values.textValues[TermField.instance], '山');
    expect(values.textValues[ReadingField.instance], 'やま');
    expect(values.textValues[MeaningField.instance], '<div>mountain</div>');
    expect(values.textValues[FuriganaField.instance], ' 山[やま]');
    expect(values.textValues[FrequencyField.instance], '1500');
    expect(
        values.textValues[PitchAccentField.instance], '<ol><li>[0]</li></ol>');
    expect(values.textValues[ClozeInsideField.instance], '山');
    expect(values.extraValues['singleGlossaries'], '{"Dict":"mountain"}');
    expect(values.extraValues['selectedDictionary'], 'Dict');
    expect(values.extraValues[FrequencyField.frequencyRankExtraKey], '1500');
    expect(values.extraValues[FrequencyField.frequenciesHtmlExtraKey],
        '<ul><li>Freq: 1500</li></ul>');
    expect(values.extraValues[PitchAccentField.pitchPositionsExtraKey],
        '<ol><li>[0]</li></ol>');
    expect(values.extraValues[PitchAccentField.pitchCategoriesExtraKey],
        '<ol><li>heiban</li></ol>');
    expect(
        values.extraValues[CreatorFieldValues.popupSelectionTextExtraKey], '山');
  });

  test('mine fields keep reader sentence cloze separate from popup selection',
      () {
    final values = CreatorFieldValues.fromMineFields(
      fields: {
        'expression': '山',
        'popupSelectionText': '山',
      },
      sentence: '高い山を見る。',
      clozeBefore: '高い',
      clozeInside: '山',
      clozeAfter: 'を見る。',
      usePopupSelectionAsClozeInside: false,
    );

    expect(values.textValues[SentenceField.instance], '高い山を見る。');
    expect(values.textValues[ClozeBeforeField.instance], '高い');
    expect(values.textValues[ClozeInsideField.instance], '山');
    expect(values.textValues[ClozeAfterField.instance], 'を見る。');
    expect(
        values.extraValues[CreatorFieldValues.popupSelectionTextExtraKey], '山');
  });

  test('mine-only pitch handlebars resolve positions and categories separately',
      () {
    final mapping = AnkiMapping.defaultMapping(
      language: JapaneseLanguage.instance,
      order: 0,
    );
    final values = CreatorFieldValues.fromMineFields(
      fields: {
        'pitchPositions': '<ol><li>[0]</li></ol>',
        'pitchCategories': '<ol><li>heiban</li></ol>',
      },
    );

    expect(
      AnkiHandlebar.resolveFieldMappings(
        ankiFieldNames: ['PitchPosition', 'PitchCategories'],
        fieldMappings: {
          'PitchPosition': AnkiHandlebar.pitchAccentPositions,
          'PitchCategories': AnkiHandlebar.pitchAccentCategories,
        },
        creatorFieldValues: values,
        exportedImages: {},
        exportedAudio: {},
        mapping: mapping,
      ),
      ['<ol><li>[0]</li></ol>', '<ol><li>heiban</li></ol>'],
    );
  });
}
