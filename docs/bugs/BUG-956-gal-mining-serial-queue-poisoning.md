## BUG-956 · galgame 制卡串行队列异常毒化后所有后续制卡永久挂起
- **报告**：2026-07-21（PR#295 落地审查 M4，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:727-746` + `gal_hook_mining_coordinator.dart:115-136`：串行队列 `_tail = _tail.then(...)` 无 `catchError` 归位，catch 块自身抛出即毒化队列，后续所有制卡 `await` 永久挂起。
- **[x] ① 已修复** — 抽出可测共享原语 `hibiki/lib/src/mining/serial_job_queue.dart`（`SerialJobQueue.enqueue`）：内层 try/catch 造降级结果 + **链尾 `catchError` 兜底**，`settle` 全程吞掉 onError/buildFailure 副作用异常，保证 `_tail` 永不停在 rejected、completer 一定完成。coordinator `mineLine`（`gal_hook_mining_coordinator.dart`）与 controller `_captureAudioBytes`（`gal_hook_session_controller.dart`）两处重复的危险模式统一改用该原语（消除重复）。
- **[x] ② 已加自动化测试** — `test/mining/serial_job_queue_test.dart`：核心用例「job 抛 + onError 副作用自身也抛」用 `.timeout` 断言不挂起、后续任务仍执行（直测原本无法注入的毒化场景）；另覆盖 buildFailure 自身抛退化为 completeError。coordinator/controller 原有测试全过（重构无回归）。
- **备注**：全仓同模式（whenComplete 自等/链毒化）值得一并审计，见 PR#291 备忘。
