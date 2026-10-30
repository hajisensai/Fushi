/// 新卡数按每周任务与复习量自动调节（零弹窗）。
library;

import 'deck.dart';

/// 今天的新卡配额与调整原因。
class SrsNewCardBudget {
  const SrsNewCardBudget({
    required this.limit,
    required this.allowed,
    required this.reviewBudget,
    required this.reason,
  });

  /// 牌组设置的每日新卡上限。
  final int limit;

  /// 今天实际出的新卡数（已扣掉今天已学的之前的值）。
  final int allowed;
  final int reviewBudget;

  /// 没调整 = null；其余见 [SrsNewCardBudgetReason]。界面据此显示一行小字。
  final SrsNewCardBudgetReason? reason;
}

enum SrsNewCardBudgetReason {
  /// 到期复习超过预算，按比例减少。
  reduced,

  /// 到期复习超过 2 倍预算，当天不出新卡。
  paused,

  /// 到期复习不到预算一半，按 [SrsNewCardPlan.boostPercent] 多出。
  increased,

  /// 本周新卡任务已完成。
  weekDone,
}

/// SRS 日序号（[SrsDayContext.dayIndexOf]）对应的星期：0 = 周一 … 6 = 周日。
/// 第 0 天是 1970-01-01（周四）。
int srsWeekdayOfDay(int dayIndex) => (dayIndex + 3) % 7;

/// [dayIndex] 所在周（周一起）的第一天。
int srsWeekStartDay(int dayIndex) => dayIndex - srsWeekdayOfDay(dayIndex);

/// 计算今天的新卡数。
///
/// 1. 每周任务（[SrsNewCardPlan.perWeek] > 0）：今天的基数 = ⌈本周剩余任务 ÷ 本周剩余天数（含今天）⌉，
///    不超过每日上限；本周剩余为 0 = 当天不出新卡（[SrsNewCardBudgetReason.weekDone]）。
///    没设每周任务时基数 = 每日上限。
/// 2. 按复习量调整（[SrsNewCardPlan.autoLoad]）：
///    - 每日复习预算 = 最近 30 天「有复习的天」的日均复习数 × [SrsNewCardPlan.budgetPercent]%，
///      且不低于 每日新卡上限 × 10；最近 30 天里有复习的天数少于 7 天 =「数据不足」，预算 = 每日新卡上限 × 10；
///    - 到期复习数 ≤ 预算：不变；超过预算按比例减少；超过 2 倍预算：当天不出新卡；
///    - 到期复习数 < 预算一半且 [SrsNewCardPlan.boostPercent] > 0：从一半预算到 0 线性增加，
///      最多 +boostPercent%，有每周任务时不超过本周剩余任务。
SrsNewCardBudget srsComputeNewCardBudget({
  required int newPerDayLimit,
  required int dueReviews,
  required List<int> reviewsPerDayLast30,
  SrsNewCardPlan plan = const SrsNewCardPlan(),
  int introducedThisWeekBeforeToday = 0,
  int daysLeftInWeek = 7,
}) {
  int base = newPerDayLimit;
  int? weekRemaining;
  if (plan.perWeek > 0) {
    final int remaining = plan.perWeek - introducedThisWeekBeforeToday;
    weekRemaining = remaining < 0 ? 0 : remaining;
    if (weekRemaining == 0) {
      return SrsNewCardBudget(
        limit: newPerDayLimit,
        allowed: 0,
        reviewBudget: 0,
        reason: SrsNewCardBudgetReason.weekDone,
      );
    }
    final int days = daysLeftInWeek.clamp(1, 7);
    final int spread = (weekRemaining + days - 1) ~/ days;
    if (spread < base) base = spread;
  }
  if (!plan.autoLoad) {
    return SrsNewCardBudget(
      limit: newPerDayLimit,
      allowed: base,
      reviewBudget: 0,
      reason: null,
    );
  }
  final List<int> active = <int>[
    for (final int n in reviewsPerDayLast30)
      if (n > 0) n,
  ];
  final int floor = newPerDayLimit * 10;
  int budget;
  if (active.length < 7) {
    budget = floor;
  } else {
    final double avg = active.reduce((int a, int b) => a + b) / active.length;
    budget = (avg * plan.budgetPercent / 100).round();
    if (budget < floor) budget = floor;
  }
  if (budget <= 0) {
    return SrsNewCardBudget(
      limit: newPerDayLimit,
      allowed: base,
      reviewBudget: budget,
      reason: null,
    );
  }
  if (dueReviews > budget * 2) {
    return SrsNewCardBudget(
      limit: newPerDayLimit,
      allowed: 0,
      reviewBudget: budget,
      reason: SrsNewCardBudgetReason.paused,
    );
  }
  if (dueReviews > budget) {
    // 预算到 2 倍预算之间线性减到 0。
    final double factor = 1 - (dueReviews - budget) / budget;
    final int allowed = (base * factor).floor().clamp(0, base);
    return SrsNewCardBudget(
      limit: newPerDayLimit,
      allowed: allowed,
      reviewBudget: budget,
      reason: allowed < base ? SrsNewCardBudgetReason.reduced : null,
    );
  }
  final double half = budget / 2;
  if (plan.boostPercent > 0 && dueReviews < half) {
    // 一半预算到 0 之间线性加到 +boostPercent%。
    final double share = 1 - dueReviews / half;
    int allowed = base + (base * plan.boostPercent / 100 * share).floor();
    if (weekRemaining != null && allowed > weekRemaining) {
      allowed = weekRemaining;
    }
    if (allowed > base) {
      return SrsNewCardBudget(
        limit: newPerDayLimit,
        allowed: allowed,
        reviewBudget: budget,
        reason: SrsNewCardBudgetReason.increased,
      );
    }
  }
  return SrsNewCardBudget(
    limit: newPerDayLimit,
    allowed: base,
    reviewBudget: budget,
    reason: null,
  );
}
