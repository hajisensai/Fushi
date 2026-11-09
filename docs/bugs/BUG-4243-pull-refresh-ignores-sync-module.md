## BUG-4243 · 下拉刷新无视「同步与备份」模块开关仍触发同步
- **报告**：2026-11-09（用户：应用内反馈 SJeJd5EEZO，android 3.3.0-debug.24478）
- **真实性**：✅ 真 bug。下拉刷新 = 手动同步，模块门只在书架页写了一份（`fushi/lib/src/pages/implementations/reader_history/remote.part.dart:220` 判 `ModuleId.sync`）；词典页 `fushi/lib/src/pages/implementations/home_dictionary_page.dart:686` 的 `_pullToRefreshDictionary` 与视频页 `fushi/lib/src/pages/implementations/home_video_page.dart:1208` 的 `_pullToRefresh` 直接调 `runManualSyncWithFeedback`，没过门。关掉「同步与备份 + 互联」模块后，在视频 / 词典页下拉照样跑一轮 `runManualFullSync`，同步进度条也会出现。
- **[x] ① 已修复** — 门收进 `fushi/lib/src/sync/manual_sync_ui.dart` 新增的 `runPullToRefreshSync`（模块关 → 返回 notConfigured、不跑同步、不出提示；模块开 → 关掉 notConfigured / busy 提示的 `runManualSyncWithFeedback`），三页下拉只调它，不再各写一份门。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/sync/pull_to_refresh_sync_module_gate_test.dart`：模块关时（在飞同步下）返回 notConfigured、不进同步外壳、无 SnackBar；模块开时进外壳返回 busy；源码守卫钉住三页不直调 `runManualSyncWithFeedback`（修复前视频 / 词典页直调，守卫红）。
- **备注**：反馈另一半「关掉模块后正在进行的同步 / 定时同步仍在跑到本次会话结束」属于产品决策（`app_model.dart` 模块门注释写明「正在跑的照常跑完，下次启动才不再拉起」），本条未改。悬浮球「同步」按钮与 ctl 同步路由仍直调同步外壳，未纳入本门。
