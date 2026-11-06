import 'package:collection/collection.dart';

import 'anki_models.dart';
import 'fushi_card_preset.dart';
import 'lapis_preset.dart';
import 'note_type_default_mappings.dart';
import 'senren_preset.dart';

/// 一个「有出厂预设的笔记类型」条目：怎么认出它、它的默认字段映射是什么。
///
/// 新增预设（另一套社区笔记类型）只在 [NoteTypePresets.all] 里加一条，选卡优先级、
/// 换笔记类型时的映射重置、默认映射补全都走同一张表分派，不再在各处写死名字判断。
final class NoteTypePreset {
  const NoteTypePreset({
    required this.id,
    required this.nameKeyword,
    required this.matches,
    required this.defaultMappings,
  });

  /// 稳定标识（日志 / 测试用）。
  final String id;

  /// 笔记类型名（小写）含此关键字即视为该预设。只在拿不到字段表、只剩一个持久化的
  /// 笔记类型名时（[NoteTypePresets.nameHasPreset]）单独使用。
  final String nameKeyword;

  /// 按名字或字段集合认出该预设。
  final bool Function(AnkiNoteType noteType) matches;

  /// 该预设对 [AnkiNoteType.fields] 中能认出的字段给出的默认映射。
  final Map<String, String> Function(AnkiNoteType noteType) defaultMappings;
}

/// 笔记类型预设注册表。[all] 的顺序就是优先级：靠前的先认领、选卡时先被选中。
abstract final class NoteTypePresets {
  static const NoteTypePreset lapis = NoteTypePreset(
    id: 'lapis',
    nameKeyword: 'lapis',
    matches: LapisPreset.matches,
    defaultMappings: LapisPreset.defaultMappings,
  );

  static const NoteTypePreset senren = NoteTypePreset(
    id: 'senren',
    nameKeyword: 'senren',
    matches: SenrenPreset.matches,
    defaultMappings: SenrenPreset.defaultMappings,
  );

  /// Fushi 卡片导出到 Anki 的笔记类型（新字段名；旧名副本先被 [lapis] 认领，映射值相同）。
  static const NoteTypePreset fushiCard = NoteTypePreset(
    id: 'fushi_card',
    nameKeyword: 'fushi card',
    matches: FushiCardPreset.matches,
    defaultMappings: FushiCardPreset.defaultMappings,
  );

  /// Lapis / Kiku 在前：保持「同时装了多套预设时默认选 Lapis」的既有行为。
  static const List<NoteTypePreset> all = <NoteTypePreset>[
    lapis,
    senren,
    fushiCard,
  ];

  /// [noteType] 对应的预设（按优先级第一个认领的）；没有则 `null`。
  static NoteTypePreset? of(AnkiNoteType noteType) =>
      all.firstWhereOrNull((NoteTypePreset p) => p.matches(noteType));

  static bool hasPreset(AnkiNoteType noteType) => of(noteType) != null;

  /// 只有笔记类型名（字段表不可得）时的判据。
  static bool nameHasPreset(String? noteTypeName) {
    final String? lower = noteTypeName?.toLowerCase();
    if (lower == null) return false;
    return all.any((NoteTypePreset p) => lower.contains(p.nameKeyword));
  }

  /// 没有显式选择时默认挑的笔记类型：按预设优先级，取第一个被该预设认领的笔记类型。
  static AnkiNoteType? preferred(List<AnkiNoteType> noteTypes) {
    for (final NoteTypePreset preset in all) {
      final AnkiNoteType? hit = noteTypes.firstWhereOrNull(preset.matches);
      if (hit != null) return hit;
    }
    return null;
  }

  /// 给 [noteType] 补默认映射，[currentMappings] 里的用户映射优先。
  ///
  /// 有预设：预设映射打底。无预设：现有映射覆盖到这个笔记类型就原样保留；否则（空表 /
  /// 属于别的笔记类型）补上按字段名推出的默认映射，不留空表让每张卡都被当空卡拒收。
  static Map<String, String> applyDefaults(
    AnkiNoteType noteType,
    Map<String, String> currentMappings,
  ) {
    final NoteTypePreset? preset = of(noteType);
    if (preset != null) {
      return <String, String>{
        ...preset.defaultMappings(noteType),
        ...currentMappings,
      };
    }
    if (mappingsCoverNoteType(currentMappings, noteType)) {
      return currentMappings;
    }
    return <String, String>{
      ...noteTypeDefaultMappings(noteType),
      ...currentMappings,
    };
  }
}
