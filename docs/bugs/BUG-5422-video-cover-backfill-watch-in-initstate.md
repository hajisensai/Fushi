## BUG-5422 · video-cover-backfill-watch-in-initstate
- **报告**：2026-11-25（合并 PR #4376 前审查，定向测试 `home_video_floating_toolbar_test.dart` 两条红）
- **真实性**：✅ 真 bug。BUG-5387（PR #4364）把视频封面回填包进 `appModel.database.runBackgroundWork`，而 `_HomeVideoPageState._maybeBackfillCovers` 由 `initState` 同步调用、首个 `await` 之前就读 `appModel`（`fushi/lib/src/pages/implementations/home_video_page.dart` 回填 try 块；`BasePageState.appModel` 是 `ref.watch`，`fushi/lib/src/pages/base_page.dart:40`）。debug 下每次挂载视频库页都断言「dependOnInheritedWidgetOfExactType<UncontrolledProviderScope>() … called before initState() completed」，回填整轮被掀掉；release 断言编译掉，侥幸能跑。
- **[x] ① 已修复** — 回填改用不订阅的 `appModelNoUpdate.database`（后台循环本就不该订阅 provider）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_floating_toolbar_test.dart` 两条用例挂载视频库页即覆盖（修前断言红）；用例体结束前卸掉页面、边推进真实时间边 pump 直到关库完成（`unmountAndCloseDb`）。
- **备注**：BUG-5387 后关库要等后台工作退出；回填里的真实文件 I/O 回调落在 testWidgets 的假时间 zone，用例体结束后没人 pump，tearDown 的 `db.close()` 会永远等下去（实测该文件第二条用例挂满 10 分钟）。其它挂载视频库页、tearDown 里直接 `db.close()` 的测试（`fushi/test` 下约 47 个文件引用 `VideoLibraryShell` / `HomeVideoPage`）有同样的按时序挂起风险，未逐个改，待全量 CI 结果按同一办法处理。
