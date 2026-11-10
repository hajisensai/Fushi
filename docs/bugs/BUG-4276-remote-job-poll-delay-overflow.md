## BUG-4276 · 远端任务轮询退避在约 2.4 小时后溢出抛错并删除 host 任务
- **报告**：2026-11-10（互联远程长任务审查 V-D1 / R12）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/interconnect_manga_ocr_client.dart:34-39` `mangaOcrPollDelay` 先 `baseMs * pow(1.5, attempt)` 再 `round()` 再 `min(…, 5000)`，attempt≈1736 时 `pow` 得 Infinity，`Infinity.round()` 抛 `UnsupportedError`，封顶在 round 之后挡不住；`interconnect_job_client.dart:118` 默认复用它，`:316` 抛出后进 catch → `cleanupRemote()` → `DELETE /api/jobs/<id>`，按 5s 一轮约 2.4 小时的远端 ASR 必被自己删掉。为此写的 `hostJobPollDelay`（`:604-607`）从未接线、且同样先 round 再封顶。修复前单测实测抛 `Unsupported operation: Infinity or NaN toInt`。
- **[x] ① 已修复** — `df045014199` 新建 `fushi/lib/src/sync/interconnect_remote_job_poll.dart` 的 `remoteJobPollDelay`：指数先夹到 6（500×1.5^6 > 5000）再算，任意 attempt 不产生 Infinity / NaN；`mangaOcrPollDelay` 改为委托它，两个 client 默认都用它；删掉死代码 `hostJobPollDelay` 与 job client 对 OCR client 的 import。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_manga_ocr_client_test.dart`「poll delay never throws for very large attempts」：前 7 个值 500/750/1125/1688/2531/3797/5000 逐毫秒不变，attempt 1736 / 5000 / 1<<40 恒为 5s 且不抛。
- **备注**：前 6 次延迟与旧函数逐毫秒相同，纯客户端，无 wire / 持久化改动。
