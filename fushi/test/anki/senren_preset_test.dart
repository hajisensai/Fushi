import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

const List<String> _senrenFields = <String>[
  'word',
  'reading',
  'sentence',
  'sentenceFurigana',
  'sentenceTranslation',
  'sentenceCard',
  'audioCard',
  'notes',
  'selectionText',
  'definition',
  'wordAudio',
  'sentenceAudio',
  'picture',
  'glossary',
  'pitchAccents',
  'pitchPositions',
  'pitchCategories',
  'frequencies',
  'freqSort',
  'miscInfo',
  'dictionaryPreference',
];

void main() {
  final AnkiNoteType senren = AnkiNoteType(
    id: 7,
    name: 'Senren',
    fields: _senrenFields,
  );

  test('matches by name, and by field names for a renamed copy', () {
    expect(SenrenPreset.matches(senren), isTrue);
    expect(
      SenrenPreset.matches(
        AnkiNoteType(id: 8, name: 'My vocab', fields: _senrenFields),
      ),
      isTrue,
    );
    expect(
      SenrenPreset.matches(
        AnkiNoteType(id: 9, name: 'Basic', fields: ['Front', 'Back']),
      ),
      isFalse,
    );
    expect(
      LapisPreset.matches(senren),
      isFalse,
      reason: 'Senren must not be claimed by the Lapis matcher',
    );
  });

  test('applyDefaults autofills every Senren field that has a placeholder', () {
    final Map<String, String> m = LapisPreset.applyDefaults(senren, {});
    expect(m, SenrenPreset.defaultFieldMappings);
    expect(m['word'], '{expression}');
    expect(m['wordAudio'], '{audio}');
    expect(m['sentenceAudio'], '{sentence-audio}');
    expect(m['picture'], '{card-image}');
    expect(m['pitchPositions'], '{pitch-accent-positions}');
    expect(m['freqSort'], '{frequency-harmonic-rank}');
    for (final String empty in <String>[
      'sentenceFurigana',
      'sentenceTranslation',
      'sentenceCard',
      'audioCard',
      'notes',
      'dictionaryPreference',
    ]) {
      expect(m.containsKey(empty), isFalse, reason: empty);
    }
  });

  test('user mappings win over the preset', () {
    final Map<String, String> m = LapisPreset.applyDefaults(senren, {
      'word': '{reading}',
    });
    expect(m['word'], '{reading}');
    expect(m['wordAudio'], '{audio}');
  });

  test('hasPreset covers Lapis and Senren but not a plain note type', () {
    expect(LapisPreset.hasPreset(senren), isTrue);
    expect(
      LapisPreset.hasPreset(
        AnkiNoteType(id: 1, name: 'Lapis', fields: LapisNoteType.fields),
      ),
      isTrue,
    );
    expect(
      LapisPreset.hasPreset(
        AnkiNoteType(id: 2, name: 'Basic', fields: ['Front', 'Back']),
      ),
      isFalse,
    );
  });

  test('Lapis behaviour is unchanged', () {
    final AnkiNoteType lapis = AnkiNoteType(
      id: 1,
      name: 'Lapis',
      fields: LapisNoteType.fields,
    );
    expect(LapisPreset.applyDefaults(lapis, {})['Expression'], '{expression}');
    expect(SenrenPreset.matches(lapis), isFalse);
  });
}
