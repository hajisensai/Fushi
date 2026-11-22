## BUG-5198 · 上锁作品：剩余列出作品标题的次要消费端未接 MediaVisibility
- **报告**：2026-11-22（PR #4144 审查：全仓 grep 列出作品标题的消费端）
- **真实性**：✅ 真缺口。PR #4144 已把库页、首页（含远端「继续」）、收藏、统计四页、追踪页、合集管理计数、歌单曲目 / 计数、互联远端占位卡（书 / 视频 / 有声书 / 活动，wire 字段 `locked`）、控制通道的库 / 游戏 / 视频作品 / 合集 / 音乐路由接到 `fushi/lib/src/media/privacy/media_visibility.dart`；下列消费端仍会列出上锁作品标题：
  - 控制通道：`fushi/lib/src/ops/ctl_media_links_routes.dart`（作品关系图 / 人物）、`ctl_audiobook_routes.dart`（任务 / 作业列表）、`ctl_disc_routes.dart`、`ctl_video_organize_routes.dart`（audit / files / detail）；
  - UI：`work_network_page` / `media_links_section`（作品关系网）、`music_history.dart`（最近播放）、`media_history_repository`、`srs_card_source_jump`、标签页 / `media_sources_view`、`interconnect_manga_browse_page`、`hidden_remote_books_page`、`media_collection_detail_page` 的远端成员；`companion_library_service`（未确认）。
- **[ ] ① 未修复** — 每处都要经 `MediaVisibility`（`hidesWork` / `hidesRemoteEntry` / `hidesMusicTrack` 等）过滤，不在消费端另写判据。
- **[ ] ② 未加自动化测试** — 每接一处加对应过滤测试。
- **备注**：主路径已在 PR #4144 修完，这里是次要入口，分期登记。
