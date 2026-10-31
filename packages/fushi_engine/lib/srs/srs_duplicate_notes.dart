/// 重复笔记的合并建议（docs/specs/2026-10-25-srs-sync-v2-design.md §5.4）。
///
/// 两台设备各自制了同一个词：ID 不同的两条笔记不会被自动合并（自动判重会误伤）。这里按「同一笔记类型 + 词形键 +
/// 读音键」（笔记缓存的 `term_key` / `reading_key`，与词状态索引同口径）给出建议，用户确认后才合并：
///
/// - 被吸收笔记的每张卡挂到保留笔记同模板（同 cloze 序号）的卡上，作为它的**前身**（卡片修改记录
///   `historyFrom/<被吸收卡>`，与「更改笔记类型」同一套血统机制）：内核重放时把两边的复习历史按时间合在一起，
///   得到合并后的调度，不是二选一。
/// - 保留笔记空着的字段用被吸收笔记的值补上，标签取并集；然后被吸收笔记删除（墓碑，时间线里可恢复）。
/// - 合并之前自动打还原点。整个过程是普通的操作，照常同步到所有设备。
///
/// 「不是重复」写进两条笔记的 `notDup/<对方>` 记录（集合语义、随同步走），之后不再建议这一对。
library;

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';

/// 一组疑似重复的笔记（同类型、同词形、同读音）。
class SrsDuplicateGroup {
  const SrsDuplicateGroup({
    required this.noteTypeId,
    required this.noteIds,
    required this.reviews,
    required this.sortFields,
  });

  final String noteTypeId;

  /// 建议保留的排在最前（复习最多的，平手取先创建的）。
  final List<String> noteIds;

  /// 每条笔记全部卡片的复习次数。
  final Map<String, int> reviews;

  /// 每条笔记的首字段（去 HTML），列表显示用。
  final Map<String, String> sortFields;
}

/// 合并的结果。
class SrsMergeReport {
  const SrsMergeReport({
    required this.linkedCards,
    required this.unmatchedCards,
  });

  /// 挂成前身的卡数（它们的复习历史并进了保留卡）。
  final int linkedCards;

  /// 保留笔记里找不到同模板卡的被吸收卡数（它们随笔记删除，历史仍在时间线里）。
  final int unmatchedCards;
}

extension SrsDuplicateNotes on SrsDbStore {
  /// 「不是重复」标记的修改记录键。
  static String notDuplicateKey(String otherNoteId) => 'notDup/$otherNoteId';

  /// 当前的重复建议（排除标过「不是重复」的对）。
  Future<List<SrsDuplicateGroup>> duplicateNoteGroups() async {
    final List<QueryRow> rows = await db
        .customSelect(
          'SELECT n.id AS id, n.note_type_id AS t, n.term_key AS k, '
          'n.reading_key AS r, n.created_at AS c, n.sort_field AS s, '
          '(SELECT COALESCE(SUM(x.reps), 0) FROM srs_cards_cache x '
          'WHERE x.note_id = n.id) AS reps '
          'FROM srs_notes_cache n JOIN ('
          'SELECT note_type_id, term_key, reading_key FROM srs_notes_cache '
          "WHERE profile_uid = ? AND deleted_at IS NULL AND term_key != '' "
          'GROUP BY note_type_id, term_key, reading_key HAVING COUNT(*) > 1'
          ') g ON g.note_type_id = n.note_type_id AND g.term_key = n.term_key '
          'AND g.reading_key = n.reading_key '
          'WHERE n.profile_uid = ? AND n.deleted_at IS NULL',
          variables: <Variable<Object>>[
            Variable<String>(profileUid, srsIdType),
            Variable<String>(profileUid, srsIdType),
          ],
          readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
            db.srsNotesCache,
            db.srsCardsCache,
          },
        )
        .get();
    final Map<String, List<QueryRow>> byKey = <String, List<QueryRow>>{};
    for (final QueryRow r in rows) {
      final String key =
          '${r.read<String>('t')}\u0000${r.read<String>('k')}\u0000${r.read<String>('r')}';
      (byKey[key] ??= <QueryRow>[]).add(r);
    }
    final List<String> all = <String>[
      for (final QueryRow r in rows) r.read<String>('id'),
    ];
    final Map<String, Set<String>> dismissed = await _dismissedPairs(all);
    final List<SrsDuplicateGroup> out = <SrsDuplicateGroup>[];
    for (final List<QueryRow> g in byKey.values) {
      g.sort((QueryRow a, QueryRow b) {
        final int byReps = b.read<int>('reps').compareTo(a.read<int>('reps'));
        if (byReps != 0) return byReps;
        final int byAge = a.read<int>('c').compareTo(b.read<int>('c'));
        return byAge != 0
            ? byAge
            : a.read<String>('id').compareTo(b.read<String>('id'));
      });
      // 去掉与组里每一条都标过「不是重复」的笔记；剩不到两条就不算一组。
      final List<String> ids = <String>[
        for (final QueryRow r in g) r.read<String>('id'),
      ];
      final List<String> kept = <String>[
        for (final String id in ids)
          if (ids.any(
            (String o) => o != id && !(dismissed[id]?.contains(o) ?? false),
          ))
            id,
      ];
      if (kept.length < 2) continue;
      out.add(
        SrsDuplicateGroup(
          noteTypeId: g.first.read<String>('t'),
          noteIds: kept,
          reviews: <String, int>{
            for (final QueryRow r in g)
              if (kept.contains(r.read<String>('id')))
                r.read<String>('id'): r.read<int>('reps'),
          },
          sortFields: <String, String>{
            for (final QueryRow r in g)
              if (kept.contains(r.read<String>('id')))
                r.read<String>('id'): r.read<String>('s'),
          },
        ),
      );
    }
    out.sort(
      (SrsDuplicateGroup a, SrsDuplicateGroup b) => a
          .sortFields[a.noteIds.first]!
          .compareTo(b.sortFields[b.noteIds.first]!),
    );
    return out;
  }

  /// [ids] 各自标过「不是重复」的对方。
  Future<Map<String, Set<String>>> _dismissedPairs(List<String> ids) async {
    final Map<String, Set<String>> out = <String, Set<String>>{};
    for (final MapEntry<String, SrsEntityEdits> e in (await entityEditsMany(
      SrsEntityKind.note,
      ids,
    )).entries) {
      final SrsEntityEdits edits = e.value;
      for (final String key in edits.keys) {
        if (!key.startsWith('notDup/')) continue;
        if (edits.value(key) == true) {
          (out[e.key] ??= <String>{}).add(key.substring('notDup/'.length));
        }
      }
    }
    return out;
  }

  /// 标记 [noteIds] 两两「不是重复」（双向写，任一台设备上标过就全网不再建议）。
  Future<void> dismissDuplicates(List<String> noteIds) =>
      writeEdits(<SrsEditSpec>[
        for (final String a in noteIds)
          for (final String b in noteIds)
            if (a != b)
              SrsEditSpec(SrsEntityKind.note, a, notDuplicateKey(b), true),
      ]);

  /// 把 [absorbIds] 并进 [keepId]（见库注释）。笔记类型必须相同。
  Future<SrsMergeReport> mergeNotes({
    required String keepId,
    required List<String> absorbIds,
  }) => runExclusive(() async {
    final List<String> absorb = <String>[
      for (final String id in absorbIds)
        if (id != keepId) id,
    ];
    if (absorb.isEmpty) {
      return const SrsMergeReport(linkedCards: 0, unmatchedCards: 0);
    }
    final Map<String, SrsNoteView?> views = await notes(<String>[
      keepId,
      ...absorb,
    ]);
    final SrsNoteView? keep = views[keepId];
    if (keep == null) throw StateError('note $keepId not found');
    for (final String id in absorb) {
      final SrsNoteView? n = views[id];
      if (n == null) throw StateError('note $id not found');
      if (n.noteTypeId != keep.noteTypeId) {
        throw StateError('notes of different note types cannot be merged');
      }
    }
    await sync2Checkpoint(
      keep.fields.values.firstOrNull ?? keepId,
      'merge_notes',
    );
    final Map<String, List<SrsCardCacheRow>> cards = await cardsOfNotes(
      <String>[keepId, ...absorb],
    );
    final Map<(String, int), String> keepCards = <(String, int), String>{
      for (final SrsCardCacheRow c in cards[keepId]!)
        (c.templateId, c.clozeOrd): c.id,
    };
    int linked = 0;
    int unmatched = 0;
    final List<SrsEditSpec> specs = <SrsEditSpec>[];
    final Map<String, String> filled = <String, String>{};
    final Set<String> tags = <String>{...keep.tags};
    for (final String id in absorb) {
      final SrsNoteView n = views[id]!;
      for (final SrsCardCacheRow c in cards[id]!) {
        final String? target = keepCards[(c.templateId, c.clozeOrd)];
        if (target == null) {
          unmatched++;
          continue;
        }
        specs.add(
          SrsEditSpec(
            SrsEntityKind.card,
            target,
            SrsFieldKeys.cardHistoryFrom(c.id),
            true,
          ),
        );
        linked++;
      }
      for (final MapEntry<String, String> f in n.fields.entries) {
        if ((keep.fields[f.key] ?? '').trim().isEmpty &&
            f.value.trim().isNotEmpty &&
            !filled.containsKey(f.key)) {
          filled[f.key] = f.value;
        }
      }
      tags.addAll(n.tags);
    }
    if (specs.isNotEmpty) await writeEdits(specs);
    if (filled.isNotEmpty || tags.length != keep.tags.length) {
      await updateNote(
        keepId,
        fieldsById: filled.isEmpty ? null : filled,
        tags: tags.length == keep.tags.length ? null : tags.toList(),
      );
    }
    for (final String id in absorb) {
      await deleteNote(id);
    }
    return SrsMergeReport(linkedCards: linked, unmatchedCards: unmatched);
  });
}
