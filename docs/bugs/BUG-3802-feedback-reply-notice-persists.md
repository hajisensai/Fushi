## BUG-3802 · 反馈回复提示条常驻不消失、遮挡提交按钮
- **报告**：2026-10-25（用户：反馈 eiFcN3DZQ3，电脑端，「这个提示条不会自动消除，挡住了我的反馈提交按钮」；深色主题下 × 几乎看不见）
- **真实性**：✅ 真 bug。`showFeedbackReplyNotice` 带「查看」动作，`SnackBar` 的 `persist ?? action != null` 让它常驻（`fushi/lib/src/pages/implementations/feedback/feedback_common.dart:919`）；BUG-3357 只补了关闭按钮。关闭按钮图标用 `IconButton` 默认前景色（onSurfaceVariant），与 MD3 提示条底色 inverseSurface 同深浅（`fushi/lib/src/utils/components/glass/fushi_glass_overlays.dart` `_FushiSnackBarCloseButton`）。
- **[x] ① 已修复** — 回复提示是被动提醒：显式 `persist: false` + `kFeedbackReplyNoticeDuration`（6 秒）自动收起，未读红点照常亮；常驻提示条的关闭图标改用 `SnackBarTheme.closeIconColor ?? onInverseSurface`（玻璃用 secondaryLabel），与原生 showCloseIcon 同口径。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_reply_notifier_test.dart`（不补常驻关闭按钮、到时自动消失）。
- **备注**：关闭图标对比度属视觉，未做设备截图。
