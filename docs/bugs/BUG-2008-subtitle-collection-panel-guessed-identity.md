## BUG-2008 · 合集字幕批量搜索只用合集名与裸 anilistId，无视已刮削的规范身份
- **报告**：2026-09-01（刮削重设计调查：字幕域 7 处「身份→请求」构造盘点中定位）
- **真实性**：✅ 真 bug。`subtitle_collection_panel.dart`（修前 :210-213/:393-403）：查询词 = 合集显示名过一遍文件名解析（中文名对 Jimaku/AniList 命中率最差）；请求身份只有 `media_collections.anilistId`，`mediaKind` 写死 tv、无 originalTitle、无 tmdb id——而同一合集刮削出的 `video_metadata_works`（日文原名 + 全套 provider 身份）就躺在库里没人读。播放页单集面板（`subtitle.part.dart` 的 seed）早已接了规范身份，合集批量是掉队的那个。
- **[x] ① 已修复** — `d44bebbe78`（首版 `147ff99e5f` 因审查阻断被撤销重做）：面板 initState 读回合集的规范作品与身份（`_loadCanonicalIdentity`）：用户未改过查询词时替换为日文原名；请求带 originalTitle / tmdb id、mediaKind 取刮削结论、合集未绑 AniList 而身份里有 anilist id 时直接按 id 搜。首版额外把 AniDB 全量别名灌进刮削后补齐（`video_subtitle_backfill.dart`）的 `alternateTitles`——被审查判死（一部番 20~60 条别名 × Jimaku「逐条试、首个非空即停」× 逐集调用 = 请求爆炸，且 SnK/HxH 类短别名 first-hit-wins 误配整部字幕），重做已撤销该接线：backfill 的 `scrapedMediaReference` 本就带外部 id 与日文原名（见 `scraped_subtitle_targets.dart`），身份精度不依赖别名兜底。
- **[x] ② 已加自动化测试** — 既有 `fushi/test/pages/subtitle_collection_panel_test.dart` 全绿（纯函数与写列行为不受影响）；身份构造为 widget 内私有读库路径，行为由「合集无规范作品 → 走旧路径」的空值分支保证零破坏，规范身份消费面的端到端归入合入前全量。
- **备注**：字幕域其余独立身份构造点（发现页 / 旧番剧订阅链 / 浏览器扩展桥）各属独立功能面，未在本轮收敛——见 docs/bugs 索引与 P3 PR 描述的后续清单。
