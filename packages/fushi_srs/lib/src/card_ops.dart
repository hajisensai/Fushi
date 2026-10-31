/// 把「评分 / 撤销 / 手动改期 / 重置 / 移交」落成一条不可变日志事件。
library;

import 'algorithm.dart';
import 'day.dart';
import 'fsrs_engine.dart';
import 'hlc.dart';
import 'ids.dart';
import 'review_log.dart';
import 'scheduler.dart';
import 'valid_logs.dart';

/// 本机写日志所需的身份与时间。
class SrsLogContext {
  SrsLogContext({
    required this.profileUid,
    required this.clock,
    required this.now,
    required this.day,
    String Function(int nowMs)? newId,
  }) : _newId = newId ?? ((int ms) => uuidV7(nowMs: ms));

  final String profileUid;
  final HlcClock clock;

  /// (可信时间毫秒, 时间来源)。
  final (int, SrsTimeSource) Function() now;
  final SrsDayContext day;
  final String Function(int nowMs) _newId;

  String newId(int nowMs) => _newId(nowMs);
}

/// 参数组的出处哈希：算法前缀 + 参数的稳定摘要。
String srsParamsHash(SrsAlgorithm algorithm, List<double> params) {
  if (params.isEmpty) return '${algorithm.wire}:default';
  final String text = params.map((double p) => p.toStringAsFixed(6)).join(',');
  return '${algorithm.wire}:${hash53(text).toRadixString(36)}';
}

/// 评分预览：四个按钮各自的结果，以及算出它们所用的记忆状态。
class SrsAnswerPreview {
  const SrsAnswerPreview({
    required this.plan,
    required this.memoryBefore,
    required this.algorithm,
    required this.params,
    required this.nowMs,
    required this.timeSource,
  });

  final SrsAnswerPlan plan;
  final SrsMemory? memoryBefore;

  /// 这次作答的排程方式，写进日志的 `alg`：RWKV 牌组是 [SrsAlgorithm.rwkv]（RWKV 没准备好时它的复习卡
  /// 根本不出，不存在「RWKV 牌组按 FSRS-7 排」），否则是牌组算法的 [SrsAlgorithm.memoryAlgorithm]。间隔与
  /// 记忆状态一律由记忆算法算（RWKV 牌组是 FSRS-7）：RWKV-Instant 不给间隔，存下的到期日只在导出给 Anki
  /// 时用；统计据日志的 `alg` 区分按 R 排的复习。
  final SrsAlgorithm algorithm;
  final List<double> params;
  final int nowMs;
  final SrsTimeSource timeSource;
}

/// 卡片操作。所有方法只读 [SrsCardHistory]，返回新事件，不改任何已有事件。
class SrsCardOps {
  const SrsCardOps({required this.engine});

  final FsrsEngine engine;

  /// 算四个评分的结果（显示间隔预览，也是 [answer] 的第一步）。
  SrsAnswerPreview preview({
    required String cardId,
    required SrsCardHistory history,
    required SrsSchedulingConfig config,
    required SrsLogContext ctx,
  }) {
    final (int nowMs, SrsTimeSource source) = ctx.now();
    final SrsAlgorithm algorithm = config.algorithm.memoryAlgorithm;
    final List<double> params = config.params;
    final SrsMemoryInput input = srsCollectMemoryInput(
      history,
      algorithm: algorithm,
      day: ctx.day,
    );
    final SrsMemory? memory = srsComputeMemory(
      input,
      engine: engine,
      algorithm: algorithm,
      params: params,
    );
    final SrsScheduleResult current = history.state;
    final SrsAnswerContext answerCtx = SrsAnswerContext(
      cardId: cardId,
      current: current,
      nowMs: nowMs,
      day: ctx.day,
      config: config,
    );
    final SrsNextStates next = engine.nextStates(
      algorithm: algorithm,
      params: params,
      desiredRetention: config.desiredRetention,
      memory: memory,
      elapsedDays: answerCtx.elapsedDaysFor(algorithm),
    );
    return SrsAnswerPreview(
      plan: srsPlanAnswer(answerCtx, next),
      memoryBefore: memory,
      algorithm: config.algorithm.usesRwkv ? SrsAlgorithm.rwkv : algorithm,
      params: params,
      nowMs: nowMs,
      timeSource: source,
    );
  }

  /// 评分：写一条 review 日志。
  SrsReviewLog answer({
    required String cardId,
    required SrsCardHistory history,
    required int rating,
    required SrsSchedulingConfig config,
    required SrsLogContext ctx,
    int durationMs = 0,
  }) {
    if (rating < 1 || rating > 4) {
      throw ArgumentError.value(rating, 'rating', 'must be 1..4');
    }
    // 永远在评分这一刻重算：显示卡面时算的预览已经过时（学习步按分钟算，用出题时刻会偏一档；
    // 日志时刻也必须是评分时刻）。界面上的间隔预览只用于显示。
    final SrsAnswerPreview p = preview(
      cardId: cardId,
      history: history,
      config: config,
      ctx: ctx,
    );
    final SrsScheduleResult before = history.state;
    final Hlc hlc = ctx.clock.tick(p.nowMs);
    return SrsReviewLog(
      id: ctx.newId(p.nowMs),
      profileUid: ctx.profileUid,
      cardId: cardId,
      kind: SrsLogKind.review,
      rating: rating,
      hlc: hlc,
      occurredAt: p.nowMs,
      timeSource: p.timeSource,
      origin: SrsLogOrigin.fushi,
      reviewType: SrsReviewType.ofQueue(before.queue),
      durationMs: durationMs,
      paramsHash: srsParamsHash(p.algorithm, p.params),
      algorithm: p.algorithm.wire,
      utcOffsetMin: ctx.day.utcOffsetMin,
      dayRolloverHour: ctx.day.rolloverHour,
      result: p.plan[rating],
    );
  }

  /// 撤销：只允许撤销该卡当前最后一条有效日志；否则返回 null（界面提示「已在其它设备上复习过」）。
  SrsReviewLog? undo({
    required String cardId,
    required SrsCardHistory history,
    required String targetLogId,
    required SrsLogContext ctx,
  }) {
    if (!history.canUndo(targetLogId)) return null;
    return _event(
      cardId: cardId,
      kind: SrsLogKind.undo,
      reviewType: SrsReviewType.manual,
      ctx: ctx,
      revokesId: targetLogId,
    );
  }

  /// 手动改到期日。
  SrsReviewLog setDue({
    required String cardId,
    required SrsCardHistory history,
    required int dueDay,
    required SrsLogContext ctx,
  }) {
    final (int nowMs, _) = ctx.now();
    return _event(
      cardId: cardId,
      kind: SrsLogKind.manual,
      reviewType: SrsReviewType.manual,
      ctx: ctx,
      result: srsManualSetDue(
        history.state,
        dueDay: dueDay,
        today: ctx.day.dayIndexOf(nowMs),
      ),
    );
  }

  /// 设为新卡（重置）。
  SrsReviewLog reset({
    required String cardId,
    required SrsCardHistory history,
    required SrsLogContext ctx,
  }) => _event(
    cardId: cardId,
    kind: SrsLogKind.manual,
    reviewType: SrsReviewType.manual,
    ctx: ctx,
    result: srsManualReset(history.state),
  );

  /// 「立即重排整组」：按当前参数为这张卡重算到期（reschedule 日志）。
  SrsReviewLog? reschedule({
    required String cardId,
    required SrsCardHistory history,
    required SrsSchedulingConfig config,
    required SrsLogContext ctx,
  }) {
    final SrsScheduleResult cur = history.state;
    if (cur.queue != SrsQueue.review || cur.lastReviewedAt == null) return null;
    final SrsAlgorithm algorithm = config.algorithm.memoryAlgorithm;
    final SrsMemoryInput input = srsCollectMemoryInput(
      history,
      algorithm: algorithm,
      day: ctx.day,
    );
    final SrsMemory? memory = srsComputeMemory(
      input,
      engine: engine,
      algorithm: algorithm,
      params: config.params,
    );
    if (memory == null) return null;
    // 「立即重排」只重算 FSRS 间隔：RWKV 的间隔取决于作答当下整个 collection 的状态，
    // 对已经过去的复习回推没有意义（RWKV 牌组的卡在下次作答时按 RWKV 排）。
    final SrsNextStates next = engine.nextStates(
      algorithm: algorithm,
      params: config.params,
      desiredRetention: config.desiredRetention,
      memory: memory,
      elapsedDays: 0,
    );
    final int ivl = srsConstrainInterval(
      raw: next.good.interval,
      minimum: 1,
      config: config,
      cardId: cardId,
      reps: cur.reps,
    );
    final int lastDay = ctx.day.dayIndexOf(cur.lastReviewedAt!);
    return _event(
      cardId: cardId,
      kind: SrsLogKind.reschedule,
      reviewType: SrsReviewType.rescheduled,
      ctx: ctx,
      result: cur.copyWith(
        dueDay: lastDay + ivl,
        scheduledDays: ivl,
        memory: memory,
      ),
    );
  }

  /// 移交给 Anki 排程（卡在 Fushi 里只读、不进复习队列）。
  SrsReviewLog handOff({
    required String cardId,
    required SrsCardHistory history,
    required SrsLogContext ctx,
  }) => _event(
    cardId: cardId,
    kind: SrsLogKind.handOff,
    reviewType: SrsReviewType.manual,
    ctx: ctx,
    result: srsHandOff(history.state),
  );

  /// 收回到 Fushi 排程。与 handOff 对称：只有这个显式动作改 scheduler，
  /// 重新导入不改（第六轮审查「handOff 卡回导」：同一个操作必须同一种结果）。
  SrsReviewLog reclaim({
    required String cardId,
    required SrsCardHistory history,
    required SrsLogContext ctx,
  }) => _event(
    cardId: cardId,
    kind: SrsLogKind.handOff,
    reviewType: SrsReviewType.manual,
    ctx: ctx,
    result: srsReclaim(history.state),
  );

  SrsReviewLog _event({
    required String cardId,
    required String kind,
    required String reviewType,
    required SrsLogContext ctx,
    String? revokesId,
    SrsScheduleResult? result,
  }) {
    final (int nowMs, SrsTimeSource source) = ctx.now();
    final Hlc hlc = ctx.clock.tick(nowMs);
    return SrsReviewLog(
      id: ctx.newId(nowMs),
      profileUid: ctx.profileUid,
      cardId: cardId,
      kind: kind,
      revokesId: revokesId,
      hlc: hlc,
      occurredAt: nowMs,
      timeSource: source,
      origin: SrsLogOrigin.fushi,
      reviewType: reviewType,
      utcOffsetMin: ctx.day.utcOffsetMin,
      dayRolloverHour: ctx.day.rolloverHour,
      result: result,
    );
  }
}
