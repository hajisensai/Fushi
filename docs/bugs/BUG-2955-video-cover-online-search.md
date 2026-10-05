## BUG-2955 · 视频设置封面只能选本地文件，在线搜索封面入口丢失
- **报告**：2026-10-05（用户：「视频的设置封面回归只能选本地文件之前可以在线」）
- **真实性**：✅ 真 bug（回归）。`1637876c64c`（2026-08-23 `refactor(video): make AniDB the canonical scraper`）把旧 Bangumi/TMDB 刮削链换成 canonical 资料源时，连带删掉了视频卡菜单的「在线匹配海报」（`_openCoverMatch` → `cover_match_dialog.dart`）与合集的「刮削资料与封面」，**没有把选封面接到新资料源上**。此后视频的三个设置封面入口都只调 `MediaCoverService.pickCoverImage()`（本地文件）：
  - 单集卡菜单：`fushi/lib/src/pages/implementations/home_video_page.dart:3200`（`srt_import_pick_cover` → `_pickCover`，`:3507`）
  - 库页合集菜单：`home_video_page.dart:6933`（`collection_cover_set` → `_setCollectionCover`，`:6989`）
  - 合集详情 AppBar：`fushi/lib/src/pages/implementations/media_collection_detail_page.dart:2175`（`_setCover`，`:769`）
  书 / 漫画不受影响：书架卡菜单的「在线刮削封面」（`reader_fushi_history_page.dart:2587`）与编辑对话框封面字段的刮削按钮仍在。
- **[x] ① 已修复** — 不复活已退役的 Bangumi 链，而是接到现有 canonical 候选搜索（AniDB / MAL / TMDB，与「手动指定作品」同一条 `VideoSourceScrapeTaskController.searchManualCandidates`）：新 `fushi/lib/src/media/video/cover_ui/video_online_cover_picker.dart` 复用 `showVideoMetadataCandidateSearchDialog`（加可选 `title` / `hint`），选中候选取其 `VideoMetadataImageKind.cover` 图（搜索摘要无图时经 `fetchWorkForLookup` 拉完整资料），`downloadImageToTempFile` 下载后交给与本地选图完全相同的落盘（`applyVideoCoverManual` / `applyCollectionCover`，手选保护标记照记）。三个入口各加「在线搜索封面」：单集卡菜单、库页合集菜单、合集详情 AppBar（经新回调 `onPickOnlineCover` 由库页注入，`VideoWorkDetailPage` 透传）。只在有刮削 controller 且其支持手动搜索、「在线服务」模块开启时出现。只取图，不改作品身份。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_online_cover_picker_test.dart`（封面 URL 判据）、`fushi/test/pages/home_video_page_menu_test.dart` 组「视频卡「在线搜索封面」（BUG-2955）」（菜单在场 + 打到候选搜索 / controller 不支持时不画）、`fushi/test/pages/collection_detail_scrape_entry_test.dart`（合集详情菜单项在场并调用注入实现 / 未注入时不画）。
- **备注**：没有真打 AniDB / TMDB 下图（测试注入候选）。真机验证：视频库长按单集卡 / 长按合集 / 合集详情右上「⋯」→「在线搜索封面」→ 搜索 → 点一条结果，封面应立即换成该作品封面。
