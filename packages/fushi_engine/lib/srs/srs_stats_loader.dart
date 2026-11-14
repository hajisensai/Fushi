/// 复习统计的装载：统计数据与聚合都在 Rust 内核（native/fushi_fsrs/src/store/stats.rs）。这里只备好一次装载的口径
/// （日界、此刻、每个牌组的排程配置、RWKV 此刻回忆率），之后每换一个范围 / 牌组发一条 `stats_report`，拿回聚合好的
/// [SrsStatsReport]。
///
/// 内核按 profile + [SrsDbStore.statsFingerprint] + 写入代数缓存原料：同一份数据上换范围 / 牌组不重读库。
library;

import 'package:fushi_srs/fushi_srs.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_engine/srs/srs_stats.dart';

/// 一次装载：某 profile、某一时刻的统计口径。[report] 按范围 / 牌组子集取聚合结果。
class SrsStatsLoad {
  SrsStatsLoad._({
    required this.store,
    required this.tree,
    required this.day,
    required this.nowMs,
    required this.fingerprint,
    required Map<String, Object?> context,
  }) : _context = context;

  final SrsDbStore store;
  final SrsDeckTree tree;
  final SrsDayContext day;
  final int nowMs;

  /// 装载开始时的 [SrsDbStore.statsFingerprint]：相同 = 期间没有落过会改变统计的事件，页面不必重读。
  final String fingerprint;

  /// 每条 `stats_report` 都带的口径（此刻、日界、模型、目标保留率、RWKV 回忆率）。
  final Map<String, Object?> _context;

  /// 今天的 SRS 日序号。
  int get today => day.dayIndexOf(nowMs);

  /// 牌组（按全名排序）：(deckId, 全名)。
  List<(String, String)> get decks => <(String, String)>[
    for (final SrsDeckView d in tree.decks) (d.id, tree.fullName(d.id)),
  ]..sort(((String, String) a, (String, String) b) => a.$2.compareTo(b.$2));

  /// 某牌组的子树（自己 + 全部子牌组）。
  Set<String> subtree(String deckId) => tree.subtree(deckId).toSet();

  /// 某牌组子树里的可见卡（模型校准按牌组出报告用）。
  Future<List<String>> cardIdsInDeck(String deckId) =>
      store.cardIdsInDecks(subtree(deckId));

  /// [range] 下、[decks]（null = 全部；否则只看这些牌组里的卡）的全部统计。[futureDays] 缺省按范围
  /// （[srsStatsFutureDays]，「全部」= 最晚到期日）；[windows] 是另要的时间窗（范围窗 [kSrsStatsRangeWindow] 恒带）。
  Future<SrsStatsReport> report({
    SrsStatsRange range = SrsStatsRange.month,
    Set<String>? decks,
    int? futureDays,
    Map<String, SrsStatsWindow> windows = const <String, SrsStatsWindow>{},
  }) => SrsOpLedger.track('dart:stats_report', () async {
    final int? future = futureDays ?? srsStatsFutureDays(range);
    final Map<String, Object?> r = await store.statsCommand(<String, Object?>{
      'op': 'stats_report',
      ..._context,
      'range': range.name,
      'decks': ?decks?.toList(),
      'future': ?future,
      'windows': <String, Object?>{
        kSrsStatsRangeWindow: <Object?>[srsStatsRangeBack(range), 0],
        for (final MapEntry<String, SrsStatsWindow> w in windows.entries)
          w.key: w.value.toJson(),
      },
    });
    return SrsStatsReport.fromJson(r, range: range, nowMs: nowMs);
  });

  /// 归一化之后逐卡 / 逐条的统计视图（内核 `stats_rows`：卡、有效复习、成熟事件、出处）。只给回归测试核对
  /// 归一化本身；界面一律读 [report]。
  @visibleForTesting
  Future<Map<String, Object?>> rows() =>
      store.statsCommand(<String, Object?>{'op': 'stats_rows', ..._context});
}

/// 备好当前 profile 的一次统计装载。[day] / [nowMs] 只给测试覆写（默认取 store 的口径与可信时钟）。
Future<SrsStatsLoad> loadSrsStats(
  SrsDbStore store, {
  SrsDayContext? day,
  int? nowMs,
}) => SrsOpLedger.track(
  'dart:load_stats',
  () => _loadSrsStats(store, day: day, nowMs: nowMs),
);

Future<SrsStatsLoad> _loadSrsStats(
  SrsDbStore store, {
  SrsDayContext? day,
  int? nowMs,
}) async {
  final String fingerprint = store.statsFingerprint;
  final SrsDayContext dayCtx = day ?? await store.dayContext();
  final int now = nowMs ?? store.now().$1;
  final SrsDeckTree tree = await store.deckTree();

  // 每个牌组的排程配置（算法 / 参数 / 目标保留率）：可提取度与期望保留率用。不在牌组树里的牌组归默认牌组
  // （`effectiveDeckOf`），内核按 `fallback*` 取。
  final FsrsEngine? engine = store.engine;
  const String missing = '\u0000';
  SrsSchedulingConfig configOf(String deckId) {
    final String id = tree.effectiveDeckOf(
      deckId,
      fallback: store.defaultDeckId,
    );
    if (tree[id] == null) return const SrsSchedulingConfig();
    return tree.schedulingConfig(id, defaultsOf: engine?.defaultParams);
  }

  final List<Object?> models = <Object?>[];
  final Map<String, int> modelIndex = <String, int>{};
  int modelOf(SrsSchedulingConfig c) {
    final SrsAlgorithm alg = c.algorithm.memoryAlgorithm;
    return modelIndex.putIfAbsent('${alg.wire}|${c.params.join(',')}', () {
      models.add(<Object?>[alg.wire, c.params]);
      return models.length - 1;
    });
  }

  final Map<String, Object?> deckModels = <String, Object?>{};
  final Map<String, Object?> desired = <String, Object?>{};
  final List<String> recallDecks = <String>[];
  for (final SrsDeckView d in tree.decks) {
    final SrsSchedulingConfig c = configOf(d.id);
    deckModels[d.id] = modelOf(c);
    desired[d.id] = c.desiredRetention;
    if (store.instantActiveFor(tree, d.id)) recallDecks.add(d.id);
  }
  final SrsSchedulingConfig fallback = configOf(missing);
  final bool recallFallback =
      tree[tree.effectiveDeckOf(missing, fallback: store.defaultDeckId)] !=
          null &&
      store.instantActiveFor(tree, missing);
  final Map<String, Object?> context = <String, Object?>{
    'key': fingerprint,
    'now': now,
    'utcOff': dayCtx.utcOffsetMin,
    'rollover': dayCtx.rolloverHour,
    if (engine != null) ...<String, Object?>{
      'models': models,
      'deckModels': deckModels,
      'fallbackModel': modelOf(fallback),
    },
    'desired': desired,
    'fallbackDesired': fallback.desiredRetention,
    'recallDecks': recallDecks,
    'recallFallback': recallFallback,
  };

  // RWKV-Instant 排队的复习卡：可提取度用 RWKV 此刻的回忆率（排队按今天结束时的回忆率数到期；统计显示的是此刻）。
  // RWKV 用不了时这些牌组照旧按存下的到期日排队，统计也照旧（FSRS 的可提取度、按到期日计）。
  if (recallDecks.isNotEmpty || recallFallback) {
    final List<Object?> rows =
        (await store.statsCommand(<String, Object?>{
              'op': 'stats_recall',
              ...context,
            }))['cards']!
            as List<Object?>;
    final List<SrsRwkvCandidate> candidates = <SrsRwkvCandidate>[
      for (final List<Object?> row in rows.cast<List<Object?>>())
        SrsRwkvCandidate(
          id: row[0]! as String,
          noteId: row[1]! as String,
          deckId: row[2]! as String,
          lastLogId: row[3] as String?,
        ),
    ];
    final Map<String, double>? r = await store.instantRetrievabilityOf(
      candidates,
    );
    if (r != null) {
      final List<String> ids = r.keys.toList();
      context['recall'] = <String, Object?>{
        'ids': ids,
        'r': <Object?>[
          for (final String id in ids)
            if (r[id]! case final double x when x.isFinite) x else null,
        ],
      };
    }
  }

  return SrsStatsLoad._(
    store: store,
    tree: tree,
    day: dayCtx,
    nowMs: now,
    fingerprint: fingerprint,
    context: context,
  );
}
