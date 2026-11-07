/// 重复卡片模板：同一笔记类型里两个模板的**正面**完全一样（注释与空白差异不算），它们考的是同一道题，
/// 却各出一张卡、各自排期，复习量白白翻倍（Discord 反馈：给内置 Fushi 卡片加了第二个模板、正文照抄
/// 第一个没改，10.9k 笔记出了 21k 张卡）。
///
/// - 判重只看正面：正面一样 = 对每条笔记渲染出同一张题面；背面不同也还是同一道题。
/// - 正面一个字段都不引用的模板（空白模板、只剩骨架的区块布局）对任何笔记都是空卡、不出卡，不算重复。
/// - 删除重复模板（[SrsTemplateDuplicates.dedupeTemplates]）：被删模板上**有复习记录**的卡挂到同一笔记
///   保留模板那张卡上，作为它的前身（卡片修改记录 `historyFrom/<被删卡>`，与「更改笔记类型」「合并重复笔记」
///   同一套血统机制）：内核重放时把两边的复习历史按时间合在一起，被删那张的复习记录不丢；然后被删模板标删除
///   （软删除，它的卡不再生成）。链接与删除在同一次写入里落库，之前自动打还原点。
/// - 卡片 ID 由 (笔记, 模板 ID, cloze 序号) 确定性派生（`SrsIds.card`），与模板在列表里的位置无关：调过
///   模板顺序也不会把复习记录对到别的模板上。
library;

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';

final RegExp _comment = RegExp(r'<!--[\s\S]*?-->');
final RegExp _space = RegExp(r'\s+');
final RegExp _fieldRef = RegExp(r'\{\{[^{}]*fld:');

/// 判重用的正面：去掉 HTML 注释（含可视化模板的布局标记，都不渲染）、空白折叠成一个空格。[front] 是
/// 存储形态（`{{fld:<id>}}` 引用）。
String srsTemplateFrontKey(String front) =>
    front.replaceAll(_comment, '').replaceAll(_space, ' ').trim();

/// 正面有没有引用字段（存储形态 `{{…fld:<id>}}`，含条件段）。没有 = 对任何笔记都是空卡。
bool srsTemplateFrontUsesFields(String front) => _fieldRef.hasMatch(front);

/// [type] 里正面相同的模板组（每组 ≥ 2 个，组内按模板顺序；组按第一个模板的顺序）。填空类型只有一个
/// 模板，恒为空。
List<List<SrsTemplateDef>> srsDuplicateFrontGroups(SrsNoteTypeView type) {
  if (type.isCloze) return const <List<SrsTemplateDef>>[];
  final Map<String, List<SrsTemplateDef>> byKey =
      <String, List<SrsTemplateDef>>{};
  for (final SrsTemplateDef tpl in type.templates) {
    if (!srsTemplateFrontUsesFields(tpl.front)) continue;
    (byKey[srsTemplateFrontKey(tpl.front)] ??= <SrsTemplateDef>[]).add(tpl);
  }
  return <List<SrsTemplateDef>>[
    for (final List<SrsTemplateDef> g in byKey.values)
      if (g.length > 1) g,
  ];
}

/// [type] 里与模板 [templateId] 正面相同的其它模板（按模板顺序）。[front] 给了就按它判（编辑器里还没
/// 保存的正面，存储形态），否则按模板现有正面。
List<SrsTemplateDef> srsTemplatesWithSameFront(
  SrsNoteTypeView type,
  String templateId, {
  String? front,
}) {
  if (type.isCloze) return const <SrsTemplateDef>[];
  final String? mine =
      front ??
      type.templates
          .where((SrsTemplateDef x) => x.id == templateId)
          .firstOrNull
          ?.front;
  if (mine == null || !srsTemplateFrontUsesFields(mine)) {
    return const <SrsTemplateDef>[];
  }
  final String key = srsTemplateFrontKey(mine);
  return <SrsTemplateDef>[
    for (final SrsTemplateDef x in type.templates)
      if (x.id != templateId &&
          srsTemplateFrontUsesFields(x.front) &&
          srsTemplateFrontKey(x.front) == key)
        x,
  ];
}

/// 一次删除重复模板的预演（确认框据此写明删多少卡、多少张的复习记录并入保留的卡）。
class SrsTemplateDedupePreview {
  const SrsTemplateDedupePreview({
    required this.keep,
    required this.drop,
    required this.droppedCards,
    required this.links,
    required this.bothReviewed,
    required this.unmatched,
  });

  /// 保留的模板。
  final SrsTemplateDef keep;

  /// 要删的模板（与 [keep] 正面相同）。
  final List<SrsTemplateDef> drop;

  /// 要删模板现在可见的卡数（删了就不再出现）。
  final int droppedCards;

  /// 保留卡 → 并进来的被删卡（被删卡有复习记录、同一笔记有保留卡）。
  final Map<String, List<String>> links;

  /// 两张都有复习记录的笔记数（合并后两边的历史按时间合在一起）。
  final int bothReviewed;

  /// 有复习记录、但同一笔记找不到保留卡的被删卡数（正面相同时不会出现；它们的历史仍在时间线里）。
  final int unmatched;

  /// 复习记录并入保留卡的被删卡数。
  int get linkedCards =>
      links.values.fold<int>(0, (int s, List<String> l) => s + l.length);
}

extension SrsTemplateDuplicates on SrsDbStore {
  /// 预演删除 [dropTemplateIds]、保留 [keepTemplateId]（不写库）。要删的模板与保留模板正面必须相同，
  /// 否则抛 [StateError]（不是重复模板的删除走 `deleteTemplate`）。
  Future<SrsTemplateDedupePreview> previewTemplateDedupe(
    String noteTypeId, {
    required String keepTemplateId,
    required List<String> dropTemplateIds,
  }) async {
    final SrsNoteTypeView? type = await noteType(noteTypeId);
    if (type == null || type.deletedAt != null) {
      throw ArgumentError.value(noteTypeId, 'noteTypeId', 'not found');
    }
    SrsTemplateDef find(String id) =>
        type.templates.where((SrsTemplateDef x) => x.id == id).firstOrNull ??
        (throw ArgumentError.value(id, 'templateId', 'not found'));
    final SrsTemplateDef keep = find(keepTemplateId);
    final List<SrsTemplateDef> drop = <SrsTemplateDef>[
      for (final String id in dropTemplateIds.toSet())
        if (id != keepTemplateId) find(id),
    ];
    if (drop.isEmpty) throw ArgumentError('nothing to drop');
    final Set<String> same = <String>{
      for (final SrsTemplateDef x in srsTemplatesWithSameFront(type, keep.id))
        x.id,
    };
    for (final SrsTemplateDef d in drop) {
      if (!same.contains(d.id)) {
        throw StateError('template ${d.id} is not a duplicate of ${keep.id}');
      }
    }
    final Set<String> dropIds = <String>{
      for (final SrsTemplateDef d in drop) d.id,
    };
    final List<SrsCardCacheRow> rows =
        await (db.select(db.srsCardsCache)..where(
              (c) =>
                  c.profileUid.equals(profileUid) &
                  c.templateId.isIn(<String>[keep.id, ...dropIds]),
            ))
            .get();
    bool reviewed(SrsCardCacheRow c) => c.reps > 0 || c.lastReviewedAt != null;
    final Map<String, SrsCardCacheRow> keepByNote = <String, SrsCardCacheRow>{
      for (final SrsCardCacheRow c in rows)
        if (c.templateId == keep.id) c.noteId: c,
    };
    int dropped = 0;
    int unmatched = 0;
    final Map<String, List<String>> links = <String, List<String>>{};
    final Set<String> both = <String>{};
    for (final SrsCardCacheRow c in rows) {
      if (!dropIds.contains(c.templateId)) continue;
      if (!c.hidden) dropped++;
      if (!reviewed(c)) continue;
      final SrsCardCacheRow? k = keepByNote[c.noteId];
      if (k == null) {
        unmatched++;
        continue;
      }
      (links[k.id] ??= <String>[]).add(c.id);
      if (reviewed(k)) both.add(c.noteId);
    }
    return SrsTemplateDedupePreview(
      keep: keep,
      drop: drop,
      droppedCards: dropped,
      links: links,
      bothReviewed: both.length,
      unmatched: unmatched,
    );
  }

  /// 删除重复模板（见库注释）：被删模板上有复习记录的卡挂成同一笔记保留卡的前身，被删模板标删除，同一次
  /// 写入落库。预演与写入在同一个独占区里：算计划时读到的现值就是落库时的现值。
  Future<SrsTemplateDedupePreview> dedupeTemplates(
    String noteTypeId, {
    required String keepTemplateId,
    required List<String> dropTemplateIds,
  }) => runExclusive(() async {
    final SrsTemplateDedupePreview p = await previewTemplateDedupe(
      noteTypeId,
      keepTemplateId: keepTemplateId,
      dropTemplateIds: dropTemplateIds,
    );
    final SrsNoteTypeView type = (await noteType(noteTypeId))!;
    await sync2Checkpoint(type.name, 'note_type');
    await writeEdits(<SrsEditSpec>[
      for (final MapEntry<String, List<String>> l in p.links.entries)
        for (final String from in l.value)
          SrsEditSpec(
            SrsEntityKind.card,
            l.key,
            SrsFieldKeys.cardHistoryFrom(from),
            true,
          ),
      for (final SrsTemplateDef d in p.drop)
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.templateDef(d.id),
          d.copyWith(deleted: true).toValue(),
        ),
    ]);
    return p;
  });
}
