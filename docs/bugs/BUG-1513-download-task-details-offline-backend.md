## BUG-1513 · 下载任务详情被离线原后端阻断
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/downloads_page.dart` 的详情入口在打开弹窗前调用后端解析；`fushi/lib/src/media/video/download/video_download_pipeline_service.dart:483` 原实现会在任务记录的内置引擎缺失时直接抛错，因此弹窗无法出现。
- **[x] ① 已修复** — 详情加载改为实时后端数据优先、数据库持久化快照兜底；原后端离线时仍可查看任务总览和文件，并明确提示实时参数不可用，同时禁止误连当前配置中的其他 qBittorrent 实例。
- **[x] ② 已加自动化测试** — `fushi/test/pages/torrent_detail_dialog_test.dart` 覆盖无后端时持久化总览、离线提示及文件页仍可渲染。
- **备注**：按用户要求本轮跳过自动化测试，完成 Windows Debug 构建后直接启动实测。
