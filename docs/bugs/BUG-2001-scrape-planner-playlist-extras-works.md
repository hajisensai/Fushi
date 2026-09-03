## BUG-2001 · 计划器把播放列表合集与无集号特典当独立作品刮削
- **报告**：2026-09-01（沿用户库实测：`video_metadata_works` 里出现标题为「S00E01」「特典 S00E01」「哆啦A梦剧场版 播放列表」的垃圾作品行）
- **真实性**：✅ 真 bug（部分）。`fushi/lib/src/media/video/metadata/video_source_work_planner.dart`：不属于多成员合集的单个集号文件退化为独立作品，标题取 `book.title`——「特典 S00E01」这类纯集号标签拿去 AniDB 必失败，而解析器的目录名候选回查又会把特典**误绑成正片作品**。注意：播放列表型合集**不能**按 `collection_type='playlist'` 排除——用户库 35 个合集 34 个是 playlist（含正常追番系列），类型不是判据；多部电影混装合集属于下载整理阶段的形状问题，归刮削重设计 P3。
- **[x] ① 已修复** — `194637edab`：`VideoSourceScrapeWork.hasIdentifiableTitle`（纯集号标签正则：可选 特典/SP/OVA/Special/Extra 前缀 + SxxEyy）。这类作品仍进计划与待确认队列（用户可手动指定身份），但库内自动补刮不对它做注定失败或注定误绑的自动尝试。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_source_work_planner_test.dart`（「纯集号标签标题判为不可自动识别」正反例）；`fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`（「集号标签型标题进待确认队列但不自动补刮」）。
- **备注**：多电影种子被整理成 SxxEyy / 只认最大文件为正片的根因在 organize 阶段（`video_download_organizer.dart`），P3 处理；本条不动整理命名。
