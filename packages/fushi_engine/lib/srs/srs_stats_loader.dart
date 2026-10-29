/// 复习统计的装载：内核一次命令（`stats_bundle`，native/fushi_fsrs/src/store/bulk.rs）直接读卡片缓存、笔记缓存
/// （创建时刻与出处列）与有效复习投影，按列交回（[SrsDbStore.statsColumns]），这里归一成 [SrsStatsData]，另附牌组
/// 筛选用的索引 [SrsStatsIndex]。
///
/// 只读：不写任何事件、不刷新缓存。以前为了「制卡来源」把整库笔记连同全部修改记录物化一遍（`allNoteViews`，
/// UI isolate 上同步 JSON），卡片缓存 / 笔记缓存 / 投影各走一遍 Drift 整表读与跨 isolate 深拷贝（L3）。
library;

import 'dart:math' as math;

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_engine/srs/srs_stats.dart';

/// 统计页的筛选索引：牌组树与每张可见卡所在的牌组。
class SrsStatsIndex {
  SrsStatsIndex({
    required this.tree,
    required this.cardDecks,
    required this.day,
    required this.nowMs,
  });

  final SrsDeckTree tree;

  /// 可见卡 → 所在牌组（缓存行上的牌组 ID）。
  final Map<String, String> cardDecks;
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
      for (final MapEntry<String, String> e in cardDecks.entries)
        if (sub.contains(e.value)) e.key,
    };
  }
}

/// 装载结果。[fingerprint] 是装载开始时的 [SrsDbStore.statsFingerprint]：相同 = 期间没有落过会改变统计的事件，
/// 页面不必重读。
class SrsStatsBundle {
  const SrsStatsBundle({
    required this.data,
    required this.index,
    this.fingerprint = '',
  });

  final SrsStatsData data;
  final SrsStatsIndex index;
  final String fingerprint;
}

/// 读出当前 profile 的复习统计。[day] / [nowMs] 只给测试覆写（默认取 store 的口径与可信时钟）。每处理一批卡
/// 让出一次事件循环，大集合不卡住界面。
Future<SrsStatsBundle> loadSrsStats(
  SrsDbStore store, {
  SrsDayContext? day,
  int? nowMs,
}) async {
  final String fingerprint = store.statsFingerprint;
  final SrsDayContext dayCtx = day ?? await store.dayContext();
  final int now = nowMs ?? store.now().$1;
  final int today = dayCtx.dayIndexOf(now);
  final SrsDeckTree tree = await store.deckTree();
  final Map<String, SrsColumns> t = await store.statsColumns();
  final SrsColumns cardCols = t['cards']!;
  final int cardCount = cardCols.rows;

  final SrsStringColumn idCol = cardCols.strings('id');
  final SrsStringColumn noteCol = cardCols.strings('note_id');
  final SrsStringColumn deckCol = cardCols.strings('deck_id');
  final SrsStringColumn queueCol = cardCols.strings('queue');
  final SrsIntColumn daysCol = cardCols.ints('scheduled_days');
  final SrsIntColumn suspendedCol = cardCols.ints('suspended');
  final SrsIntColumn buriedCol = cardCols.ints('buried_until_day');
  final SrsStringColumn schedulerCol = cardCols.strings('scheduler');
  final SrsIntColumn dueDayCol = cardCols.ints('due_day');
  final SrsIntColumn dueAtCol = cardCols.ints('due_at');
  final SrsDoubleColumn stabilityCol = cardCols.doubles('stability');
  final SrsDoubleColumn difficultyCol = cardCols.doubles('difficulty');
  final SrsIntColumn lastCol = cardCols.ints('last_reviewed_at');
  final SrsIntColumn lapsesCol = cardCols.ints('lapses');
  final SrsIntColumn repsCol = cardCols.ints('reps');
  final SrsIntColumn addedCol = cardCols.ints('added_at');
  final SrsStringColumn lastLogCol = cardCols.strings('last_log_id');
  final SrsIntColumn srcCol = cardCols.ints('src');

  // 卡 ID 表：可见卡按行号，复习归属到的不可见卡接在后面（与内核的 `card` 下标同一编号）。
  final List<String> extra = t['extra_ids']!.strings('id').toList();
  final List<String> ids = <String>[
    for (int i = 0; i < cardCount; i++) idCol[i],
    ...extra,
  ];
  final List<String> deckIds = <String>[
    for (int i = 0; i < cardCount; i++) deckCol[i],
  ];
  final List<String> noteIds = <String>[
    for (int i = 0; i < cardCount; i++) noteCol[i],
  ];

  // 前身卡（更改笔记类型 / 旧 Lapis 迁到 Fushi 卡片后不再生成的旧卡）的复习已在缓存刷新时记到继承它历史的
  // 可见卡上（投影的归属卡，见 `SrsDbStore._refreshStatProjection`），并按合并历史分类。
  final ({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
  history = _historyOf(t['reviews']!, ids, dayCtx);

  // 出处：同种类同标题归一组（标题去两侧空白，与 [SrsStatsData.sourceShares] 的口径一致）。
  final SrsColumns srcCols = t['sources']!;
  final List<SrsSourceRef?> sourceDict = <SrsSourceRef?>[
    for (int i = 0; i < srcCols.rows; i++)
      srcCols.strings('kind')[i].isEmpty
          ? null
          : SrsSourceRef(srcCols.strings('kind')[i], <String, Object?>{
              if (srcCols.strings('title')[i] case final String title
                  when title.isNotEmpty)
                'title': title,
            }),
  ];

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

  final List<SrsStatCardState> states = List<SrsStatCardState>.filled(
    cardCount,
    SrsStatCardState.newCard,
  );
  final List<double?> retrievability = List<double?>.filled(cardCount, null);
  // 可提取度按排程配置分组，每组一次批量调用（逐张走 FFI 时编码开销占大头）。
  final Map<SrsSchedulingConfig, _RetrievabilityGroup> groups =
      Map<SrsSchedulingConfig, _RetrievabilityGroup>.identity();
  for (int i = 0; i < cardCount; i++) {
    final SrsStatCardState state = srsStatCardStateOf(queueCol[i], daysCol[i]);
    states[i] = state;
    // 卡片缓存里的记忆状态就是有效历史重放的结果（同一次重算写的）。
    final double? s = stabilityCol.at(i);
    final double? d = difficultyCol.at(i);
    final int? last = lastCol.at(i);
    if (engine != null &&
        s != null &&
        d != null &&
        state != SrsStatCardState.newCard &&
        last != null) {
      (groups[configOf(deckIds[i])] ??= _RetrievabilityGroup()).add(
        i,
        SrsMemory(stability: s, difficulty: d),
        math.max(0, now - last) / 86400000,
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
      SrsQueue.parse(queueCol[i]) == SrsQueue.review &&
      (byRecallDeck[deckIds[i]] ??= store.instantActiveFor(tree, deckIds[i]));
  final List<int> recallRows = <int>[
    for (int i = 0; i < cardCount; i++)
      if (byRecallCard(i)) i,
  ];
  final Map<String, double>? rwkvR = await store
      .instantRetrievabilityOf(<SrsRwkvCandidate>[
        for (final int i in recallRows)
          SrsRwkvCandidate(
            id: ids[i],
            noteId: noteIds[i],
            deckId: deckIds[i],
            lastLogId: lastLogCol.at(i),
          ),
      ]);

  final List<SrsStatCard> cards = <SrsStatCard>[];
  final Map<String, SrsSourceRef?> sources = <String, SrsSourceRef?>{};
  for (int i = 0; i < cardCount; i++) {
    final SrsStatCardState state = states[i];
    final SrsSchedulingConfig config = configOf(deckIds[i]);
    final bool byRecall = rwkvR != null && byRecallCard(i);
    final double? rr = byRecall ? rwkvR[ids[i]] : null;
    final double? r = byRecall
        ? (rr != null && rr.isFinite ? rr : null)
        : retrievability[i];
    final int? buried = buriedCol.at(i);
    final int src = srcCol[i];
    if (src >= 0) sources[noteIds[i]] = sourceDict[src];
    cards.add(
      SrsStatCard(
        id: ids[i],
        noteId: noteIds[i],
        deckId: deckIds[i],
        state: state,
        suspended: suspendedCol.flag(i),
        buried: buried != null && buried > today,
        fushiScheduled: schedulerCol[i] == SrsScheduler.fushi,
        intervalDays: daysCol[i],
        dueDay: dueDayCol.at(i),
        dueAt: dueAtCol.at(i),
        stability: stabilityCol.at(i),
        difficulty: difficultyCol.at(i),
        retrievability: r,
        lapses: lapsesCol[i],
        reps: repsCol[i],
        addedDay: dayCtx.dayIndexOf(addedCol[i]),
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
      sources: sources,
      retrievabilityAvailable: engine != null,
    ),
    index: SrsStatsIndex(
      tree: tree,
      cardDecks: <String, String>{
        for (int i = 0; i < cardCount; i++) ids[i]: deckIds[i],
      },
      day: dayCtx,
      nowMs: now,
    ),
    fingerprint: fingerprint,
  );
}

/// 有效复习投影的列 → 统计复习记录 + 成熟变化（与 [srsStatsFromProjection] 同一口径：日序号 / 小时 / 提前复习按
/// [day] 算）。[ids] 是内核 `card` 下标对应的卡 ID 表。
({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity}) _historyOf(
  SrsColumns cols,
  List<String> ids,
  SrsDayContext day,
) {
  const List<SrsStatReviewKind> kinds = SrsStatReviewKind.values;
  const int dayMs = 86400000;
  const int hourMs = 3600000;
  final SrsIntColumn card = cols.ints('card');
  final SrsIntColumn at = cols.ints('occurred_at');
  final SrsIntColumn off = cols.ints('utc_offset_min');
  final SrsIntColumn rating = cols.ints('rating');
  final SrsIntColumn kind = cols.ints('kind');
  final SrsIntColumn dur = cols.ints('duration_ms');
  final SrsIntColumn prev = cols.ints('prev_due_day');
  final SrsIntColumn delta = cols.ints('maturity_delta');
  final List<SrsStatReview> reviews = <SrsStatReview>[];
  final List<SrsStatMaturityEvent> maturity = <SrsStatMaturityEvent>[];
  for (int i = 0; i < cols.rows; i++) {
    final String cardId = ids[card[i]];
    final int occurred = at[i];
    final int dayIndex = day.dayIndexOf(occurred);
    final int? r = rating.at(i);
    if (r != null) {
      final int? prevDue = prev.at(i);
      reviews.add(
        SrsStatReview(
          cardId: cardId,
          at: occurred,
          day: dayIndex,
          hour: ((occurred + off[i] * 60000) % dayMs) ~/ hourMs,
          rating: r,
          kind: kinds[kind[i].clamp(0, kinds.length - 1)],
          durationMs: dur[i],
          early: prevDue != null && prevDue > dayIndex,
        ),
      );
    }
    if (delta[i] != 0) {
      maturity.add(
        SrsStatMaturityEvent(cardId: cardId, day: dayIndex, delta: delta[i]),
      );
    }
  }
  return (reviews: reviews, maturity: maturity);
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
