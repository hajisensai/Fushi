## BUG-5241 · 音轨刷新定时器守卫从注释里也能找到 cancel，行为测试看不到存活的定时器
- **报告**：2026-11-22（审查 HBK-AUDIT-233，起因 PR #4092）
- **真实性**：✅ 真 bug（测试缺口，生产代码当前仍会取消）。`fushi/test/tools/gal_diagnostics_track_autorefresh_guard_test.dart:79` 用原串 `body.indexOf('_trackRefreshTimer?.cancel();')`，把 `_stopSourcesInternal` 里真实的取消行注释掉仍能命中；命中点在注释里时 `_braceDepthAt` 也回 1，守卫照样绿。行为测试 `fushi/test/mining/gal_hook_track_autorefresh_test.dart` 只数引擎调用，而停源后 `refreshAudioTracks` 因 `_engineSource == null` 提前返回，定时器还活着也观测不到。
- **[x] ① 已修复** — 守卫改用 `_codeIndexOf`：只认不在 `//` 注释与字符串里的出现位置。控制器加 `@visibleForTesting trackAutoRefreshActive`（`_trackRefreshTimer?.isActive`）。
- **[x] ② 已增加自动化测试** — 行为测试在 `stopCapture` 前后断言 `trackAutoRefreshActive` 由 true 变 false，直接验定时器注销。
- **备注**：
