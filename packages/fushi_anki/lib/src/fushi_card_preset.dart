import 'anki_models.dart';
import 'fushi_card_fields.dart';
import 'fushi_card_note_type.dart';

/// 「Fushi 卡片」导出到 Anki 后作为制卡目标时的预设。
///
/// 2026-10-29 之前 Fushi 卡片与 Lapis 同名字段，导出的笔记类型会被 Lapis 预设认领；改名后
/// （[FushiCardFields]）新导出的笔记类型字段是 `Term` / `Media` / `Source` …，Lapis 预设认不出，
/// 只剩按字段名猜的兜底（读音 / 音频 / 画面 / 来源 / 词频排序大多猜不到）。本预设按名字或新字段组合
/// 认出它，给出与内置相同的默认映射。旧名导出的副本仍由 Lapis 预设认领（映射值相同）。
abstract final class FushiCardPreset {
  static const String _nameKeyword = 'fushi card';

  /// 新字段名里 Fushi 卡片特有的组合（`MainDefinition` / `Sentence` 与 Lapis 共有）。
  static const List<String> signatureFields = <String>[
    FushiCardFields.term,
    FushiCardFields.termReading,
    'MainDefinition',
    'Sentence',
  ];

  static bool matches(AnkiNoteType noteType) {
    final Set<String> fields = noteType.fields.toSet();
    return noteType.name.toLowerCase().contains(_nameKeyword) ||
        signatureFields.every(fields.contains);
  }

  /// [noteType] 里能认出的字段的默认映射。字段还是旧名（旧导出）时按别名对上同一个占位符。
  static Map<String, String> defaultMappings(AnkiNoteType noteType) {
    final Set<String> fields = noteType.fields.toSet();
    return <String, String>{
      for (final MapEntry<String, String> e in FushiCardFields.alignToFields(
        FushiCardNoteType.defaultFieldMappings,
        fields,
      ).entries)
        if (fields.contains(e.key)) e.key: e.value,
    };
  }
}
