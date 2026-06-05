import 'anki_models.dart';
import 'lapis_note_type.dart';

class LapisPreset {
  static const _defaults = LapisNoteType.defaultFieldMappings;

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
