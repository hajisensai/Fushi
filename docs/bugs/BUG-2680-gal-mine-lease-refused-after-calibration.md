## BUG-2680 · 校准后制卡截图租约被拒
- **报告**：2026-09-25（用户：ディメンション凸ラバース!!（Pal）里点制卡报 `窗口截图失败：GalHookCaptureSuppressionException: the attached glyph surface is no longer current`，制卡不了）
- **真实性**：✅ 真 bug，根因未定位。日志：14:49:26 校准采集进入 `captureSuppressed`；14:51:15、14:51:19 两次制卡失败，14:52:14 在同样状态下成功。三次制卡前 Dart 状态相同，都是 `suspended/low_level_mouse_arm_failed:singleton_owned_by_other_hwnd`，这个状态在 BUG-2679 修复（`9c6dd402c8`）后已放行，所以拒绝来自 `GalAttachedTextController.acquireMiningCaptureLease` 的其他条件：`_activeCaptureLease != null`、`_sentSourceText != _latestSourceText`、`_activeVariant == null`、`!_attachedProviderClaimed`、`generation <= 0`，或 native `suspendForCapture` 失败。校准采集成功完成，说明那次租约已正常释放，「租约未释放」的猜测不成立。剩下最可能的是查词窗口开着时台词或档案变体有变化：14:51:47 新加的 host 日志记录 `dropped reason=status_suspended/state_event_layout_pending`，说明应用新档案后，变体切换存在未就绪期。以上条件被拒时都没有原因日志，无法进一步区分。
- **[ ] ① 未修复** — 本 PR 暂不修。下一步：给租约拒绝和释放写原因日志，把 `GalHookCaptureSuppressionException` 的英文原文换成按原因区分的中文提示，再按日志修根因。
- **[ ] ② 未加自动化测试**
- **备注**：临时绕法（推测，未验证）：校准完后先回到游戏翻一句台词再制卡。
