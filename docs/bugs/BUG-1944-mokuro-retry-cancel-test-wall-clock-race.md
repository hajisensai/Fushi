## BUG-1944 · mokuro 退避取消测试拿真时钟当同步原语，CI 上偶发红
- **报告**：2026-08-29（发现于 PR #1054 的 CI：该 PR 只改浏览器扩展，却红在这条与它无关的测试上）
- **真实性**：✅ 真 bug（测试自身的缺陷，不是被测代码）。根因 `fushi/test/media/manga/online/mokuro_moe_download_queue_test.dart:238`：退避被设成 `Duration(milliseconds: 10)`，随后用 `await pumpEventQueue()` 让错误传播，再断言 `task.status == waitingRetry`。`pumpEventQueue()` 会反复 yield 回事件循环，在负载高的 CI runner 上真实耗时轻易超过 10ms——重试定时器先烧掉，回调把状态推回 `queued` 并 `_pump()` 起下一次下载，断言拿到的是 `running`。即测试把**真实墙钟**当成了同步原语。
  - 实证：`Build Release APK` job 99085845373（PR #1054，head 与 mokuro 队列零交集）`FLUTTER TEST VERDICT: FAILED`，唯一失败即本条，`Expected: waitingRetry / Actual: running`；同期 develop 上同一 workflow 连续 12 次 success。
- **[x] ① 已修复** — 改用假时钟：`fakeAsync` + `async.flushMicrotasks()` 让错误传播，`async.elapse()` 显式推进过退避。退避时长同时从 10ms 提到 10s，进一步与任何真实耗时脱钩。被测代码 `mokuro_moe_download_queue.dart` **未改动**（`_finish` 全同步、不碰 DB，落在 `fakeAsync` 可控范围内）。
- **[x] ② 已加自动化测试** — 同文件同名用例。顺带修掉一个既有的**弱断言**：原用例只断言 `r.calls` 长度，但 `cancel()` 对非执行中的任务只做 `_tasks.remove(task)`、**不改 `task.status`**，所以定时器即使没被掐掉，到期回调里的 `_pump()` 也扫不到这条已移出队列的任务，`r.calls` 恒为 1——变异实测（删掉 `mokuro_moe_download_queue.dart:187` 的 `_retryTimers.remove(task)?.cancel();`）证明原断言**恒绿、抓不住它声称要抓的回归**。现补断言到期后 `task.status` 仍为 `waitingRetry`（定时器活着的话会被翻成 `queued`），同一变异下确认转红。
- **备注**：这是「测试拿真时钟当同步原语」的通用形状——同批 review 中未发现其他同型用例；本文件内其余退避用例走 `instantBackoff`（`Duration.zero`，下一轮事件循环触发，`pumpEventQueue` 可靠等到），不受影响。
