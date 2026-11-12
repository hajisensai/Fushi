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

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';

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

/// `dup_groups` 的一行（native/fushi_fsrs/src/store/reads.rs）。
typedef _DupRow = ({
  String id,
  String t,
  String k,
  String r,
  int c,
  String s,
  int reps,
});

extension SrsDuplicateNotes on SrsDbStore {
  /// 「不是重复」标记的修改记录键。
  static String notDuplicateKey(String otherNoteId) => 'notDup/$otherNoteId';

  /// 当前的重复建议（排除标过「不是重复」的对）。
  Future<List<SrsDuplicateGroup>> duplicateNoteGroups() async {
    final SrsColumns c = await readTable('dup_groups');
    final SrsStringColumn idCol = c.strings('id');
    final SrsStringColumn tCol = c.strings('t');
    final SrsStringColumn kCol = c.strings('k');
    final SrsStringColumn rCol = c.strings('r');
    final SrsIntColumn cCol = c.ints('c');
    final SrsStringColumn sCol = c.strings('s');
    final SrsIntColumn repsCol = c.ints('reps');
    final List<_DupRow> rows = <_DupRow>[
      for (int i = 0; i < c.rows; i++)
        (
          id: idCol[i],
          t: tCol[i],
          k: kCol[i],
          r: rCol[i],
          c: cCol[i],
          s: sCol[i],
          reps: repsCol[i],
        ),
    ];
    final Map<String, List<_DupRow>> byKey = <String, List<_DupRow>>{};
    for (final _DupRow r in rows) {
      final String key = '${r.t}\u0000${r.k}\u0000${r.r}';
      (byKey[key] ??= <_DupRow>[]).add(r);
    }
    final List<String> all = <String>[for (final _DupRow r in rows) r.id];
    final Map<String, Set<String>> dismissed = await _dismissedPairs(all);
    final List<SrsDuplicateGroup> out = <SrsDuplicateGroup>[];
    for (final List<_DupRow> g in byKey.values) {
      g.sort((_DupRow a, _DupRow b) {
        final int byReps = b.reps.compareTo(a.reps);
        if (byReps != 0) return byReps;
        final int byAge = a.c.compareTo(b.c);
        return byAge != 0 ? byAge : a.id.compareTo(b.id);
      });
      // 去掉与组里每一条都标过「不是重复」的笔记；剩不到两条就不算一组。
      final List<String> ids = <String>[for (final _DupRow r in g) r.id];
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
          noteTypeId: g.first.t,
          noteIds: kept,
          reviews: <String, int>{
            for (final _DupRow r in g)
              if (kept.contains(r.id)) r.id: r.reps,
          },
          sortFields: <String, String>{
            for (final _DupRow r in g)
              if (kept.contains(r.id)) r.id: r.s,
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
  ///
  /// 只读 `notDup/` 这一类键的修改记录（[SrsDbStore.noteFieldKeyPrefixValues]）。以前对组里每条笔记
  /// 走 [SrsDbStore.entityEditsMany]，把全部修改记录（含字段正文）读回来只为找这一类键：两台设备各导入过
  /// 同一个包的库上几乎每条笔记都成组，打开冲突页读回 22 万条、400+ MB，进程被系统杀掉（BUG-4187）。
  Future<Map<String, Set<String>>> _dismissedPairs(List<String> ids) async {
    const String prefix = 'notDup/';
    final Map<String, Set<String>> out = <String, Set<String>>{};
    for (final MapEntry<String, Map<String, Object?>> e
        in (await noteFieldKeyPrefixValues(ids, prefix)).entries) {
      for (final MapEntry<String, Object?> kv in e.value.entries) {
        if (kv.value == true) {
          (out[e.key] ??= <String>{}).add(kv.key.substring(prefix.length));
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
  }) async {
    final ({int linked, int unmatched}) r = await mergeNotesInto(
      keepId,
      absorbIds,
    );
    return SrsMergeReport(linkedCards: r.linked, unmatchedCards: r.unmatched);
  }
}
