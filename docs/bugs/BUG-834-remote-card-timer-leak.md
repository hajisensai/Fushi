## BUG-834 · HomeVideoPage的videoBooks watch订阅dispose取消时遗留drift缓存保留Timer致isolate不退出+CI全量单测挂死60min
- **报告**：2026-07-15（用户：integration owner / CI 全量单测挂死）
- **真实性**：✅ 真 bug。运行期取证（flutter_test 打印的 pending-timer 创建栈）钉到根因：
  `_HomeVideoPageState.dispose` (`hibiki/lib/src/pages/implementations/home_video_page.dart:195`)
  取消 `_videoUidsSub`（`initState` 里 `widget.repo.watchVideoBookUids().listen(...)`，BUG-791/commit 74ca7bdb2 引入），
  该订阅底层是 drift **keyed** 查询流 `watchVideoBookUids()`（`packages/hibiki_core/lib/src/database/database.dart:2022`
  = `select(videoBooks).map(...).watch()`）。drift 的 `StreamQueryStore.markAsClosed`
  (`drift/src/runtime/executor/stream_queries.dart:156`) 在最后一个订阅取消时 `Timer.run(...)` 安排一个
  「缓存多留一会」的零时长 Timer。真机上下一拍即触发无害；但 widget 测试里 flutter_test 的
  `runApp(Container())` 清理帧先 dispose 页面 → 安排该 Timer → 随后单个 `pump()` 不触发它 →
  `_verifyInvariants`（`flutter_test/src/binding.dart:2542` `!timersPending`）断言失败，且 pending Timer
  令 flutter_tester isolate 永不退出 → 该 suite 挂死、CI 全量单测卡 60min。
- **纠正原诊断**：非「远端占位卡渲染路径」专属。经运行期验证，`home_video_partition_test` 与
  `home_video_collapse_test`（均**不**传 `remoteVideoClientLoader`、不渲远端卡）泄漏**同一个** Timer 并同样挂死；
  真凶是所有挂载 `HomeVideoPage` 的 suite 共有的 `_videoUidsSub`（BUG-791），受影响 = 全部 15 个 HomeVideoPage 页 suite，
  不止最初列的 7 个。原 bisect 指向 67f8f24f4（07-13 远端卡）早于真凶 74ca7bdb2（07-14）。
- **[x] ① 已修复** — `packages/hibiki_core/lib/src/database/database.dart:2022` `watchVideoBookUids()` 由 drift keyed
  `.watch()` 改为 `tableUpdates(TableUpdateQuery.onTable(videoBooks))` 驱动的 `async*` 流 + `select(videoBooks).get()`
  手动重查。`tableUpdates` 流不是 `QueryStream`、取消时不走 `markAsClosed`、不安排缓存保留 Timer，故切走视频页
  不再遗留孤儿 async。仅 `home_video_page` 消费此方法（经 `VideoBookRepository`），改动范围可控；BUG-791 的
  「任意导入路径落库后自动刷新库页」行为保持（表变更即重查，消费方 `_onVideoUidsChanged` 按集合去重）。
  提交：见本轮提交。
- **[x] ② 已加自动化测试** — 复用既有 widget 守卫：修前 7 个远端 suite + `home_video_partition_test` +
  `home_video_collapse_test` 全部因该 Timer 挂死（isolate 不退出）；修后逐个 `flutter test --no-pub --concurrency 1`
  全部 `All tests passed!`、零 `Timer is still pending`、进程正常退出（非墙钟杀）。这些既有 suite 即回归守卫——
  若该 Timer 泄漏复发，它们会再次挂死。测试文件：`hibiki/test/pages/home_video_remote_*_test.dart`（7）、
  `home_video_partition_test.dart`、`home_video_collapse_test.dart`。
- **备注**：这是 drift keyed stream 取消时的缓存保留 Timer（drift 源码注释明示：widget 测试请 `await Database.close()`）；
  真机非泄漏、纯测试期 teardown 时序暴露。`audio_recorder_page` 的订阅是 audio_session 流、非 drift watch，无此问题。
