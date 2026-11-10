## BUG-4398 · 通用任务 host 只在启动时清理过期任务，被遗弃的上传永不回收
- **报告**：2026-11-10（互联远程长任务审查 R13 host 侧、R12 host 头注释）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/sync/host_jobs/host_job_manager.dart`（修复前）：`load()` `:103-136` 有 `_loaded` 门，`pruneExpired()` 只在进程首次触达 `/api/jobs` 时跑一次，之后建的任务过 TTL 也不会被删；`pruneExpired()` `:312-319` 只清 `isTerminal`，建了任务 / 传了一半就被客户端遗弃的 `pending/uploading` 永不回收（输入文件一直占盘）；`:104-105` 在第一个 await 之前就置 `_loaded = true`，并发的首批请求里后到者在表还没读完时就通过 `load()`、列表缺记录；头注释 `:1-6`「客户端看到 error 会重投」与 client 实际行为（看到 error 直接报错并 DELETE）不符。修复前新测试实测：终态 / 遗弃上传 / 节流三条用例过 25h 后记录仍在，并发 load 用例第二个响应为空列表。
- **[x] ① 已修复** — `68c7034d7ad` `load()` 改为缓存同一个 future（`_loading ??= _loadOnce()`，`host_job_manager.dart:113`）；新增 `housekeep()`（`:116`）每次 API 触达先等读盘再按 `pruneInterval`（默认 10 分钟）节流清理，`host_job_routes.dart:39` 改调它；`pruneExpired()`（`:338`）判据改为「非 running 且 `updatedAt` 早于 TTL」，running 不按 TTL 清；头注释改为实际行为。wire 与 `job.json` 不变。
- **[x] ② 已加自动化测试** — `fushi/test/sync/host_jobs_routes_test.dart` group `ttl housekeeping`（真 `handleHostJobRequest` + 注入时钟）：运行期建的终态任务过 TTL 被清、遗弃上传被清、running 不清、清理按 10 分钟节流、并发首批请求都看到已落盘记录。
- **备注**：升级后第一轮会删掉 `updatedAt` 超过 24h 的遗弃 `pending/uploading`，这些记录 client 不保存 jobId、本就无人能接回。
