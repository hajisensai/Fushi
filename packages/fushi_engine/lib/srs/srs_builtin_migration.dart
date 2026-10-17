/// Lapis → Fushi 卡片 一键迁移（复用「更改笔记类型」的存储层操作）。
///
/// 两种内置类型的字段键相同（Fushi 卡片 = Lapis 字段 + SentenceTranslation），所以预设映射
/// 按**字段键**直映：Fushi 卡片的内置字段 k ← Lapis 的内置字段 k（按内置 fieldId 认，用户给
/// Lapis 字段改过名也照样对上）。用户在 Lapis 上自己加的字段按名字（不区分大小写）找 Fushi
/// 卡片上同名的字段，找不到就不迁（预演里能看到）。扩展字段 SentenceTranslation 在 Lapis 里
/// 没有来源，留空。模板同理：Fushi 卡片唯一的模板 ← Lapis 的内置模板。
///
/// 复习历史随迁：[SrsNoteTypeStoreOps.changeNoteType] 给新卡记下前身，历史 = 自己 + 前身的日志。
library;

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';

/// 一次「换成内置类型」的预设映射（新 id → 旧 id，null = 留空）。
class SrsBuiltinMigrationMaps {
  const SrsBuiltinMigrationMaps({
    required this.fieldMap,
    required this.templateMap,
  });

  final Map<String, String?> fieldMap;
  final Map<String, String?> templateMap;
}

/// [from] → [to] 的预设映射：两边都是内置类型时按字段 / 模板键直映，其余按名字。
SrsBuiltinMigrationMaps srsBuiltinMigrationMaps(
  String profileUid,
  SrsNoteTypeView from,
  SrsNoteTypeView to,
) {
  final SrsBuiltinNoteType? fromDef = srsBuiltinNoteTypeForKey(
    profileUid,
    from.builtinKey,
  );
  final SrsBuiltinNoteType? toDef = srsBuiltinNoteTypeForKey(
    profileUid,
    to.builtinKey,
  );
  // 内置 fieldId → 字段键（模板同理）。
  Map<String, String> keysOf(Iterable<(String, String)> defs) =>
      <String, String>{for (final (String id, String key) in defs) id: key};
  final Map<String, String> fromFieldKey = fromDef == null
      ? const <String, String>{}
      : keysOf(<(String, String)>[
          for (final SrsFieldDef f in fromDef.fields) (f.id, f.name),
        ]);
  final Map<String, String> toFieldKey = toDef == null
      ? const <String, String>{}
      : keysOf(<(String, String)>[
          for (final SrsFieldDef f in toDef.fields) (f.id, f.name),
        ]);
  final Map<String, String> fromTplKey = fromDef == null
      ? const <String, String>{}
      : keysOf(<(String, String)>[
          for (final SrsTemplateDef t in fromDef.templates) (t.id, t.name),
        ]);
  final Map<String, String> toTplKey = toDef == null
      ? const <String, String>{}
      : keysOf(<(String, String)>[
          for (final SrsTemplateDef t in toDef.templates) (t.id, t.name),
        ]);

  Map<String, String?> mapItems(
    List<(String, String)> source,
    List<(String, String)> target,
    Map<String, String> sourceKey,
    Map<String, String> targetKey,
  ) {
    final Map<String, String?> out = <String, String?>{};
    final Set<String> used = <String>{};
    // 第一轮：内置键直映。
    for (final (String id, String _) in target) {
      final String? key = targetKey[id];
      if (key == null) continue;
      for (final (String sid, String _) in source) {
        if (!used.contains(sid) && sourceKey[sid] == key) {
          out[id] = sid;
          used.add(sid);
          break;
        }
      }
    }
    // 第二轮：剩下的按名字（不区分大小写）。
    for (final (String id, String name) in target) {
      if (out.containsKey(id)) continue;
      out[id] = null;
      for (final (String sid, String sname) in source) {
        if (!used.contains(sid) && sname.toLowerCase() == name.toLowerCase()) {
          out[id] = sid;
          used.add(sid);
          break;
        }
      }
    }
    return out;
  }

  final Map<String, String?> templateMap = mapItems(
    <(String, String)>[
      for (final SrsTemplateDef t in from.templates) (t.id, t.name),
    ],
    <(String, String)>[
      for (final SrsTemplateDef t in to.templates) (t.id, t.name),
    ],
    fromTplKey,
    toTplKey,
  );
  // 只有一个模板对一个模板、名字也对不上时（用户把 Lapis 的模板改了名），仍把唯一的卡
  // 接过去：复习历史比模板名重要。
  if (to.templates.length == 1 &&
      templateMap.values.every((String? v) => v == null) &&
      from.templates.isNotEmpty) {
    templateMap[to.templates.first.id] = from.templates.first.id;
  }
  return SrsBuiltinMigrationMaps(
    fieldMap: mapItems(
      <(String, String)>[
        for (final SrsFieldDef f in from.fields) (f.id, f.name),
      ],
      <(String, String)>[for (final SrsFieldDef f in to.fields) (f.id, f.name)],
      fromFieldKey,
      toFieldKey,
    ),
    templateMap: templateMap,
  );
}

extension SrsBuiltinMigrationOps on SrsDbStore {
  /// 当前是 Lapis 类型的全部笔记（未删除）。
  Future<List<String>> lapisNoteIds() => noteIdsOfType(lapisNoteTypeId);

  /// 把 [noteIds]（必须同为 Lapis 类型）换成 Fushi 卡片的预设映射。
  Future<SrsBuiltinMigrationMaps> lapisToFushiCardMaps(
    List<String> noteIds,
  ) async {
    final SrsNoteTypeView from = await sourceTypeOf(noteIds);
    final SrsNoteTypeView? to = await noteType(fushiCardNoteTypeId);
    if (to == null || to.deletedAt != null) {
      throw StateError('built-in Fushi card note type is missing');
    }
    return srsBuiltinMigrationMaps(profileUid, from, to);
  }

  /// 预演 Lapis → Fushi 卡片（不写库）。
  Future<SrsNoteTypeChangePreview> previewMigrateToFushiCard(
    List<String> noteIds,
  ) async {
    final SrsBuiltinMigrationMaps maps = await lapisToFushiCardMaps(noteIds);
    return previewNoteTypeChange(
      noteIds: noteIds,
      targetTypeId: fushiCardNoteTypeId,
      fieldMap: maps.fieldMap,
      templateMap: maps.templateMap,
    );
  }

  /// 执行 Lapis → Fushi 卡片（复习历史经前身链接随迁）。返回迁移的笔记数。
  Future<int> migrateToFushiCard(List<String> noteIds) async {
    if (noteIds.isEmpty) return 0;
    final SrsBuiltinMigrationMaps maps = await lapisToFushiCardMaps(noteIds);
    await changeNoteType(
      noteIds: noteIds,
      targetTypeId: fushiCardNoteTypeId,
      fieldMap: maps.fieldMap,
      templateMap: maps.templateMap,
    );
    return noteIds.length;
  }
}
