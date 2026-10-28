import 'anki_models.dart';
import 'lapis_note_type.dart';
import 'note_type_default_mappings.dart';
import 'senren_preset.dart';

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

  /// Lapis / Kiku 或 Senren：有出厂预设的笔记类型。选卡时优先挑它们，换到它们时用预设
  /// 映射整体替换（而不是沿用上一个笔记类型的映射）。
  static bool hasPreset(AnkiNoteType noteType) =>
      matches(noteType) || SenrenPreset.matches(noteType);

  static Map<String, String> applyDefaults(
    AnkiNoteType noteType,
    Map<String, String> currentMappings,
  ) {
    if (!matches(noteType) && SenrenPreset.matches(noteType)) {
      return {...SenrenPreset.defaultMappings(noteType), ...currentMappings};
    }
    if (!matches(noteType)) {
      // 非 Lapis：现有映射覆盖到这个笔记类型就原样保留；否则（空表 / 属于别的笔记类型）
      // 补上按字段名推出的默认映射，不再留空表让每张卡都被当空卡拒收。
      if (mappingsCoverNoteType(currentMappings, noteType)) {
        return currentMappings;
      }
      return {...noteTypeDefaultMappings(noteType), ...currentMappings};
    }
    return {...defaultMappings(noteType), ...currentMappings};
  }
}
