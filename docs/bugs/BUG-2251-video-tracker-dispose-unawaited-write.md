## BUG-2251 · VideoWatchTracker.dispose 在 dispose 里发起无人 await 的 DB 写
- **报告**：2026-09-07（用户：代码审查发现，非用户报告）
- **真实性**：✅ 真 bug（develop 既有欠账，不是 PR #1272 引入）。根因
  `fushi/lib/src/media/video/video_watch_tracker.dart:166` 的 `dispose()` 体是
  `unawaited(stop())`，而 `stop()` 会 `await _clock.stop()`（写 `study_segments`）+
  `_checkCompletion()`（写完成标记）+ `_persistCoverage()`（写覆盖并集偏好）。调用点
  `video_fushi_page.dart:3861` 的 `_watchTracker?.dispose()` 与
  `web_video_fushi_page.dart:476` 的 `unawaited(_watchTracker?.stop())` 都在页面
  `dispose()` 里——**这笔事务没有任何人持有它的 future**。
  两个后果：① widget 测试里 teardown 的 `db.close()` 与它互等（fake-async 在测试体
  结束后不再推进，事务续体永远不跑，drift 执行器锁不释放）——阅读三域的同形问题已在
  PR #1272 的 4 条漫画用例上确定性复现；视频侧目前只是恰好没有用例走到有脏段的 dispose。
  ② 生产上 app 退出时 `ExitFlushRegistry.flushAll()` → `db.close()` 与这笔在飞的写
  赛跑，最后一段观看时长可能丢。
  另注：`_checkCompletion()` 读 `_source`，而 `dispose()` 在 `unawaited(stop())`
  之后才 `_source = null`——异步续体跑到时 `_source` 多半已是 null，所以「dispose 时
  补一次完成判定」实际上早就不生效了，修复时按「不做」对齐即可，不是行为回退。
- **[ ] ① 未修复** — 修法对齐阅读三域（PR #1272）：`StudyClock` 已有零 IO 的
  `detach([settle])` 原语 + `ExitFlushRegistry.defer` 一次性延迟写汇合点。
  `VideoWatchTracker` 照此加 `detach()`：同步 `_sampler?.cancel()` + `_sample()` +
  摘 listener + `_source = null`，然后把整个 `stop` 交给 `deferWrite`（构造时由
  两个视频页传 `ExitFlushRegistry.instance.defer`），dispose 侧零 IO。
- **[ ] ② 未加自动化测试** — 加两层：`video_watch_tracker_test.dart` 断言 detach
  期间零 sink 写、跑完 deferred 才落库；源码守卫断言 `video_fushi_page` /
  `web_video_fushi_page` 的 `dispose()` 里不出现 `unawaited(...stop())` /
  `unawaited(_flushPosition())`（与
  `fushi/test/pages/reader_study_clock_gate_guard_static_test.dart` 同范式）。
- **备注**：不变式一句话——**DB 写只有三个入口：tick 定时器、调用方持有 future 的
  `stop()` / `flushNow()`、进程退出 registry；`dispose()` 不是入口**。阅读三域
  （EPUB / 漫画 / PDF）已在 PR #1272 里按此收口，视频域是最后一处未收的。
