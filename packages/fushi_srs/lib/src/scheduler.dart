/// 上层排程策略（参照 rslib v3 调度器）：学习 / 重学步长、毕业、确定性 fuzz、最大间隔。
/// 记忆状态与间隔由 FSRS 算（[FsrsEngine]），本文件只把它们落成队列与到期。
library;

import 'algorithm.dart';
import 'day.dart';
import 'fsrs_engine.dart';
import 'review_log.dart';

/// 一个牌组的排程配置（来自牌组设置，参数组按算法取）。
class SrsSchedulingConfig {
  const SrsSchedulingConfig({
    this.learnStepsMinutes = const <double>[1, 10],
    this.relearnStepsMinutes = const <double>[10],
    this.desiredRetention = 0.8,
    this.maxIntervalDays = 36500,
    this.algorithm = srsDefaultAlgorithm,
    this.params = const <double>[],
    this.fuzz = true,
  });

  /// 学习 / 重学步长只允许当天以内（< 1 天，PR1 硬规则），由 [srsValidateSteps] 校验。
  final List<double> learnStepsMinutes;
  final List<double> relearnStepsMinutes;
  final double desiredRetention;
  final int maxIntervalDays;
  final SrsAlgorithm algorithm;

  /// 空 = 该算法默认参数。
  final List<double> params;
  final bool fuzz;
}

/// 步长校验：每项 > 0 且 < 1 天（1440 分钟）。返回剔除非法项后的列表；
/// 全被剔除时用默认步长（导入 Anki 的 1d / 3d 这类步长走这里）。
///
/// 空列表 = 不用步长（Anki 语义：新卡 / 答错的卡直接进复习），原样返回空；只有给了步长但全被剔除
/// （都 ≥ 1 天或非正）才用 [fallback]。
List<double> srsSanitizeSteps(List<double> steps, List<double> fallback) {
  if (steps.isEmpty) return const <double>[];
  final List<double> ok = <double>[
    for (final double s in steps)
      if (s > 0 && s < 1440) s,
  ];
  return ok.isEmpty ? fallback : ok;
}

/// 设置页输入校验：有 ≥ 1 天的项直接拒绝。
bool srsValidateSteps(List<double> steps) =>
    steps.every((double s) => s > 0 && s < 1440);

const int _minuteMs = 60000;

/// 一次评分的上下文。
class SrsAnswerContext {
  const SrsAnswerContext({
    required this.cardId,
    required this.current,
    required this.nowMs,
    required this.day,
    required this.config,
  });

  final String cardId;

  /// 最后一条有效日志的结果（新卡 = [SrsScheduleResult.initial]）。
  final SrsScheduleResult current;
  final int nowMs;
  final SrsDayContext day;
  final SrsSchedulingConfig config;

  int get today => day.dayIndexOf(nowMs);

  /// 下次评分的 elapsed：评分时刻 − lastReviewedAt（空 = 新卡 = 0），不用最后一条日志的操作时刻。
  double elapsedDaysFor(SrsAlgorithm algorithm) {
    final int? last = current.lastReviewedAt;
    if (last == null || nowMs <= last) return 0;
    return switch (algorithm.memoryAlgorithm) {
      SrsAlgorithm.fsrs7 ||
      SrsAlgorithm.rwkv => (nowMs - last) / (24 * 60 * _minuteMs),
      SrsAlgorithm.fsrs6 =>
        (day.dayIndexOf(nowMs) - day.dayIndexOf(last)).toDouble(),
    };
  }
}

/// splitmix64：跨平台确定的伪随机（Dart 原生 int 是 64 位补码）。
int _splitmix64(int x) {
  int z = x + 0x9E3779B97F4A7C15;
  z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
  z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
  return z ^ (z >>> 31);
}

/// [0, 1) 的确定性随机数：种子 = hash(cardId) + reps。
double srsFuzzFactor(String cardId, int reps) {
  int h = 0xcbf29ce484222325;
  for (final int c in cardId.codeUnits) {
    h = (h ^ c) * 0x100000001b3;
  }
  final int r = _splitmix64(h + reps);
  return (r >>> 11) / 9007199254740992.0;
}

/// Anki 的 fuzz 区间（rslib scheduler/states/fuzz.rs）。
({int min, int max}) srsFuzzRange(double interval, int minimum, int maximum) {
  if (interval < 2.5) {
    final int v = interval.round().clamp(minimum, maximum);
    return (min: v, max: v);
  }
  const List<(double, double, double)> ranges = <(double, double, double)>[
    (2.5, 7.0, 0.15),
    (7.0, 20.0, 0.1),
    (20.0, double.infinity, 0.05),
  ];
  double delta = 1.0;
  for (final (double start, double end, double factor) in ranges) {
    delta +=
        factor *
        ((interval < end ? interval : end) - start).clamp(0, double.infinity);
  }
  int lo = (interval - delta).round();
  int hi = (interval + delta).round();
  lo = lo.clamp(minimum, maximum);
  hi = hi.clamp(minimum, maximum);
  if (lo > hi) lo = hi;
  return (min: lo, max: hi);
}

/// 把 FSRS 给的小数间隔落成整天：取整、fuzz、夹在 [minimum, 最大间隔]。
int srsConstrainInterval({
  required double raw,
  required int minimum,
  required SrsSchedulingConfig config,
  required String cardId,
  required int reps,
}) {
  final int maximum = config.maxIntervalDays < minimum
      ? minimum
      : config.maxIntervalDays;
  if (!config.fuzz) {
    return raw.round().clamp(minimum, maximum);
  }
  final ({int min, int max}) range = srsFuzzRange(raw, minimum, maximum);
  final double f = srsFuzzFactor(cardId, reps);
  return range.min +
      (f * (range.max - range.min + 1)).floor().clamp(0, range.max - range.min);
}

/// 四个评分各自的结果（还没写成日志）。
class SrsAnswerPlan {
  const SrsAnswerPlan(this.byRating);

  final Map<int, SrsScheduleResult> byRating;

  SrsScheduleResult operator [](int rating) => byRating[rating]!;
}

/// 算出四个评分各自的「这次操作后」结果。
///
/// [next] 是用当前记忆状态（由历史重建）与 elapsed 调 FSRS 得到的下一状态。
SrsAnswerPlan srsPlanAnswer(SrsAnswerContext ctx, SrsNextStates next) {
  final SrsScheduleResult cur = ctx.current;
  final SrsSchedulingConfig cfg = ctx.config;
  final int today = ctx.today;
  final int now = ctx.nowMs;
  final int reps = cur.reps + 1;

  SrsScheduleResult learning(
    SrsQueue queue,
    int step,
    double delayMinutes,
    SrsMemory memory,
    int lapses,
  ) => SrsScheduleResult(
    queue: queue,
    dueAt: now + (delayMinutes * _minuteMs).round(),
    scheduledDays: 0,
    learningStep: step,
    memory: memory,
    lastReviewedAt: now,
    reps: reps,
    lapses: lapses,
    scheduler: cur.scheduler,
  );

  SrsScheduleResult reviewAt(int ivl, SrsMemory memory, int lapses) =>
      SrsScheduleResult(
        queue: SrsQueue.review,
        dueDay: today + ivl,
        scheduledDays: ivl,
        learningStep: 0,
        memory: memory,
        lastReviewedAt: now,
        reps: reps,
        lapses: lapses,
        scheduler: cur.scheduler,
      );

  int ivlOf(double raw, {int minimum = 1}) => srsConstrainInterval(
    raw: raw,
    minimum: minimum,
    config: cfg,
    cardId: ctx.cardId,
    reps: reps,
  );

  // 复习卡的三个通过评分：hard ≤ good ≤ easy 且严格递增，
  // fuzz 不让 Good / Easy 的新间隔小于上次间隔（#4431）。
  (int, int, int) passingIntervals({required bool fromReview}) {
    final int prev = fromReview ? cur.scheduledDays : 0;
    int hard = ivlOf(next.hard.interval);
    int good = ivlOf(next.good.interval, minimum: hard + (fromReview ? 1 : 0));
    if (fromReview && next.good.interval >= prev && good < prev) good = prev;
    if (good <= hard && fromReview) good = hard + 1;
    int easy = ivlOf(next.easy.interval, minimum: good + 1);
    if (fromReview && next.easy.interval >= prev && easy < prev) easy = prev;
    if (easy <= good) easy = good + 1;
    final int max = cfg.maxIntervalDays;
    hard = hard.clamp(1, max);
    good = good.clamp(1, max);
    easy = easy.clamp(1, max);
    return (hard, good, easy);
  }

  final Map<int, SrsScheduleResult> out = <int, SrsScheduleResult>{};
  switch (cur.queue) {
    case SrsQueue.newCard:
    case SrsQueue.learning:
      final List<double> steps = cfg.learnStepsMinutes;
      final int step = cur.queue == SrsQueue.newCard ? 0 : cur.learningStep;
      final (int _, int good, int easy) = passingIntervals(fromReview: false);
      out[1] = steps.isEmpty
          ? reviewAt(ivlOf(next.again.interval), next.again.memory, cur.lapses)
          : learning(
              SrsQueue.learning,
              0,
              steps.first,
              next.again.memory,
              cur.lapses,
            );
      out[2] = steps.isEmpty
          ? reviewAt(ivlOf(next.hard.interval), next.hard.memory, cur.lapses)
          : learning(
              SrsQueue.learning,
              step,
              _hardDelay(steps, step),
              next.hard.memory,
              cur.lapses,
            );
      out[3] = step + 1 < steps.length
          ? learning(
              SrsQueue.learning,
              step + 1,
              steps[step + 1],
              next.good.memory,
              cur.lapses,
            )
          : reviewAt(good, next.good.memory, cur.lapses);
      out[4] = reviewAt(easy, next.easy.memory, cur.lapses);
    case SrsQueue.review:
      final List<double> rsteps = cfg.relearnStepsMinutes;
      final int lapses = cur.lapses + 1;
      out[1] = rsteps.isEmpty
          ? reviewAt(ivlOf(next.again.interval), next.again.memory, lapses)
          : learning(
              SrsQueue.relearning,
              0,
              rsteps.first,
              next.again.memory,
              lapses,
            );
      final (int hard, int good, int easy) = passingIntervals(fromReview: true);
      out[2] = reviewAt(hard, next.hard.memory, cur.lapses);
      out[3] = reviewAt(good, next.good.memory, cur.lapses);
      out[4] = reviewAt(easy, next.easy.memory, cur.lapses);
    case SrsQueue.relearning:
      final List<double> rsteps = cfg.relearnStepsMinutes;
      final int step = cur.learningStep;
      final (int _, int good, int easy) = passingIntervals(fromReview: false);
      out[1] = rsteps.isEmpty
          ? reviewAt(ivlOf(next.again.interval), next.again.memory, cur.lapses)
          : learning(
              SrsQueue.relearning,
              0,
              rsteps.first,
              next.again.memory,
              cur.lapses,
            );
      out[2] = rsteps.isEmpty
          ? reviewAt(ivlOf(next.hard.interval), next.hard.memory, cur.lapses)
          : learning(
              SrsQueue.relearning,
              step,
              _hardDelay(rsteps, step),
              next.hard.memory,
              cur.lapses,
            );
      out[3] = step + 1 < rsteps.length
          ? learning(
              SrsQueue.relearning,
              step + 1,
              rsteps[step + 1],
              next.good.memory,
              cur.lapses,
            )
          : reviewAt(good, next.good.memory, cur.lapses);
      out[4] = reviewAt(easy, next.easy.memory, cur.lapses);
  }
  return SrsAnswerPlan(out);
}

/// Hard 在学习步上的延迟（rslib learning.rs）：第一步 = 前两步的平均（只有一步时 ×1.5，最多多一天）；其它步 = 当前步。
double _hardDelay(List<double> steps, int step) {
  if (step > 0) return steps[step.clamp(0, steps.length - 1)];
  if (steps.length >= 2) return (steps[0] + steps[1]) / 2;
  final double plus = steps[0] * 1.5;
  final double cap = steps[0] + 1440;
  return plus < cap ? plus : cap;
}

/// 是否到期。学习卡允许提前 20 分钟（Anki 的 learn ahead）。
bool srsIsDue(
  SrsScheduleResult s, {
  required int nowMs,
  required int today,
  int learnAheadMs = 20 * _minuteMs,
}) => switch (s.queue) {
  SrsQueue.newCard => false,
  SrsQueue.learning ||
  SrsQueue.relearning => (s.dueAt ?? 0) <= nowMs + learnAheadMs,
  SrsQueue.review => (s.dueDay ?? 0) <= today,
};

/// 「manual 改到期 / 改间隔」的结果：四项（lastReviewedAt / reps / lapses / scheduler）沿用。
SrsScheduleResult srsManualSetDue(
  SrsScheduleResult current, {
  required int dueDay,
  required int today,
}) => current.copyWith(
  queue: SrsQueue.review,
  dueDay: dueDay,
  dueAt: null,
  clearDue: true,
  scheduledDays: (dueDay - today).clamp(1, 1 << 30),
  learningStep: 0,
);

/// 「manual 重置（设为新卡）」：lastReviewedAt = 空，reps = lapses = 0；记忆状态的新起点。
SrsScheduleResult srsManualReset(SrsScheduleResult current) =>
    SrsScheduleResult(queue: SrsQueue.newCard, scheduler: current.scheduler);

/// handOff：只把 scheduler 改为 anki，其余沿用。
SrsScheduleResult srsHandOff(SrsScheduleResult current) =>
    current.copyWith(scheduler: SrsScheduler.anki);

/// 收回（Anki → Fushi）：只把 scheduler 改回 fushi，其余沿用。
SrsScheduleResult srsReclaim(SrsScheduleResult current) =>
    current.copyWith(scheduler: SrsScheduler.fushi);

/// 评分按钮间隔的单位（与 Anki 答题按钮同一套：分钟 / 小时 / 天 / 月 / 年）。
enum SrsIntervalUnit { minutes, hours, days, months, years }

/// 评分按钮预览的间隔：数值（已按 Anki 的精度格式化）+ 单位。单位文案由界面层按
/// 语言给（本包不依赖 i18n）。<1 天显示分钟 / 小时，否则天 / 月 / 年。
({String amount, SrsIntervalUnit unit}) srsIntervalParts(
  SrsScheduleResult s, {
  required int nowMs,
  required int today,
}) {
  if (s.queue == SrsQueue.learning || s.queue == SrsQueue.relearning) {
    final int mins = (((s.dueAt ?? nowMs) - nowMs) / _minuteMs).round();
    if (mins < 60) {
      return (amount: '${mins < 1 ? 1 : mins}', unit: SrsIntervalUnit.minutes);
    }
    return (
      amount: (mins / 60).toStringAsFixed(mins < 600 ? 1 : 0),
      unit: SrsIntervalUnit.hours,
    );
  }
  final int days = (s.dueDay ?? today) - today;
  if (days < 30) return (amount: '$days', unit: SrsIntervalUnit.days);
  if (days < 365) {
    return (
      amount: (days / 30).toStringAsFixed(1),
      unit: SrsIntervalUnit.months,
    );
  }
  return (amount: (days / 365).toStringAsFixed(1), unit: SrsIntervalUnit.years);
}

/// [srsIntervalParts] 的英文缩写形态（Anki 英文答题按钮同款：m / h / d / mo / y），
/// 供日志与测试；界面一律按语言格式化。
String srsFormatInterval(
  SrsScheduleResult s, {
  required int nowMs,
  required int today,
}) {
  final ({String amount, SrsIntervalUnit unit}) p = srsIntervalParts(
    s,
    nowMs: nowMs,
    today: today,
  );
  return '${p.amount}${switch (p.unit) {
    SrsIntervalUnit.minutes => 'm',
    SrsIntervalUnit.hours => 'h',
    SrsIntervalUnit.days => 'd',
    SrsIntervalUnit.months => 'mo',
    SrsIntervalUnit.years => 'y',
  }}';
}
