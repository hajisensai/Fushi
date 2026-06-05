import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  test('LapisPreset defaults == LapisNoteType.defaultFieldMappings', () {
    final noteType =
        AnkiNoteType(id: 1, name: 'Lapis', fields: LapisNoteType.fields);
    final mappings = LapisPreset.applyDefaults(noteType, {});
    for (final entry in LapisNoteType.defaultFieldMappings.entries) {
      expect(mappings[entry.key], entry.value);
    }
    expect(mappings.containsKey('SentenceFurigana'), isFalse);
    expect(mappings.containsKey('Hint'), isFalse);
  });

  test('matches() recognises the official Lapis note type', () {
    final noteType =
        AnkiNoteType(id: 1, name: 'Lapis', fields: LapisNoteType.fields);
    expect(LapisPreset.matches(noteType), isTrue);
  });

  test('existing user mappings are preserved over defaults', () {
    final noteType =
        AnkiNoteType(id: 1, name: 'Lapis', fields: LapisNoteType.fields);
    final result =
        LapisPreset.applyDefaults(noteType, {'Expression': '{reading}'});
    expect(result['Expression'], '{reading}');
  });
}
