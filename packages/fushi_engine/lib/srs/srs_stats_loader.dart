/// 复习统计的装载：从 [SrsDbStore]（当前 profile）一次读出日志、卡片缓存、笔记与
/// 牌组，归一成 [SrsStatsData]，另附牌组 / 搜索筛选用的索引 [SrsStatsIndex]。
///
/// 只读：不写任何事件、不刷新缓存。日志按卡用 [SrsCardHistory] 判有效。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';

/// 统计页的筛选索引：牌组树、笔记与笔记类型（Anki 搜索语法求值用）。
class SrsStatsIndex {
  SrsStatsIndex({
    required this.tree,
    required this.cards,
    required this.notes,
    required this.noteTypes,
    required this.day,
    required this.nowMs,
  });

  final SrsDeckTree tree;

  /// 可见卡片缓存行。
  final List<SrsCardCacheRow> cards;
  final Map<String, SrsNoteView> notes;
  final Map<String, SrsNoteTypeView> noteTypes;
  final SrsDayContext day;
  final int nowMs;

  /// 牌组（按全名排序）：(deckId, 全名)。
  List<(String, String)> get decks => <(String, String)>[
    for (final SrsDeckView d in tree.decks) (d.id, tree.fullName(d.id)),
  ]..sort(((String, String) a, (String, String) b) => a.$2.compareTo(b.$2));

  /// 某牌组子树里的卡。
  Set<String> cardIdsInDeck(String deckId) {
    final Set<String> sub = tree.subtree(deckId).toSet();
    return <String>{
      for (final SrsCardCacheRow c in cards)
        if (sub.contains(c.deckId)) c.id,
    };
  }

  /// 命中 Anki 搜索语法的卡；语法不支持 / 不合法时抛 [SrsSearchUnsupported]。
  Set<String> cardIdsMatching(String query) {
    final SrsSearchNode node = parseAnkiSearch(query);
    final int today = day.dayIndexOf(nowMs);
    final Set<String> out = <String>{};
    for (final SrsCardCacheRow c in cards) {
      final SrsNoteView? n = notes[c.noteId];
      if (n == null) continue;
      final SrsNoteTypeView? t = noteTypes[n.noteTypeId];
      if (t == null) continue;
      final SrsCardSearchSubject subject = SrsCardSearchSubject(
        note: n,
        noteType: t,
        card: c,
        deckName: tree[c.deckId] == null ? '' : tree.fullName(c.deckId),
        day: day,
        nowMs: nowMs,
        todayDayIndex: today,
      );
      if (matchesAnkiSearch(node, subject)) {
        out.add(c.id);
      }
    }
    return out;
  }
}

/// 装载结果。
class SrsStatsBundle {
  const SrsStatsBundle({required this.data, required this.index});

  final SrsStatsData data;
  final SrsStatsIndex index;
}

/// 读出当前 profile 的复习统计。[day] / [nowMs] 只给测试覆写（默认取 store 的
/// 口径与可信时钟）。每处理一批卡让出一次事件循环，大集合不卡住界面。
Future<SrsStatsBundle> loadSrsStats(
  SrsDbStore store, {
  SrsDayContext? day,
  int? nowMs,
}) async {
  final FushiDatabase db = store.db;
  final SrsDayContext dayCtx = day ?? await store.dayContext();
  final int now = nowMs ?? store.now().$1;
  final int today = dayCtx.dayIndexOf(now);
  final SrsDeckTree tree = await store.deckTree();

  final List<SrsReviewLogRow> logRows = await (db.select(
    db.srsReviewLogs,
  )..where((t) => t.profileUid.equals(store.profileUid))).get();
  final Map<String, List<SrsReviewLog>> logsByCard =
      <String, List<SrsReviewLog>>{};
  for (int i = 0; i < logRows.length; i++) {
    final SrsReviewLogRow r = logRows[i];
    (logsByCard[r.cardId] ??= <SrsReviewLog>[]).add(
      SrsReviewLog.fromJson(
        (jsonDecode(r.json) as Map).cast<String, Object?>(),
      ),
    );
    if (i % 4000 == 3999) await Future<void>.delayed(Duration.zero);
  }

  final List<SrsCardCacheRow> cardRows = <SrsCardCacheRow>[
    for (final SrsCardCacheRow c in await store.allCardRows())
      if (!c.hidden) c,
  ];
  final List<SrsNoteCacheRow> noteRows = await (db.select(
    db.srsNotesCache,
  )..where((n) => n.profileUid.equals(store.profileUid))).get();
  final Map<String, SrsNoteCacheRow> noteCache = <String, SrsNoteCacheRow>{
    for (final SrsNoteCacheRow n in noteRows) n.id: n,
  };
  final Map<String, SrsNoteView> notes = <String, SrsNoteView>{
    for (final SrsNoteView n in await store.allNoteViews()) n.id: n,
  };
  final Map<String, SrsNoteTypeView> types = <String, SrsNoteTypeView>{
    for (final SrsNoteTypeView t in await store.noteTypes()) t.id: t,
  };

  // 每个牌组的排程配置（算法 / 参数 / 目标保留率），可提取度与期望保留率用。
  final FsrsEngine? engine = store.engine;
  final Map<String, SrsSchedulingConfig> configs =
      <String, SrsSchedulingConfig>{};
  SrsSchedulingConfig configOf(String deckId) =>
      configs.putIfAbsent(deckId, () {
        final String id = tree[deckId] == null ? store.defaultDeckId : deckId;
        if (tree[id] == null) return const SrsSchedulingConfig();
        return tree.schedulingConfig(id, defaultsOf: engine?.defaultParams);
      });

  final List<SrsStatReview> reviews = <SrsStatReview>[];
  final List<SrsStatMaturityEvent> maturity = <SrsStatMaturityEvent>[];
  final Map<String, SrsMemory?> memoryByCard = <String, SrsMemory?>{};
  int processed = 0;
  for (final MapEntry<String, List<SrsReviewLog>> e in logsByCard.entries) {
    final SrsCardHistory h = SrsCardHistory(e.value);
    final ({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
    one = srsStatsFromHistory(h, dayCtx);
    reviews.addAll(one.reviews);
    maturity.addAll(one.maturity);
    memoryByCard[e.key] = h.state.memory;
    if (++processed % 1000 == 0) await Future<void>.delayed(Duration.zero);
  }

  final List<SrsStatCard> cards = <SrsStatCard>[];
  for (int i = 0; i < cardRows.length; i++) {
    final SrsCardCacheRow c = cardRows[i];
    final SrsStatCardState state = srsStatCardStateOf(c.queue, c.scheduledDays);
    final SrsSchedulingConfig config = configOf(c.deckId);
    final SrsMemory? memory =
        memoryByCard[c.id] ??
        (c.stability != null && c.difficulty != null
            ? SrsMemory(stability: c.stability!, difficulty: c.difficulty!)
            : null);
    double? r;
    if (engine != null &&
        memory != null &&
        state != SrsStatCardState.newCard &&
        c.lastReviewedAt != null) {
      try {
        r = engine.retrievability(
          algorithm: config.algorithm,
          params: config.params,
          memory: memory,
          elapsedDays: math.max(0, now - c.lastReviewedAt!) / 86400000,
        );
      } on SrsFsrsException {
        r = null;
      }
    }
    final SrsNoteCacheRow? n = noteCache[c.noteId];
    cards.add(
      SrsStatCard(
        id: c.id,
        noteId: c.noteId,
        deckId: c.deckId,
        state: state,
        suspended: c.suspended,
        buried: c.buriedUntilDay != null && c.buriedUntilDay! > today,
        fushiScheduled: c.scheduler == SrsScheduler.fushi,
        intervalDays: c.scheduledDays,
        dueDay: c.dueDay,
        dueAt: c.dueAt,
        stability: memory?.stability ?? c.stability,
        difficulty: memory?.difficulty ?? c.difficulty,
        retrievability: r,
        lapses: c.lapses,
        reps: c.reps,
        addedDay: dayCtx.dayIndexOf(n?.createdAt ?? c.noteCreatedAt),
        label: n?.sortField ?? '',
        desiredRetention: config.desiredRetention,
      ),
    );
    if (i % 500 == 499) await Future<void>.delayed(Duration.zero);
  }

  return SrsStatsBundle(
    data: SrsStatsData(
      day: dayCtx,
      nowMs: now,
      reviews: reviews,
      cards: cards,
      maturityEvents: maturity,
      sources: <String, SrsSourceRef?>{
        for (final SrsNoteView n in notes.values) n.id: n.source,
      },
      retrievabilityAvailable: engine != null,
    ),
    index: SrsStatsIndex(
      tree: tree,
      cards: cardRows,
      notes: notes,
      noteTypes: types,
      day: dayCtx,
      nowMs: now,
    ),
  );
}
