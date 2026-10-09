## BUG-3228 · 排行榜总字数卡加载失败后永远停在加载条
- **报告**：2026-10-09（集成审查 #2039 时发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/leaderboard/leaderboard_tab.dart` `_refreshSummary()` 的 catch 只写日志，`_summaryTotal` 保持 null；`LeaderboardCharsSummaryCard` 把 `total == null` 一律画成加载条，于是两次 rank 请求任一失败（断网 / 503）卡片就永远转着，下拉刷新再失败也一样。
- **[x] ① 已修复** — 页面记下 `_summaryError`（成功时清空），卡片新增 `error` 参数：`total == null && error != null` 时显示 `leaderboardErrorText(error)` 代替加载条；已有数时刷新失败保留旧数。
- **[x] ② 已加自动化测试** — `fushi/test/leaderboard_ui/leaderboard_ui_test.dart`「总字数卡：加载失败显示原因，不永远停在加载条上」。
- **备注**：
