## BUG-1461 · Himouto 罗马字标题被 TMDB 本地化结果严格门控拒绝
- **报告**：2026-08-08（用户：`himouto` 刮削失败）
- **真实性**：✅ 真 bug，且首轮修复不完整。第一处根因在 `hibiki/lib/src/media/video/metadata/tmdb_video_metadata_provider.dart`：TMDB 中文搜索可以通过英文别名命中，但响应只保留本地化中文名和日文原名，严格标题门控看不到英文命中名。首轮补齐 aliases 后用户仍复现；查用户真实运行库的任务摘要发现第二处根因在 `video_source_scrape_coordinator.dart::_parsedYear`：它用裸正则扫描完整发布名，把 `[1920x1080]` 的 `1920` 当成发行年，从而继续拒绝真实的 2015 候选。规范作品表因此保持 0 行，详情页只能显示文件名与抽帧。
- **[x] ① 已修复** — 第一阶段在同一 TMDB 主源内合并配置语言、英文、日文和简中搜索 aliases；本轮把年份提取收口到仓内唯一的 `FilenameParser`，分辨率不再污染年份门控。已有来源在应用启动及打开合集详情时都会离线、幂等补建 `VideoMetadataWork`，详情路由改为内嵌圆角作品 hero、规范标题和资料区；未刮到资料时明确提示从来源重试，不再静默呈现一张像“完成页”的旧布局。
- **[x] ② 已加自动化测试** — `video_metadata_provider_contract_test.dart` 覆盖本地化 aliases；`video_source_scrape_coordinator_test.dart` 用真实 Himouto 发布名锁定 `1920x1080` 不会生成 1920 年且 2015 候选能成功入库；`video_source_metadata_indexer_test.dart` 锁定旧来源补建作品与重复启动幂等；`collection_hero_scrape_meta_test.dart` 锁定新的作品 hero 与待刮削状态。后台任务面板测试继续覆盖关闭面板不取消、进度历史和重新进入。
- **备注**：自动应用仍要求规范化标题、类型、年份和季号严格匹配，不引入跨源回退或模糊匹配；多个严格候选仍进入后台待确认，不会静默选错。
