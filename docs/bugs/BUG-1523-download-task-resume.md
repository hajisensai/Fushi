## BUG-1523 · Cancelled download tasks cannot be resumed
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。取消动作会暂停真实 torrent 并将任务持久化为 `cancelled`，但 `fushi/lib/src/pages/implementations/video_download_jobs_panel.dart:496` 之前只为 `active` 提供取消、为 `failed/needsAttention` 提供重试；流水线和数据库也没有 `cancelled → active` 的用户动作，因此暂停任务没有任何恢复入口。
- **[x] ① 已修复** — `packages/fushi_core/lib/src/database/database_video_domain.part.dart:1295` 新增严格的 cancelled CAS；`fushi/lib/src/media/video/download/video_download_pipeline_service.dart:540` 恢复原后端的精确 torrent。内置引擎 fast-resume 条目若已丢失，则保留原 hash/magnet 并退回 enqueue 自动重建；其他后端不允许静默换实例。任务卡仅对暂停任务显示恢复按钮。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart` 覆盖原任务直接恢复和内置 fast-resume 丢失后的重建；`fushi/test/pages/video_download_jobs_panel_test.dart` 覆盖恢复按钮的生命周期可见性和动作分发。
- **备注**：按用户要求跳过自动化测试；用 Windows Debug 构建直接实测。
