/// 复习统计的装载：从 [SrsDbStore]（当前 profile）一次读出有效复习投影、卡片缓存、笔记与
/// 牌组，归一成 [SrsStatsData]，另附牌组 / 搜索筛选用的索引 [SrsStatsIndex]。
///
/// 只读：不写任何事件、不刷新缓存。复习记录读 `srs_stat_reviews`（有效复习投影，与卡片缓存
/// 同一次重算产出，见 `SrsDbStore._cardCacheRow`）的定长列，不再全量读复习日志逐条
/// jsonDecode 重放历史（BUG-3770：20 万条日志时那一段占装载的一半）。
library;

import 'dart:math' as math;

import 'package:drift/drift.dart';
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
    this.defaultDeckId = '',
  });

  final SrsDeckTree tree;

  /// 默认牌组：牌组已不存在的卡在搜索里归到它（BUG-3617）；空串 = 不归并。
  final String defaultDeckId;

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

  /// 搜索求值对象（有笔记与笔记类型的卡），第一次筛选时建，之后的筛选复用。
  late final List<SrsCardSearchSubject> _subjects = () {
    final int today = day.dayIndexOf(nowMs);
    final Map<String, String> deckNames = <String, String>{};
    return <SrsCardSearchSubject>[
      for (final SrsCardCacheRow c in cards)
        if (notes[c.noteId] case final SrsNoteView n)
          if (noteTypes[n.noteTypeId] case final SrsNoteTypeView t)
            SrsCardSearchSubject(
              note: n,
              noteType: t,
              card: c,
              deckName: deckNames[c.deckId] ??= tree.effectiveDeckNameOf(
                c.deckId,
                fallback: defaultDeckId,
              ),
              day: day,
              nowMs: nowMs,
              todayDayIndex: today,
            ),
    ];
  }();

  late final SrsSearchCorpus _corpus = SrsSearchCorpus(_subjects);

  /// 命中 Anki 搜索语法的卡；语法不支持 / 不合法、原生内核不可用时抛 [SrsSearchUnsupported]。
  Set<String> cardIdsMatching(String query) {
    final SrsSearchNode node = parseAnkiSearch(query);
    return <String>{
      for (final int i in _corpus.match(node, query: query))
        _subjects[i].card.id,
    };
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

  // 前身卡（更改笔记类型 / 旧 Lapis 迁到 Fushi 卡片后隐藏的旧卡）的复习算到继承它历史的可见卡上，
  // 与复习时用的 [SrsDbStore.history] 同一血统：否则迁移过来的卡在牌组统计里一条复习都没有。投影按
  // 日志自己的卡存（分类已按血统历史定），归属在读时换。
  final Map<String, String> owners = await store.historyOwnerIndex();
  final ({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
  history = srsStatsFromProjection(<SrsStatProjection>[
    for (final SrsStatProjection p in await loadSrsStatProjection(
      db,
      store.profileUid,
    ))
      if (owners[p.cardId] case final String owner) p.withCard(owner) else p,
  ], dayCtx);

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
        final String id = tree.effectiveDeckOf(
          deckId,
          fallback: store.defaultDeckId,
        );
        if (tree[id] == null) return const SrsSchedulingConfig();
        return tree.schedulingConfig(id, defaultsOf: engine?.defaultParams);
      });

  final int cardCount = cardRows.length;
  final List<SrsStatCardState> states = List<SrsStatCardState>.filled(
    cardCount,
    SrsStatCardState.newCard,
  );
  final List<SrsMemory?> memories = List<SrsMemory?>.filled(cardCount, null);
  final List<double?> retrievability = List<double?>.filled(cardCount, null);
  // 可提取度按排程配置分组，每组一次批量调用（逐张走 FFI 时编码开销占大头）。
  final Map<SrsSchedulingConfig, _RetrievabilityGroup> groups =
      Map<SrsSchedulingConfig, _RetrievabilityGroup>.identity();
  for (int i = 0; i < cardCount; i++) {
    final SrsCardCacheRow c = cardRows[i];
    final SrsStatCardState state = srsStatCardStateOf(c.queue, c.scheduledDays);
    // 卡片缓存里的记忆状态就是有效历史重放的结果（同一次重算写的）。
    final SrsMemory? memory = c.stability != null && c.difficulty != null
        ? SrsMemory(stability: c.stability!, difficulty: c.difficulty!)
        : null;
    states[i] = state;
    memories[i] = memory;
    if (engine != null &&
        memory != null &&
        state != SrsStatCardState.newCard &&
        c.lastReviewedAt != null) {
      (groups[configOf(c.deckId)] ??= _RetrievabilityGroup()).add(
        i,
        memory,
        math.max(0, now - c.lastReviewedAt!) / 86400000,
      );
    }
  }
  if (engine != null) {
    for (final MapEntry<SrsSchedulingConfig, _RetrievabilityGroup> e
        in groups.entries) {
      final _RetrievabilityGroup g = e.value;
      try {
        final List<double> r = srsRetrievabilityBatch(
          engine,
          algorithm: e.key.algorithm.memoryAlgorithm,
          params: e.key.params,
          memories: g.memories,
          elapsedDays: g.elapsedDays,
        );
        for (int k = 0; k < r.length; k++) {
          retrievability[g.indices[k]] = r[k];
        }
      } on SrsFsrsException {
        // 整组参数不可用：这组卡的可提取度留空（与逐张失败时一致）。
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  // RWKV-Instant 排队的复习卡：可提取度用 RWKV 此刻的回忆率（排队用的就是它）。RWKV 用不了时
  // 这些牌组照旧按存下的到期日排队，统计也照旧（FSRS 的可提取度、按到期日计）。
  final Map<String, bool> byRecallDeck = <String, bool>{};
  bool byRecallCard(int i) =>
      states[i] != SrsStatCardState.newCard &&
      SrsQueue.parse(cardRows[i].queue) == SrsQueue.review &&
      (byRecallDeck[cardRows[i].deckId] ??= store.instantActiveFor(
        tree,
        cardRows[i].deckId,
      ));
  final Map<String, double>? rwkvR = await store.instantRetrievabilityOf(
    <SrsCardCacheRow>[
      for (int i = 0; i < cardCount; i++)
        if (byRecallCard(i)) cardRows[i],
    ],
  );

  final List<SrsStatCard> cards = <SrsStatCard>[];
  for (int i = 0; i < cardCount; i++) {
    final SrsCardCacheRow c = cardRows[i];
    final SrsStatCardState state = states[i];
    final SrsSchedulingConfig config = configOf(c.deckId);
    final SrsMemory? memory = memories[i];
    final bool byRecall = rwkvR != null && byRecallCard(i);
    final double? rr = byRecall ? rwkvR[c.id] : null;
    final double? r = byRecall
        ? (rr != null && rr.isFinite ? rr : null)
        : retrievability[i];
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
        byRecall: byRecall,
      ),
    );
    if (i % 500 == 499) await Future<void>.delayed(Duration.zero);
  }

  return SrsStatsBundle(
    data: SrsStatsData(
      day: dayCtx,
      nowMs: now,
      reviews: history.reviews,
      cards: cards,
      maturityEvents: history.maturity,
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
      defaultDeckId: store.defaultDeckId,
    ),
  );
}

/// 同一排程配置下待算可提取度的卡：[indices] 是在卡片列表里的下标。
class _RetrievabilityGroup {
  final List<int> indices = <int>[];
  final List<SrsMemory> memories = <SrsMemory>[];
  final List<double> elapsedDays = <double>[];

  void add(int index, SrsMemory memory, double elapsed) {
    indices.add(index);
    memories.add(memory);
    elapsedDays.add(elapsed);
  }
}

/// 读出 [profileUid] 的有效复习投影（`srs_stat_reviews`）。只取定长列、不经 Drift 的整行映射：
/// 这是统计页随复习量线性增长的那一段。
Future<List<SrsStatProjection>> loadSrsStatProjection(
  FushiDatabase db,
  String profileUid,
) async {
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT log_id, card_id, occurred_at, utc_offset_min, rating, kind, '
        'duration_ms, prev_due_day, maturity_delta FROM srs_stat_reviews '
        'WHERE profile_uid = ? ORDER BY occurred_at',
        variables: <Variable<Object>>[Variable<String>(profileUid)],
        readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
          db.srsStatReviews,
        },
      )
      .get();
  const List<SrsStatReviewKind> kinds = SrsStatReviewKind.values;
  return <SrsStatProjection>[
    for (final QueryRow r in rows)
      SrsStatProjection(
        logId: r.read<String>('log_id'),
        cardId: r.read<String>('card_id'),
        occurredAt: r.read<int>('occurred_at'),
        utcOffsetMin: r.read<int>('utc_offset_min'),
        rating: r.read<int?>('rating'),
        kind: kinds[r.read<int>('kind').clamp(0, kinds.length - 1)],
        durationMs: r.read<int>('duration_ms'),
        prevDueDay: r.read<int?>('prev_due_day'),
        maturityDelta: r.read<int>('maturity_delta'),
      ),
  ];
}
