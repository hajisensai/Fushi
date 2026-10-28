import 'anki_models.dart';
import 'lapis_note_type.dart';

/// Lapis / Kiku 笔记类型预设（Kiku 字段名与 Lapis 相同）。
///
/// 只负责「认出它」与「它的默认映射」；分派（选卡优先级、补默认映射）统一走
/// `NoteTypePresets`（`note_type_preset.dart`）。
abstract final class LapisPreset {
  static const Map<String, String> _defaults =
      LapisNoteType.defaultFieldMappings;

  static bool matches(AnkiNoteType noteType) {
    final Set<String> fields = noteType.fields.toSet();
    return noteType.name.toLowerCase().contains('lapis') ||
        <String>[
          'Expression',
          'MainDefinition',
          'Sentence',
        ].every(fields.contains);
  }

  static Map<String, String> defaultMappings(AnkiNoteType noteType) =>
      <String, String>{
        for (final String f in noteType.fields)
          if (_defaults.containsKey(f)) f: _defaults[f]!,
      };
}
