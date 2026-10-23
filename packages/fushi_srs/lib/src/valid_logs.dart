/// 有效日志选取与 S/D 输入收集（铁律 A / B）。只做两件事：按 sortKey 找出最后一条有效日志；
/// 收集 S/D 的输入交给 FFI。不做状态机重放。
library;

import 'algorithm.dart';
import 'fsrs_engine.dart';
import 'history_kernel.dart';
import 'ordering.dart';
import 'review_log.dart';

/// 导入复习与原生复习的等价容差：同卡、同评分、时刻相差不超过 1 秒。
const int srsImportEquivalenceToleranceMs = 1000;

const int _dayMs = 24 * 60 * 60 * 1000;

/// 一张卡的日志视图。[serverTimeOf] 给出事件的 S(e)。
///
/// 排序与有效日志选取（撤销、等价导入、排程归属）只在 Rust 里写一份
/// （native/fushi_fsrs/src/history.rs，见 history_kernel.dart）；这里只是选取结果的视图。
/// 一次构造一次 FFI 调用，成批构造用 [SrsCardHistory.many]（一批一次）。
class SrsCardHistory {
  /// 一份历史（一次 FFI 调用；空历史不进原生侧）。
  factory SrsCardHistory(
    Iterable<SrsReviewLog> logs, {
    int? Function(String eventId)? serverTimeOf,
  }) => many(<SrsHistoryInput>[(logs.toList(), serverTimeOf)]).single;

  SrsCardHistory._(
    List<SrsReviewLog> logs,
    SrsHistorySelection sel,
    this._serverTimeOf,
  ) : all = <SrsReviewLog>[for (final int i in sel.order) logs[i]],
      lastEffective = sel.lastEffective < 0 ? null : logs[sel.lastEffective],
      _schedulerFrom = sel.schedulerFrom < 0 ? null : logs[sel.schedulerFrom] {
    effective = <SrsReviewLog>[
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryEffective != 0) all[k],
    ];
    revoked = <String>{
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryRevoker != 0) all[k].revokesId!,
    };
    equivalentImports = <String>{
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryEquivalentImport != 0) all[k].id,
    };
  }

  /// 一批历史，与输入同序；整批一次 FFI 调用。
  static List<SrsCardHistory> many(List<SrsHistoryInput> inputs) {
    final List<SrsHistorySelection> sel = srsSelectHistories(inputs);
    return <SrsCardHistory>[
      for (int i = 0; i < inputs.length; i++)
        SrsCardHistory._(inputs[i].$1, sel[i], inputs[i].$2),
    ];
  }

  final int? Function(String eventId)? _serverTimeOf;

  /// 全部日志（含 undo、被撤销的、不认识的；同 ID 只留最后一条），按 sortKey 升序。
  final List<SrsReviewLog> all;

  /// 有效日志（kind 已知且不是 undo、没被撤销、不是被判等价的导入日志），按 sortKey 升序。
  late final List<SrsReviewLog> effective;

  /// 被 undo 撤销的日志 ID（undo 的目标；目标不在本历史里也算）。
  late final Set<String> revoked;

  /// 被判与原生日志等价、因此不算有效的导入日志 ID。
  late final Set<String> equivalentImports;

  /// 最后一条有结果的有效日志；没有 = 新卡。
  final SrsReviewLog? lastEffective;

  /// 决定排程归属的那条 handOff（最后一条有结果的有效 handOff）。
  final SrsReviewLog? _schedulerFrom;

  SrsSortKey sortKeyOf(SrsReviewLog log) =>
      srsSortKey(log.hlc, log.id, _serverTimeOf?.call(log.id));

  /// 卡片当前排程状态 = 最后一条有效日志的结果；scheduler 另由 [scheduler] 决定。
  SrsScheduleResult get state {
    final SrsScheduleResult base =
        lastEffective?.result ?? SrsScheduleResult.initial;
    final String owner = scheduler;
    return base.scheduler == owner ? base : base.copyWith(scheduler: owner);
  }

  /// 卡片归谁排程：最后一条有效 handOff 事件（移交 / 收回）的方向；没有 = fushi。
  /// 导入锚点、评分都不改归属，同一个导入操作永远同一种结果。
  String get scheduler =>
      _schedulerFrom?.result!.scheduler ?? SrsScheduler.fushi;

  /// 协议只允许撤销「该卡当前最后一条有效日志」。
  bool canUndo(String logId) => lastEffective?.id == logId;

  /// 进统计 / 优化器训练集的评分日志（被撤销、被判等价的都已排除）。
  List<SrsReviewLog> get effectiveRatings => <SrsReviewLog>[
    for (final SrsReviewLog l in effective)
      if (l.isRatingReview && l.rating != null) l,
  ];
}

/// 导入日志 [imported] 与原生日志 [native] 是否是同一次复习（铁律 B）。只看两条日志自身。
///
/// 卡片历史里的等价判定在 native/fushi_fsrs/src/history.rs（同一容差、同一判据，固定向量
/// test/history/fixtures/ 钉齐）；这一份只给 Anki 导入器入库前判重用，第二阶段随导入一起收进内核
/// （docs/specs/2026-10-23-srs-rust-core.md）。
///
/// [sameCard] = 调用方已知两条日志属于同一张逻辑卡（同一份卡片历史：新卡与它经「更改笔记类型」
/// 继承的前身卡），此时不再比 cardId。
bool srsImportEquivalent(
  SrsReviewLog imported,
  SrsReviewLog native, {
  bool sameCard = false,
}) {
  if (!sameCard && imported.cardId != native.cardId) return false;
  if (imported.rating != native.rating) return false;
  if (!imported.isRatingReview || !native.isRatingReview) return false;
  final int? ankiMs = imported.ankiRevlogId;
  if (ankiMs == null) return false;
  return (ankiMs - native.occurredAt).abs() <= srsImportEquivalenceToleranceMs;
}

/// 「重置」：manual 且结果是新卡、reps 归零。是记忆状态的新起点。
bool srsIsReset(SrsReviewLog log) =>
    log.kind == SrsLogKind.manual &&
    log.result != null &&
    log.result!.queue == SrsQueue.newCard &&
    log.result!.reps == 0;

/// 「恢复到备份时间点」照抄状态的 manual 日志（restore_plan.dart `srsPlanStateRestore`）：
/// 结果是备份那一刻的卡片状态（含记忆状态），作为 S/D 的起点，与导入锚点同一种处理（铁律 A ③′）。
bool srsIsRestoreState(SrsReviewLog log) =>
    log.kind == SrsLogKind.manual &&
    log.result != null &&
    log.extra[srsRestoreLogExtraKey] != null &&
    !srsIsReset(log);

/// 交给 FSRS 的记忆状态输入。
class SrsMemoryInput {
  const SrsMemoryInput({
    required this.reviews,
    this.starting,
    this.sm2Start,
    required this.complete,
  });

  final List<SrsFsrsReview> reviews;

  /// 锚点自带、可直接用的起点（同算法的 FSRS 记忆状态）。
  final SrsMemory? starting;

  /// 需要用 SM-2 换算的起点（ease 小数，如 2.5；间隔天数）。
  final ({double ease, double intervalDays})? sm2Start;

  /// 历史完整（从新卡算起，与锚点无关）。
  final bool complete;
}

/// 两次评分之间的 elapsed（天）。
///
/// FSRS-7 用小数天（含当天复习的优势，第六轮审查第 12 条）；FSRS-6 与 Anki 一致按翻日后的日序号差取整天。
double srsElapsedDays({
  required SrsAlgorithm algorithm,
  required int fromMs,
  required int toMs,
  required int Function(int ms) dayIndexOf,
}) {
  if (toMs <= fromMs) return 0;
  return switch (algorithm.memoryAlgorithm) {
    SrsAlgorithm.fsrs7 || SrsAlgorithm.rwkv => (toMs - fromMs) / _dayMs,
    SrsAlgorithm.fsrs6 => (dayIndexOf(toMs) - dayIndexOf(fromMs)).toDouble(),
  };
}

/// 收集 S/D 的输入（铁律 A ①～③）。锚点只决定队列与到期，不截断 S/D 的历史。
///
/// ① 取最近一次重置之后的全部有效评分日志（含导入的；被判等价的导入日志已排除）。
/// ② 第一条是学习类评分 → 历史完整，从新卡算起。
/// ③ 不完整 → 以最近一条（在这段历史开头之前的）导入锚点为起点：锚点有同算法的 FSRS 记忆状态就直接用，
///    否则由锚点 ease + 间隔做 SM-2 换算，再接上锚点之后的评分。
SrsMemoryInput srsCollectMemoryInput(
  SrsCardHistory history, {
  required SrsAlgorithm algorithm,
  required int Function(int ms) dayIndexOf,
}) {
  final List<SrsReviewLog> eff = history.effective;
  int start = 0;
  for (int i = eff.length - 1; i >= 0; i--) {
    if (srsIsReset(eff[i])) {
      start = i + 1;
      break;
    }
  }
  final List<SrsReviewLog> window = eff.sublist(start);
  final List<SrsReviewLog> ratings = <SrsReviewLog>[
    for (final SrsReviewLog l in window)
      if (l.isRatingReview && l.rating != null) l,
  ];

  List<SrsFsrsReview> toReviews(List<SrsReviewLog> rs, int? previousMs) {
    final List<SrsFsrsReview> out = <SrsFsrsReview>[];
    int? prev = previousMs;
    for (final SrsReviewLog r in rs) {
      final double delta = prev == null
          ? 0
          : srsElapsedDays(
              algorithm: algorithm,
              fromMs: prev,
              toMs: r.occurredAt,
              dayIndexOf: dayIndexOf,
            );
      out.add(SrsFsrsReview(rating: r.rating!, deltaDays: delta));
      prev = r.occurredAt;
    }
    return out;
  }

  // ③′ 恢复照抄的状态：被撤销的评分已不在有效历史里，从这条日志的结果（含记忆状态）接着算，
  // 之后的评分接在后面；与「从锚点起算」同一套规则（同算法直接用，否则 SM-2 换算）。
  for (int i = window.length - 1; i >= 0; i--) {
    final SrsReviewLog l = window[i];
    if (!srsIsRestoreState(l)) continue;
    final List<SrsReviewLog> after = <SrsReviewLog>[
      for (final SrsReviewLog r in ratings)
        if (history.sortKeyOf(r) > history.sortKeyOf(l)) r,
    ];
    return _fromAnchor(l, after, algorithm, toReviews);
  }
  if (ratings.isEmpty) {
    final SrsReviewLog? anchor = _lastAnchor(window);
    if (anchor == null) {
      return const SrsMemoryInput(reviews: <SrsFsrsReview>[], complete: true);
    }
    return _fromAnchor(anchor, const <SrsReviewLog>[], algorithm, toReviews);
  }
  if (ratings.first.reviewType == SrsReviewType.learn) {
    return SrsMemoryInput(reviews: toReviews(ratings, null), complete: true);
  }
  final SrsReviewLog? anchor = _lastAnchor(window);
  if (anchor == null) {
    // 没有锚点也不完整（旧集合没有 revlog 的第一段）：当作从第一条评分起的新历史。
    return SrsMemoryInput(reviews: toReviews(ratings, null), complete: false);
  }
  final List<SrsReviewLog> after = <SrsReviewLog>[
    for (final SrsReviewLog r in ratings)
      if (history.sortKeyOf(r) > history.sortKeyOf(anchor)) r,
  ];
  return _fromAnchor(anchor, after, algorithm, toReviews);
}

SrsReviewLog? _lastAnchor(List<SrsReviewLog> window) {
  for (int i = window.length - 1; i >= 0; i--) {
    if (window[i].kind == SrsLogKind.importAnchor) return window[i];
  }
  return null;
}

SrsMemoryInput _fromAnchor(
  SrsReviewLog anchor,
  List<SrsReviewLog> after,
  SrsAlgorithm algorithm,
  List<SrsFsrsReview> Function(List<SrsReviewLog>, int?) toReviews,
) {
  final SrsScheduleResult res = anchor.result ?? SrsScheduleResult.initial;
  final int? since = res.lastReviewedAt ?? anchor.occurredAt;
  final List<SrsFsrsReview> reviews = toReviews(after, since);
  final SrsMemory? mem = res.memory;
  final String? anchorAlg = anchor.extra['memAlg'] as String?;
  if (mem != null && anchorAlg == algorithm.wire) {
    return SrsMemoryInput(reviews: reviews, starting: mem, complete: false);
  }
  final double ease = (res.ease ?? 2500) / 1000.0;
  final double ivl = res.scheduledDays <= 0 ? 1 : res.scheduledDays.toDouble();
  return SrsMemoryInput(
    reviews: reviews,
    sm2Start: (ease: ease, intervalDays: ivl),
    complete: false,
  );
}

/// 用 [engine] 把输入算成当前记忆状态（新卡返回 null）。
SrsMemory? srsComputeMemory(
  SrsMemoryInput input, {
  required FsrsEngine engine,
  required SrsAlgorithm algorithm,
  required List<double> params,
  double sm2Retention = 0.9,
}) {
  algorithm = algorithm.memoryAlgorithm;
  SrsMemory? starting = input.starting;
  final ({double ease, double intervalDays})? sm2 = input.sm2Start;
  if (starting == null && sm2 != null) {
    starting = engine.memoryStateFromSm2(
      algorithm: algorithm,
      params: params,
      easeFactor: sm2.ease,
      intervalDays: sm2.intervalDays,
      sm2Retention: sm2Retention,
    );
  }
  if (input.reviews.isEmpty) return starting;
  final List<SrsFsrsReview> reviews = starting == null
      ? <SrsFsrsReview>[
          SrsFsrsReview(rating: input.reviews.first.rating, deltaDays: 0),
          ...input.reviews.skip(1),
        ]
      : input.reviews;
  return engine.memoryState(
    algorithm: algorithm,
    params: params,
    reviews: reviews,
    starting: starting,
  );
}
