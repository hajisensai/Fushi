## BUG-1518 · 下载服务未启动时任务删除无效
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/downloads_page.dart` 的删除回调通过 `videoDownloadPipelineService?.deleteJob` 执行；服务为 null 时 null-aware 调用直接成功返回，界面不报错但任务完全未删除。
- **[x] ① 已修复** — 持久任务删除从 pipeline 解耦：服务不存在时也删除数据库任务；勾选文件时仅处理任务明确记录的文件/链接和对应视频库记录，绝不递归删除目录。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart` 覆盖无活动后端的持久任务删除。
- **备注**：按用户要求跳过自动化测试，使用 Windows Debug 构建直接实测。
