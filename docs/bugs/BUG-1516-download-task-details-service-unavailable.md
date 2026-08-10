## BUG-1516 · 下载服务未启动时任务详情打不开
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/downloads_page.dart` 在 `videoDownloadPipelineService == null` 时先抛出 “The download service is not available”；内置引擎运行库缺失会停用下载服务，因此此前的弹窗离线兜底仍无法触达。
- **[x] ① 已修复** — 持久化详情组装从运行中 pipeline 解耦；服务未启动时直接从数据库任务与文件表构建详情，实时后端参数按离线状态降级。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart` 覆盖不依赖活动后端的持久化详情构建。
- **备注**：本机 Debug 包缺少可选的内置引擎四个 DLL；本轮从已安装的完整 Fushi 包恢复同版本运行库到预构建目录后重新打包。按用户要求跳过自动化测试。
