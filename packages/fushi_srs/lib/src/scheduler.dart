/// 排程配置、步长校验、评分预览的值对象与间隔显示。
///
/// 排程本身（学习 / 重学步长、毕业、确定性 fuzz、最大间隔、手动改期 / 重置 / 立即重排）只在 Rust 里算一份：
/// native/fushi_fsrs/src/sync2/sched.rs（评分预览 / 作答经 `preview` / `apply`，手动操作经 `sched` 命令）。
library;

import 'algorithm.dart';
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

/// 四个评分各自的结果（还没写成日志）。
class SrsAnswerPlan {
  const SrsAnswerPlan(this.byRating);

  final Map<int, SrsScheduleResult> byRating;

  SrsScheduleResult operator [](int rating) => byRating[rating]!;
}

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
