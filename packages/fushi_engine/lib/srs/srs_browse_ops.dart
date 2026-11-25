/// 浏览页的批量操作：每个操作一个批次落库（[SrsDbStore.editFieldsUndoable] / 批量日志），并给出撤销——
/// 标志 / 牌组 / 标签 / 删除 = 按撤销凭据还原（[SrsDbStore.revertEdits]：只还原之后没被别人动过的字段键，
/// 被动过的保留现值，见 srs_edit_undo.dart）；重置 / 设置到期 = 撤那批日志（铁律 B：只有仍是该卡最后一条有效日志
/// 的才撤得掉）。
library;

import 'dart:math';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';

/// 撤销一个批量操作的结果。
class SrsBatchRevertResult {
  /// 字段类撤销（[SrsDbStore.revertEdits] 的结果）。
  const SrsBatchRevertResult.edits(this.edits) : blockedLogs = 0;

  /// 日志类撤销：[blockedLogs] 条撤不掉（别的设备已在其上复习过）。
  const SrsBatchRevertResult.logs(this.blockedLogs)
    : edits = SrsEditUndoResult.none;

  final SrsEditUndoResult edits;
  final int blockedLogs;

  bool get complete => blockedLogs == 0 && edits.complete;
}

/// 撤销一个批量操作。
typedef SrsBatchRevert =
    Future<SrsBatchRevertResult> Function(SrsDbStore store);

/// 字段类撤销：按凭据还原（凭据为空 = 没有改动，没有撤销）。
SrsBatchRevert? srsEditRevert(SrsEditUndo undo) => undo.isEmpty
    ? null
    : (SrsDbStore s) async =>
          SrsBatchRevertResult.edits(await s.revertEdits(undo));

/// 批量操作的结果。
class SrsBatchOutcome {
  const SrsBatchOutcome({required this.changed, this.revert});

  /// 由一次可撤销写入的凭据构造：改动数 = 涉及的实体数。
  factory SrsBatchOutcome.ofUndo(SrsEditUndo undo) =>
      SrsBatchOutcome(changed: undo.entityCount, revert: srsEditRevert(undo));

  /// 实际改动的卡片 / 笔记数（no-op 不算）。
  final int changed;

  /// 撤销；没有改动时为 null。
  final SrsBatchRevert? revert;
}

/// 一批卡片同一个标志键写成 [after]（当前值已经是它的卡不写，没有修改记录的卡写一条同值记录只是噪音）。
Future<SrsBatchOutcome> _cardFieldBatch(
  SrsDbStore store,
  Iterable<String> cardIds,
  String key,
  Object? Function(SrsCardCacheRow row) current,
  Object? after,
) async {
  final List<SrsCardCacheRow> rows = <SrsCardCacheRow>[
    for (final SrsCardCacheRow r in await store.cardRows(cardIds))
      if (current(r) != after) r,
  ];
  if (rows.isEmpty) return const SrsBatchOutcome(changed: 0);
  return SrsBatchOutcome.ofUndo(
    await store.editFieldsUndoable(<SrsFieldChange>[
      for (final SrsCardCacheRow r in rows)
        SrsFieldChange(SrsEntityKind.card, r.id, key, after),
    ]),
  );
}

/// 暂停 / 恢复。
Future<SrsBatchOutcome> srsBatchSetSuspended(
  SrsDbStore store,
  Iterable<String> cardIds, {
  required bool suspended,
}) => _cardFieldBatch(
  store,
  cardIds,
  SrsFieldKeys.suspended,
  (SrsCardCacheRow r) => r.suspended,
  suspended,
);

/// 搁置到明天 / 取消搁置。
Future<SrsBatchOutcome> srsBatchSetBuried(
  SrsDbStore store,
  Iterable<String> cardIds, {
  required bool buried,
}) async {
  final SrsDayContext day = await store.dayContext();
  final int today = day.dayIndexOf(store.now().$1);
  return _cardFieldBatch(
    store,
    cardIds,
    SrsFieldKeys.buriedUntilDay,
    (SrsCardCacheRow r) => r.buriedUntilDay,
    buried ? today + 1 : null,
  );
}

/// 改旗标（0 = 清除）。
Future<SrsBatchOutcome> srsBatchSetFlag(
  SrsDbStore store,
  Iterable<String> cardIds,
  int flag,
) => _cardFieldBatch(
  store,
  cardIds,
  SrsFieldKeys.flag,
  (SrsCardCacheRow r) => r.flag,
  flag,
);

/// 改牌组。
Future<SrsBatchOutcome> srsBatchMoveCards(
  SrsDbStore store,
  Iterable<String> cardIds,
  String deckId,
) => _cardFieldBatch(
  store,
  cardIds,
  SrsFieldKeys.cardDeck,
  (SrsCardCacheRow r) => r.deckId,
  deckId,
);

/// 把输入的标签串拆成标签（空白分隔，去重，保留顺序）。
List<String> srsParseTags(String text) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String t in text.split(RegExp(r'\s+')))
      if (t.isNotEmpty && seen.add(t.toLowerCase())) t,
  ];
}

/// 加 / 删标签（标签比较不区分大小写，与 Anki 一致）。
Future<SrsBatchOutcome> srsBatchEditTags(
  SrsDbStore store,
  Iterable<String> noteIds, {
  List<String> add = const <String>[],
  List<String> remove = const <String>[],
}) async {
  final Set<String> removeLower = <String>{
    for (final String t in remove) t.toLowerCase(),
  };
  final List<SrsFieldChange> changes = <SrsFieldChange>[];
  // 笔记按块一次预读（以前每条笔记各查三次，BUG-3543）。
  for (final MapEntry<String, SrsNoteView?> e in (await store.notes(
    noteIds,
  )).entries) {
    final String id = e.key;
    final SrsNoteView? n = e.value;
    if (n == null) continue;
    final List<String> next = <String>[
      for (final String t in n.tags)
        if (!removeLower.contains(t.toLowerCase())) t,
    ];
    final Set<String> have = <String>{
      for (final String t in next) t.toLowerCase(),
    };
    for (final String t in add) {
      if (have.add(t.toLowerCase())) next.add(t);
    }
    if (_sameTags(next, n.tags)) continue;
    changes.add(
      SrsFieldChange(SrsEntityKind.note, id, SrsFieldKeys.noteTags, next),
    );
  }
  if (changes.isEmpty) return const SrsBatchOutcome(changed: 0);
  return SrsBatchOutcome.ofUndo(await store.editFieldsUndoable(changes));
}

bool _sameTags(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 删除笔记（连同全部卡片）；撤销 = 恢复。
Future<SrsBatchOutcome> srsBatchDeleteNotes(
  SrsDbStore store,
  Iterable<String> noteIds,
) async {
  final int nowMs = store.now().$1;
  final List<String> ids = noteIds.toSet().toList();
  if (ids.isEmpty) return const SrsBatchOutcome(changed: 0);
  return SrsBatchOutcome.ofUndo(
    await store.editFieldsUndoable(<SrsFieldChange>[
      for (final String id in ids)
        SrsFieldChange(SrsEntityKind.note, id, SrsFieldKeys.deleted, nowMs),
    ]),
  );
}

SrsBatchOutcome _logOutcome(List<SrsReviewLog> logs) => logs.isEmpty
    ? const SrsBatchOutcome(changed: 0)
    : SrsBatchOutcome(
        changed: logs.length,
        revert: (SrsDbStore s) async => SrsBatchRevertResult.logs(
          await s.undoLogs(<(String, String)>[
            for (final SrsReviewLog l in logs) (l.cardId, l.id),
          ]),
        ),
      );

/// 重置为新卡（忘记）。需要排程内核。
Future<SrsBatchOutcome> srsBatchResetCards(
  SrsDbStore store,
  Iterable<String> cardIds,
) async => _logOutcome(await store.resetCards(cardIds));

/// 「设置到期日」的输入：`N`（N 天后，0 = 今天）或 `N-M`（N 到 M 天之间随机分散，与 Anki 一致）。
/// 不合法返回 null。
(int, int)? srsParseDueDays(String text) {
  final RegExpMatch? m = RegExp(
    r'^\s*(\d{1,5})\s*(?:-\s*(\d{1,5}))?\s*$',
  ).firstMatch(text);
  if (m == null) return null;
  final int a = int.parse(m.group(1)!);
  final int b = m.group(2) == null ? a : int.parse(m.group(2)!);
  return a <= b ? (a, b) : (b, a);
}

/// 设置到期日：[from]–[to] 天后（含两端，随机分散）。需要排程内核。
Future<SrsBatchOutcome> srsBatchSetDue(
  SrsDbStore store,
  Iterable<String> cardIds, {
  required int from,
  required int to,
  Random? random,
}) async {
  final Random rng = random ?? Random();
  final SrsDayContext day = await store.dayContext();
  final int today = day.dayIndexOf(store.now().$1);
  final List<String> ids = cardIds.toSet().toList();
  return _logOutcome(
    await store.setDueDays(<String, int>{
      for (final String id in ids)
        id: today + from + (to > from ? rng.nextInt(to - from + 1) : 0),
    }),
  );
}
