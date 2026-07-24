## BUG-1031 · 默认下载配置未传给完成轮询
- **报告**：2026-07-23（用户：）
- **真实性**：✅ 真 bug。界面把空偏好解释成默认内置后端，但 `AppModel.startAnimeDownloadService` 原先把 `prefsRepo.qbConnectionConfig` 的 `null` 直接传给轮询服务；`AnimeDownloadService._tickOnce` 因配置为空立即返回，导致新用户的任务永远不完成自动入库。根因：`hibiki/lib/src/models/app_model.dart:2973`、`hibiki/lib/src/media/torrent/anime_download_service.dart:279`。
- **[x] ① 已修复** — 新增 `effectiveTorrentConfig` 作为 UI、内置引擎和后台服务共同的默认配置真相源。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/anime_download_subscription_test.dart` 验证空偏好解析为可用的默认内置配置。
- **备注**：提交哈希在合并提交后回填。
