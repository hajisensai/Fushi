## BUG-1519 · 内置下载任务丢失后无法重新入队
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/download/video_download_pipeline_service.dart:955` 在内置引擎接收 torrent 后直接把持久任务推进到 download，但恢复数据只由 `fushi/lib/src/models/app_model.dart:3915` 的一分钟周期保存；非正常退出会留下“数据库有任务、引擎无 torrent”。随后 `packages/fushi_core/lib/src/database/database_video_domain.part.dart:1258` 的用户重试只重置生命周期和次数，不清理后端任务 id、也不退回 enqueue，因而同一缺失查询连续失败至耗尽次数。
- **[x] ① 已修复** — 内置任务添加成功后、推进 download 前强制保存恢复快照；运行中的内置任务若已从引擎丢失，以带 lease 的 CAS 清理后端任务 id 并退回 enqueue；既有失败任务点重试时也按同一规则重新解析原资源并添加。外接 qBittorrent 不应用该自动回退，避免把暂时查询失败误判为任务丢失。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart` 覆盖入队检查点顺序、活动任务丢失后的安全回退，以及既有失败任务重试后重新添加。
- **备注**：按用户要求跳过自动化测试，使用 Windows Debug 构建直接实测。
