## BUG-5078 · live-progress-test-teardown-temp-delete-fails
- **报告**：2026-11-21（用户：拍板台 Z2OhxAjKVv 执行代理在本机跑定向测试时发现）
- **真实性**：✅ 真（测试基础设施，非产品逻辑）。`origin/develop`（a11db40c13）原样复现：Windows 本机 `flutter test test/sync/sync_orchestrator_live_progress_test.dart` 37 过 1 红，红在 tearDown 的 `work.delete(recursive: true)`（`fushi/test/sync/sync_orchestrator_live_progress_test.dart:198`），报 `PathAccessException ... errno = 32`（文件被占用）或 `FileSystemException ... errno = 145`（目录非空）。断言本身全过。连跑两次都红，红的用例在 `video delay full sweep (BUG-1620)` 与 `BUG-4302 ... video` 之间漂。另一个并行工作区（wf_2e0c1a19-aea-1）的同一文件也红在这两条。根因待查：疑似 `server.stop()` / `hostDb.close()` 返回时 host 侧仍有未结束的异步文件句柄（host 视频清单的 async stat / sidecar 列目录，或 server_data 下的文件）。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：红的是 tearDown 删临时目录，不是被测行为；修之前判这份测试别只看退出码，要看失败是不是都落在 tearDown 的 delete 上。
