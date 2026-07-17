## BUG-864 · Google Drive 聚合同步瞬时网络超时不重试整轮放弃

> 原以工具自动取号建为 BUG-862，为与同批 BUG-863 保持连号并避开并发分支占用，改号为 864。

- **报告**：2026-07-16（用户：运行日志 `SyncRunReport.errors` `aggregate sync: ClientException with SocketException 信号灯超时 errno=121 www.googleapis.com`；用户明确要求「应该继续或重试，而不是完全放弃」）
- **真实性**：✅ 真 bug。
  - `GoogleDriveHandler._call`（`hibiki/lib/src/sync/google_drive_handler.dart:125`）只对 401 做单次刷新重试；瞬时 `SocketException`/超时既不是 `DetailedApiRequestError` 也非 unauthorized，走 `rethrow` 原样抛出。
  - `GoogleDriveSyncBackend._wrapErrors`（`google_drive_sync_backend.dart:36`）只 `on GoogleDriveError` / `on GoogleDriveAuthError`，接不住裸 `SocketException` → 未分类穿透。
  - `SyncOrchestrator._syncAggregate`（`sync_orchestrator.dart:456`）裸 `catch (e)` 把它记进 `report.errors` 后**整轮聚合合并+上传直接放弃**，零重试。`AggregateSyncService.sync` 里 `ensureNamespace`/`listChildren`/`putJsonAsset` 均无保护，一次瞬时超时即中断整轮。
- **[x] ① 已修复** — 在唯一咽喉 `_call` 外包有界退避重试：
  - 新增 `hibiki/lib/src/sync/sync_transient_error.dart`：`isTransientSyncError(Object)`（复用 `sync_error_messages.dart` 的 timeout/network 子串分类 + `SocketException`/`TimeoutException`/`HttpException` 类型；auth/scope/4xx 明确判非瞬时不重试）+ `retryTransientSync<T>`（默认 4 次、线性退避 400ms*attempt、`sleep` 可注入、永久错误立即抛不浪费预算）。
  - `_call` 拆出 `_callOnce`（保留原 401 刷新逻辑），`_call = retryTransientSync(() => _callOnce(fn))`。因所有 Drive op 都经 `_call`，聚合同步的 list/ensure/put 以及全部书/词典操作一并获得瞬时重试；重试 op 均幂等（overwrite-by-name / 幂等 list/ensure），重复安全。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_transient_error_test.dart`：`isTransientSyncError` 对日志原文（信号灯超时/errno121）、网络子串族判 true，对 insufficient_scope/401/invalid_grant/not-found 判 false；`retryTransientSync` 断言瞬时失败重试到成功（并按线性退避 sleep）、穷尽 maxAttempts 后抛最后一个错、永久错误一次即抛、首次成功不 sleep（零开销）。
- **备注**：同批日志另一条 ffmpeg 内嵌字幕毒轨见 BUG-863。第一条日志本身是本机代理 fake-ip 把 googleapis 解析成假 IP 导致的真实网络超时（环境），但「一次超时就放弃整轮」是代码缺陷，本条修复的是后者。
