## BUG-1524 · Task deletion is blocked when backend pause fails
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`VideoDownloadPipelineService.deleteJob` 复用了 `cancelJob`；失效或已从后端消失的 torrent 无法暂停时，删除流程在清理持久任务记录之前就抛错退出。
- **[x] ① 已修复** — 删除流程直接终止持久流水线，再尽力移除原后端 torrent；后端暂停失败、任务失效或后端离线不再阻止删除数据库任务记录。
- **[x] ② 已加自动化测试** — `video_download_pipeline_service_test.dart` 覆盖后端拒绝暂停时仍可删除 `needsAttention` 任务，并验证删除不会调用暂停接口。
- **备注**：按用户要求不运行自动化测试，使用 Windows Debug 构建启动实测。
