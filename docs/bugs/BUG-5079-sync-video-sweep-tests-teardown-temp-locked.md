## BUG-5079 · sync-video-sweep-tests-teardown-temp-locked
- **报告**：2026-11-21（用户：拍板台执行代理在 other-sync-peer-version-errors 分支跑定向测试时发现）
- **真实性**：✅ 在 origin/develop（77a0a0ad80）源码上 Windows 本机 `--concurrency=1` 复现：
  `test/sync/interconnect_video_resume_stale_cache_test.dart:170`、
  `test/sync/sync_orchestrator_live_progress_test.dart:198`、`test/sync/video_watched_mark_sync_test.dart`
  的 tearDown 里 `work.delete(recursive: true)` 抛 `PathAccessException`（errno 32，文件被占用）。
  断言本身都过，只是 tearDown 删临时目录时目录里还有文件被打开着；同一轮里失败的用例数在 4～5 条之间
  浮动。根因待查：疑为视频 sweep 路径在测试结束时仍持有临时目录里的文件句柄（server / 客户端 DB /
  某个未 close 的下载或日志文件）。
- **[ ] ① 未修复** — 先在这几条用例上找出 tearDown 时仍打开的句柄（Process Explorer / handle.exe 查
  临时目录），按所有权补关闭，不在 tearDown 里吞异常或加重试。
- **[ ] ② 未加自动化测试** — 修好后这几条用例本身就是回归测试（Windows 上 tearDown 不再红）。
- **备注**：与 other-sync-peer-version-errors 的改动无关（同一批用例在不含该改动的 develop 源码上同样红）。
