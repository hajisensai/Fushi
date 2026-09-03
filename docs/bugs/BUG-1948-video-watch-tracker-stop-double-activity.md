## BUG-1948 · VideoWatchTracker.stop 在 await 后才清零累计器：dispose 与进程退出并发各写一条活动行
- **报告**：2026-08-29（用户：「统计经常有重复统计」；本条是沿写入链验出的具体双写点）
- **真实性**：✅ 真 bug。根因（修前）`fushi/lib/src/media/video/video_watch_tracker.dart:165-176`：`stop()` 先 `await _flush()`，之后才读取并清零 `_sessionWatchMs` / `_sessionChars`。`video_fushi_page.dart` 的 dispose 路径 `unawaited(stop())`（`:3723`）与进程退出路径 `await stop()`（`:2002`）、以及生命周期 paused 的 `stop()`（`:1944`）可并发——第二条 stop 在第一条的 await 挂起期读到同一个 `ms > 0`，各写一条 `activity_events`（该表无唯一约束、注释明写「不去重」），首页活动流该次观看时长翻倍。同类形状：`reading_statistics` / `video_watch_statistics` / `*_hourly_logs` 全是 `+=` 累加、无幂等键，任何路径 flush 两次即永久翻倍。
- **[x] ① 已修复** — 结构性：`VideoWatchTracker` 不再持有任何累计器（`packages/fushi_audio/lib/src/audiobook/study_clock.dart` `StudyClock` 是唯一时钟兼累计器），`StudyClock.stop()` 的取值 / 清引用 / 取消定时器全在第一个 `await` 之前，第二条并发 stop 看到的是已清空状态；落库是按 uid 绝对值 upsert，重复 flush 是同值覆盖而非累加。提交：本分支。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/study_clock_test.dart`「两条并发 stop 只落一份终值」「两次 flushNow 同 uid 同值」「写失败重试不累加」+ `fushi/test/tools/statistics_write_convergence_guard_test.dart` ⑦（源码守卫：stop 清引用在首个 await 之前、写侧无 `+=`）。
- **备注**：历史已翻倍的 activity 行不回溯。
