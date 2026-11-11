## BUG-4453 · 漫画 OCR host 清理过期 / 取消的旧任务时删掉同卷新任务正在用的目录
- **报告**：2026-11-10（互联远程长任务审查 V-D4）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/sync/fushi_manga_ocr_host.dart:216-229` `createJob` 让同名卷的新任务落回同一个 `vol_<slug>`（续传语义），`dirBusy` 只看非终态任务，于是「旧任务已 error/done、新任务同卷」时两者共用目录；`_housekeep`（修复前 `:384-397`）让过期旧任务 `job.dir.deleteSync(recursive: true)`，把新任务的页图连同目录删掉；`cancelAndCleanup`（修复前 `:343-370`）对旧任务 DELETE 会删掉新任务已上传的页图。修复前新测试实测：TTL 用例 `B.dir` 不存在、DELETE 用例 `p2.png` 被删。
- **[x] ① 已修复** — `b1032b417b5` 目录按引用回收：新增 `_dirSharedWithOtherJob(job, liveOnly:)`（按 `p.canonicalize` 比目录、排除自身）。`_housekeep` 过期任务先出表，表里仍有任何任务引用该目录就跳过（同一轮都过期时最后一个出表的才删）；`cancelAndCleanup` 出表后若有非终态共享者就不删任何文件，共享者全是终态时照旧删页图、保留 `manga_ocr_out/`。`createJob` 的 `dirBusy` 与孤儿扫描不变。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_sync_server_manga_ocr_test.dart` group `shared volume dir`：TTL 不删共享目录、DELETE 旧任务保留在跑共享者的页图、共享者全终态时照常删页图并保留 `manga_ocr_out/`（保持用例）。
- **备注**：host 内部行为，无 wire / 持久化改动；目录名与断点缓存位置不变。
