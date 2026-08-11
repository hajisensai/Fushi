## BUG-1528 · 视频发现与系列页封面刷新重复下载
- **报告**：2026-08-11（用户：Wight）
- **真实性**：✅ 真 bug。`video_discovery_page.dart:1007`、`video_discovery_detail_page.dart:763` 与 `home_video_page.dart:654` 等视频入口直接构造 `NetworkImage`，只命中 Flutter 进程内易淘汰缓存；发现页大量封面刷新、系列页切换或应用重启后会再次请求网络。
- **[x] ① 已修复** — 本提交将发现、系列、合集详情与作品详情的远端封面统一改为 `CachedNetworkImageProvider`，按 URL 使用项目既有磁盘缓存；图片地址变化时仍会自然换新。
- **[x] ② 已加自动化测试** — `video_discovery_page_test.dart` 行为断言发现卡片使用磁盘缓存 provider；`video_remote_cover_disk_cache_guard_test.dart` 守卫五个视频入口不再退回 `NetworkImage`。按用户要求未运行自动化测试。
- **备注**：改完构建并启动 Windows 实包供实测，暂不更新 PR。
