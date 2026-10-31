/// 新卡数按复习量自动调节（零弹窗）的结果类型。
///
/// 规则只在 Rust 排队内核里（native/fushi_fsrs/src/store/study.rs `new_card_budget`，读牌组的
/// [SrsNewCardPlan]）：牌组计数与出卡 2026-10 整段搬进内核后，Dart 版计算已删（留着它就是第二份
/// 规则——PR #2663 当初就改在了这份不再被调用的 Dart 上，设置能存、出卡不认）。
library;

import 'deck.dart';

/// 今天的新卡配额与调整原因（内核计数行的后四项，`SrsDbStore._summaryFrom`）。
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

  /// 复习预算（[SrsNewCardPlan.autoLoad] 关掉时为 0）。
  final int reviewBudget;

  /// 没调整 = null；其余见 [SrsNewCardBudgetReason]。界面据此显示一行小字。
  final SrsNewCardBudgetReason? reason;
}

/// 名字就是内核结果里的原因串（`SrsNewCardBudgetReason.values.byName`），改名要两边一起改。
enum SrsNewCardBudgetReason {
  /// 到期复习超过预算，按比例减少。
  reduced,

  /// 到期复习超过 2 倍预算，当天不出新卡。
  paused,

  /// 到期复习不到预算一半，按 [SrsNewCardPlan.boostPercent] 多出。
  increased,
}
