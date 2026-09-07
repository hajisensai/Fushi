## BUG-2207 · 重载在飞时 10s 进度轮询不门控，瞬态 atEnd 可把本章剩余计入
- **报告**：2026-09-06（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:1071`（修复前）`_refreshProgress` 只门 `_controller == null || _lyricsMode`，不看 `_restoreInFlight`；`_startProgressPoll`（`:300-306`）的 10s 定时器直接调它、不经 `readerScrollProgressRefreshAllowed`。`_reloadWithCurrentSettings`（`chrome.part.dart:2064`）置 `_restoreInFlight = true` 后整章重载在飞，此时 JS 的瞬态 atEnd / 章末 progress 被采到，「旧位置 → 章末」整段计成本次新读字数。
- **[x] ① 已修复** — 提交：`003149107a`；`_refreshProgress` 开头 `if (_controller == null || _lyricsMode || _restoreInFlight) return;`。已确认 reload 路径置真（`chrome.part.dart` `_restoreInFlight = true`），`_onRestoreComplete` / `_failNavigation` / reload catch 都清旗；`onReanchorSettled`（`webview.part.dart`）与 `_reanchorContinuousAfterRestore` 的补刷都在 `_restoreInFlight=false` 之后到达，不被误伤。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_study_clock_gate_guard_static_test.dart`「BUG-2207：_refreshProgress 首条门含 _restoreInFlight 且在采样之前」。
- **备注**：
