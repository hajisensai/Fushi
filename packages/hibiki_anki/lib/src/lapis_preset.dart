import 'anki_models.dart';

class LapisPreset {
  static const _defaults = {
    'Expression': '{expression}',
    'ExpressionFurigana': '{furigana-plain}',
    'ExpressionReading': '{reading}',
    'ExpressionAudio': '{audio}',
    'SelectionText': '{popup-selection-text}',
    'MainDefinition': '{glossary-first}',
    'Sentence': '{sentence}',
    'SentenceAudio': '{sasayaki-audio}',
    'Picture': '{book-cover}',
    'Glossary': '{glossary}',
    'PitchPosition': '{pitch-accent-positions}',
    'PitchCategories': '{pitch-accent-categories}',
    'Frequency': '{frequencies}',
    'FreqSort': '{frequency-harmonic-rank}',
    'MiscInfo': '{document-title}',
    'IsWordAndSentenceCard': 'x',
  };

  static bool matches(AnkiNoteType noteType) {
    final fields = noteType.fields.toSet();
    return noteType.name.toLowerCase().contains('lapis') ||
        ['Expression', 'MainDefinition', 'Sentence'].every(fields.contains);
  }

  static Map<String, String> defaultMappings(AnkiNoteType noteType) => {
        for (final f in noteType.fields)
          if (_defaults.containsKey(f)) f: _defaults[f]!,
      };

  static Map<String, String> applyDefaults(
    AnkiNoteType noteType,
    Map<String, String> currentMappings,
  ) {
    if (!matches(noteType)) return currentMappings;
    return {...defaultMappings(noteType), ...currentMappings};
  }
}
