## BUG-3235 · 反馈处理台列表被取代的旧请求仍清加载中并写错误
- **报告**：2026-10-10（上一轮 PR 审查遗留疑点）
- **真实性**：✅ 真 bug（PR #2021）。根因 `fushi/lib/src/pages/implementations/feedback/feedback_dev_page.dart` `_load`（原 :128-131）：已有请求代号 `_generation`，但只在成功分支丢弃过期结果；被新筛选 / 搜索取代的旧请求失败时仍 `_error = …`、在 finally 里仍 `_loading = false`——新请求还在途就把刷新按钮放开、首屏还空时直接显示「刷新失败」。
- **[x] ① 已修复** — 提交「fix(feedback): drop stale inbox requests' error and loading state」：catch / finally 同样只在 `generation == _generation` 时落状态。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_pages_test.dart`「BUG-3235 处理台列表：被搜索取代的旧请求晚到失败…」（服务端桩按搜索词挂住 / 放行请求，旧请求晚到 500）。
- **备注**：
