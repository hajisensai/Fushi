/// 窗口超分状态 → 用户看得懂的话。
///
/// 分层理由与 `gal_hook_failure_text.dart` 完全一致（BUG-1100 的教训）：
/// [MagpieUpscalingStatus] / [MagpieProfileSkipReason] 是纯模型，诊断日志里保留它们的
/// 机器可读 `name`；**只有这里**把它们翻成人话。绝不把 `bootstrapFailed`、
/// `schemaMismatch` 这种内部枚举名甩到界面上——那正是当初 `engine_pcm_unavailable`
/// 被原样显示给用户的老毛病。
///
/// 每条文案都要回答用户的两个问题：**现在是什么状态**（[magpieUpscalingStatusLabel]）
/// 和 **我该做什么**（[magpieUpscalingActionHint]）。只说状态不说处置等于没说。
library;

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/mining/magpie_upscaling.dart';
import 'package:hibiki/src/mining/magpie_upscaling_service.dart';

/// 这个状态值不值得在界面上占一行。
///
/// `idle`（没在跑）与 `disabled`（用户自己关的）都不显示：用户关掉的功能不该反复提醒他
/// 关掉了，那是噪音不是信息。
bool magpieUpscalingWorthShowing(MagpieUpscalingReport report) =>
    switch (report.status) {
      MagpieUpscalingStatus.idle => false,
      MagpieUpscalingStatus.disabled => false,
      MagpieUpscalingStatus.preparing => false,
      MagpieUpscalingStatus.active => true,
      MagpieUpscalingStatus.hotkeyOnly => true,
      MagpieUpscalingStatus.unavailable => true,
      MagpieUpscalingStatus.failed => true,
    };

/// 一句话状态。
///
/// `active` 分两种说法：native 广播回填 [MagpieUpscalingReport.scalingActive] 之前，
/// 我们只知道「已经按自动缩放配置拉起了 Magpie」，还不知道它真的放大了没有。等广播到了
/// 才敢说「已开启」。**不拿意图冒充结果。**
String magpieUpscalingStatusLabel(MagpieUpscalingReport report) =>
    switch (report.status) {
      MagpieUpscalingStatus.active => report.scalingActive
          ? t.game_upscaling_status_active
          : t.game_upscaling_status_manual,
      MagpieUpscalingStatus.hotkeyOnly => t.game_upscaling_status_manual,
      MagpieUpscalingStatus.unavailable => t.game_upscaling_status_unavailable,
      MagpieUpscalingStatus.failed => t.game_upscaling_status_failed,
      MagpieUpscalingStatus.idle ||
      MagpieUpscalingStatus.disabled ||
      MagpieUpscalingStatus.preparing =>
        t.game_upscaling_status_unavailable,
    };

/// 「我该做什么」。返回 null 表示确实没有比状态本身更有用的话可说 —— 此时 UI 就只显示
/// 状态行，**绝不编造处置**（同 `galHookFailureLabel` 的约定）。
String? magpieUpscalingActionHint(MagpieUpscalingReport report) {
  switch (report.status) {
    case MagpieUpscalingStatus.active:
      // 真的在缩放就没什么要做的；还没收到广播时按「手动」给处置。
      return report.scalingActive ? null : t.game_upscaling_hint_manual;
    case MagpieUpscalingStatus.hotkeyOnly:
      return _hintForSkip(report);
    case MagpieUpscalingStatus.unavailable:
      return t.game_upscaling_hint_not_installed;
    case MagpieUpscalingStatus.failed:
      return switch (report.failureReason) {
        MagpieUpscalingFailureReason.bundleMissing =>
          t.game_upscaling_error_bundle_missing,
        MagpieUpscalingFailureReason.bundleInvalid =>
          t.game_upscaling_error_bundle_invalid,
        null => null,
      };
    case MagpieUpscalingStatus.idle:
    case MagpieUpscalingStatus.disabled:
    case MagpieUpscalingStatus.preparing:
      return null;
  }
}

/// 降级为热键模式时，按**原因**给不同的处置。
///
/// 这三条的区别对用户是实打实的：
/// - 首次初始化 → 下次就好了，**这是最常见的一条**，也是「装完第一次没反应」的真身；
/// - 已有别的 Magpie 在跑 → 永远不会自己好，得知道是我们有意不碰它；
/// - 其余（上游改了配置格式等）→ 说不出所以然，就只给通用处置，不瞎解释。
String _hintForSkip(MagpieUpscalingReport report) =>
    switch (report.profileSkipReason) {
      MagpieProfileSkipReason.bootstrapFailed =>
        t.game_upscaling_hint_first_run,
      MagpieProfileSkipReason.externalInstance =>
        t.game_upscaling_hint_external,
      _ => t.game_upscaling_hint_manual,
    };
