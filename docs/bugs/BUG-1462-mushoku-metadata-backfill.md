## BUG-1462 · 无职转生严格匹配无法人工确认且详情与剧集标题未回填
- **报告**：2026-08-09（用户：无职转生详情无资料、剧集仍显示发布文件名）
- **真实性**：✅ 真 bug。真实来源任务摘要显示合集加 NCOP/NCED 共被规划成 5 个作品且全部失败；`video_metadata_resolver.dart:134-203` 只保留通过严格标题门控的候选，TMDB 能搜索到的无职转生本地化标题因罗马字别名只存在于详情/alternative titles 而被直接丢弃，未进入已有人工确认链。`video_source_work_planner.dart:60-67` 又把 NCOP/NCED 当独立电影。详情页 `media_collection_detail_page.dart:391-392` 只读 v68 分集投影，未直接读取 v69 规范分集标题与图片，因此即使规范资料存在也可能继续回落发布文件名。
- **[x] ① 已修复** — TMDB 详情补取 `alternative_titles/translations`，严格门控同时检查搜索摘要和详情别名；类型、年份、季号有效但标题仍不确定的候选进入后台任务面板人工确认并持久绑定。NCOP/NCED/PV 归为附件、从作品刮削计划排除并清理旧版误建的独立规范作品。刮削后将真实分集名安全投影为应用内标题（只覆盖原文件 stem 或上次刮削标题，不移动/重命名磁盘文件），详情页直接读取 v69 作品图片、简介和分集标题。作品 hero 改为内容区全宽大背景和大竖版海报。
- **[x] ② 已加自动化测试** — `video_metadata_resolver_test.dart` 覆盖罗马字详情别名与人工候选保留；`video_metadata_provider_contract_test.dart` 覆盖 TMDB alternative titles；`video_source_metadata_indexer_test.dart` / `video_source_scrape_coordinator_test.dart` 覆盖 NCOP 附件迁移、单作品计划、真实分集名回填且磁盘路径不变；`collection_hero_scrape_meta_test.dart` / `collection_hero_v69_credits_test.dart` 覆盖全宽大 hero、v69 作品简介和规范分集标题。
- **备注**：与 MoviePilot 一致使用单主源和标题/原名/别名严格匹配；Hibiki 继续遵守“不整理用户媒体文件”的既定边界，所谓剧集重命名仅更新库内展示名与 NFO，不改物理文件名。
