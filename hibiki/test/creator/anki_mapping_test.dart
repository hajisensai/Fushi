import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/src/language/implementations/japanese_language.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default Japanese mapping auto-generates term audio', () {
    final mapping = AnkiMapping.defaultMapping(
      language: JapaneseLanguage.instance,
      order: 0,
    );

    expect(
      mapping.getAutoFieldEnhancementName(field: AudioField.instance),
      LocalAudioEnhancement.key,
    );
  });

  test('auto mapping recognizes Chinese frequency field names', () {
    expect(
      AnkiHandlebar.autoMapFields(['词频']),
      {'词频': AnkiHandlebar.frequencyHarmonicRank},
    );
    expect(
      AnkiHandlebar.autoMapFields(['频率']),
      {'频率': AnkiHandlebar.frequencyHarmonicRank},
    );
  });

  test('frequency handlebars resolve rank and HTML separately', () {
    final mapping = AnkiMapping.defaultMapping(
      language: JapaneseLanguage.instance,
      order: 0,
    );
    final values = CreatorFieldValues(
      textValues: {FrequencyField.instance: '1500'},
      extraValues: {
        FrequencyField.frequencyRankExtraKey: '1500',
        FrequencyField.frequenciesHtmlExtraKey:
            '<ul style="text-align: left;"><li>Freq: 1500</li></ul>',
      },
    );

    expect(
      AnkiHandlebar.resolveFieldMappings(
        ankiFieldNames: ['Frequency', 'FreqSort'],
        fieldMappings: {
          'Frequency': AnkiHandlebar.frequencies,
          'FreqSort': AnkiHandlebar.frequencyHarmonicRank,
        },
        creatorFieldValues: values,
        exportedImages: {},
        exportedAudio: {},
        mapping: mapping,
      ),
      [
        '<ul style="text-align: left;"><li>Freq: 1500</li></ul>',
        '1500',
      ],
    );
  });
}
