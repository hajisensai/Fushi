/// 浏览页的批量操作：每个操作一个批次落库（[SrsDbStore.editFieldsBatch] / 批量日志），
/// 并给出撤销——标志 / 牌组 / 标签 / 删除 = 再写一批改回原值的修改记录（铁律 H，新记录支配原记录）；
/// 重置 / 设置到期 = 撤那批日志（铁律 B：只有仍是该卡最后一条有效日志的才撤得掉）。
library;

import 'dart:math';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';

/// 撤销一个批量操作；返回撤不掉的条数（别的设备已在其上复习过）。
typedef SrsBatchRevert = Future<int> Function(SrsDbStore store);

/// 批量操作的结果。
class SrsBatchOutcome {
  const SrsBatchOutcome({required this.changed, this.revert});

  /// 实际改动的卡片 / 笔记数（no-op 不算）。
  final int changed;

  /// 撤销；没有改动时为 null。
  final SrsBatchRevert? revert;
}

/// 按卡片缓存行逐张取旧值、写新值、撤销时写回旧值（只撤真正改过的卡）。
Future<SrsBatchOutcome> _cardFieldBatch(
  SrsDbStore store,
  Iterable<String> cardIds,
  String key,
  Object? Function(SrsCardCacheRow row) before,
  Object? after,
) async {
  // 当前值已经是目标值的卡不写（没有修改记录的卡读出默认值，写一条同值记录只是噪音）。
  final List<SrsCardCacheRow> rows = <SrsCardCacheRow>[
    for (final SrsCardCacheRow r in await store.cardRows(cardIds))
      if (before(r) != after) r,
  ];
  final List<SrsFieldEdit> written = await store
      .editFieldsBatch(<SrsFieldChange>[
        for (final SrsCardCacheRow r in rows)
          SrsFieldChange(SrsEntityKind.card, r.id, key, after),
      ]);
  final Set<String> touched = <String>{
    for (final SrsFieldEdit e in written) e.entityId,
  };
  if (touched.isEmpty) return const SrsBatchOutcome(changed: 0);
  final Map<String, Object?> old = <String, Object?>{
    for (final SrsCardCacheRow r in rows)
      if (touched.contains(r.id)) r.id: before(r),
  };
  return SrsBatchOutcome(
    changed: touched.length,
    revert: (SrsDbStore s) async {
      await s.editFieldsBatch(<SrsFieldChange>[
        for (final MapEntry<String, Object?> e in old.entries)
          SrsFieldChange(SrsEntityKind.card, e.key, key, e.value),
      ]);
      return 0;
    },
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
  final Map<String, List<String>> old = <String, List<String>>{};
  final List<SrsFieldChange> changes = <SrsFieldChange>[];
  for (final String id in noteIds.toSet()) {
    final SrsNoteView? n = await store.note(id);
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
    if (next.join('\u0001') == n.tags.join('\u0001')) continue;
    old[id] = n.tags;
    changes.add(
      SrsFieldChange(SrsEntityKind.note, id, SrsFieldKeys.noteTags, next),
    );
  }
  if (changes.isEmpty) return const SrsBatchOutcome(changed: 0);
  await store.editFieldsBatch(changes);
  return SrsBatchOutcome(
    changed: changes.length,
    revert: (SrsDbStore s) async {
      await s.editFieldsBatch(<SrsFieldChange>[
        for (final MapEntry<String, List<String>> e in old.entries)
          SrsFieldChange(
            SrsEntityKind.note,
            e.key,
            SrsFieldKeys.noteTags,
            e.value,
          ),
      ]);
      return 0;
    },
  );
}

/// 删除笔记（连同全部卡片）；撤销 = 恢复。
Future<SrsBatchOutcome> srsBatchDeleteNotes(
  SrsDbStore store,
  Iterable<String> noteIds,
) async {
  final int nowMs = store.now().$1;
  final List<String> ids = noteIds.toSet().toList();
  final List<SrsFieldEdit> written = await store
      .editFieldsBatch(<SrsFieldChange>[
        for (final String id in ids)
          SrsFieldChange(SrsEntityKind.note, id, SrsFieldKeys.deleted, nowMs),
      ]);
  final Set<String> touched = <String>{
    for (final SrsFieldEdit e in written) e.entityId,
  };
  if (touched.isEmpty) return const SrsBatchOutcome(changed: 0);
  return SrsBatchOutcome(
    changed: touched.length,
    revert: (SrsDbStore s) async {
      await s.editFieldsBatch(<SrsFieldChange>[
        for (final String id in touched)
          SrsFieldChange(SrsEntityKind.note, id, SrsFieldKeys.deleted, null),
      ]);
      return 0;
    },
  );
}

SrsBatchOutcome _logOutcome(List<SrsReviewLog> logs) => logs.isEmpty
    ? const SrsBatchOutcome(changed: 0)
    : SrsBatchOutcome(
        changed: logs.length,
        revert: (SrsDbStore s) => s.undoLogs(<(String, String)>[
          for (final SrsReviewLog l in logs) (l.cardId, l.id),
        ]),
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
