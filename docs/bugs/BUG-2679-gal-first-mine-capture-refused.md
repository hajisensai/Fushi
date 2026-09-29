## BUG-2679 · 查词窗口里第一次点制卡截图被拒
- **报告**：2026-09-25（用户：在游戏内查词窗口里点制卡，第一次失败，第二次成功）
- **真实性**：✅ 真 bug，既有问题（同一报错 9-19 出现 8 次，9-24 出现 4 次）。日志 12:34:24.667 显示 `窗口截图失败：GalHookCaptureSuppressionException: the attached glyph surface is no longer current`，点击后 5 ms 即被拒。制卡截图前要先隐藏查词层，而 `GalAttachedTextController.acquireMiningCaptureLease` 只接受 `activeAttached`，或查词窗口占用鼠标的那一种状态（`mouseHookBusy` + `singleton_owned_by_other_hwnd`）。点制卡按钮这一下会让拦截短暂进入 `conflicting_transaction_pending`，随后进入 `input_shield_rehandshake_pending`；撞上这两种过渡状态，就返回 null。native 的 `SuspendForCapture` 只核对 epoch 和台词代数，并不关心输入状态。
- **[x] ① 已修复** — `9c6dd402c8`：查词窗口开着时，这两种输入过渡状态也允许制卡截图；`worker_unavailable`、握手不可用、台词已变化等真实故障仍然拒绝。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_attached_text_controller_test.dart`：`conflicting_transaction_pending` 和 `input_shield_rehandshake_pending` 可以取得截图租约，握手不可用时拒绝；原有「其他故障 / 台词变化不能用」测试保留。
- **备注**：未实机复验。
