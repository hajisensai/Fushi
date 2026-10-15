/// 新卡数按复习量自动调节（第一期补充，零弹窗）。
library;

/// 今天的新卡配额与缩减原因。
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

  /// 没缩减 = null；缩减 = reduced；超预算 2 倍 = paused。界面据此显示一行小字。
  final SrsNewCardBudgetReason? reason;
}

enum SrsNewCardBudgetReason { reduced, paused }

/// 计算今天的新卡数。
///
/// - 每日复习预算 = 最近 30 天「有复习的天」的日均复习数 × 1.5，且不低于 每日新卡上限 × 10；
/// - 最近 30 天里有复习的天数少于 7 天 =「数据不足」，预算 = 每日新卡上限 × 10；
/// - 到期复习数 ≤ 预算：系数 1；超过预算按比例减少；超过 2 倍预算：当天不出新卡。
SrsNewCardBudget srsComputeNewCardBudget({
  required int newPerDayLimit,
  required int dueReviews,
  required List<int> reviewsPerDayLast30,
}) {
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
    budget = (avg * 1.5).round();
    if (budget < floor) budget = floor;
  }
  if (budget <= 0 || dueReviews <= budget) {
    return SrsNewCardBudget(
      limit: newPerDayLimit,
      allowed: newPerDayLimit,
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
  // 预算到 2 倍预算之间线性减到 0。
  final double factor = 1 - (dueReviews - budget) / budget;
  final int allowed = (newPerDayLimit * factor).floor().clamp(
    0,
    newPerDayLimit,
  );
  return SrsNewCardBudget(
    limit: newPerDayLimit,
    allowed: allowed,
    reviewBudget: budget,
    reason: allowed < newPerDayLimit ? SrsNewCardBudgetReason.reduced : null,
  );
}
