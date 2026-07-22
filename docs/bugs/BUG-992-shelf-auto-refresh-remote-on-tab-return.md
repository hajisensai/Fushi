## BUG-992 · 切回书架 tab 不自动拉远端书(远端书+书库概览总数要手动下拉刷新才补齐)
- **报告**：2026-07-14（用户：打开/切回书架时远端书没加载、总数只显示本地，要手动下拉刷新才对；要求「切回/打开自动拉一次」）
- **真实性**：✅ 真 bug/UX。根因：顶层 tab 走 IndexedStack 保活（BUG-750/TODO-376），书架页 State 常驻，`_remoteBooksFuture` 只在首帧 `??=` 懒加载一次（`reader_hibiki_history_page.dart:377`）；切到别的 tab 再切回不重跑 `_loadRemoteBooks` → 远端占位卡不刷新，`libraryTotal`（含远端，BUG-815）也停在旧值 → 用户以为「总数漏算远端」，实则是没重拉。只有手动 `_pullToRefreshBooks`（下拉）才重拉。
- **[x] ① 已实现（待真机验证）** — 书架页 initState 监听全局 `homeShellTabNotifier`（`home_page.dart` tab 切换信号），值变成 `HomeTab.books` 时自动 `_refreshRemoteBooks()`（`_onShellTabActivated`），dispose 移除监听。配套加 `_lastRemoteState` 缓存：远端 FutureBuilder 重拉期间（future→waiting、data 暂 null）沿用上次成功态，避免每次切回远端占位卡+总数闪一下（仿视频页 `_videosCache`；失败态不覆盖缓存）。
- **[x] ② 已加自动化测试** — `test/pages/reader_remote_interconnect_test.dart`：`_FakeRemoteBookClient.listRemoteBooksCalls` 计数；切到 `HomeTab.video`（不重拉）→ 切回 `HomeTab.books`（自动重拉），断言调用次数增长。
- **备注**：取 816 避让 origin/develop 已用的 808-810。视频页目前同样只在首帧拉一次远端（`_remoteFuture`），未同步改；用户如需视频页也自动刷新另开单。**未真机验证，勿宣称已修好。**
