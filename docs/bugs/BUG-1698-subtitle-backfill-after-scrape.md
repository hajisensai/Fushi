## BUG-1698 · 刮削解析出的规范身份没被字幕侧使用，且自动配字幕能力对用户完全不可见
- **报告**：2026-08-17（用户：「刮削后自动下载字幕」+「怎么让用户知道可以自动下载字幕之类的？」）
- **真实性**：✅ 两个真问题，同一个根：刮削与字幕两条链路互不认识。
  1. **刮削链路零字幕代码**——`fushi/lib/src/media/video/metadata/video_source_scrape_coordinator.dart` 里 `subtitle` 出现 **0 次**。「刮削后自动下载字幕」不是不准，是**功能不存在**。
  2. **刮削已经算出来的身份被丢掉**：`VideoMetadataWorks` 存着 AniList/TMDB/Bangumi id 与日文 `originalTitle`，而播放页字幕对话框（`jimaku_subtitle_dialog.dart:363`）拿**文件名解析出的系列名**去 `AniList.searchAnime` 现搜。刮削过的视频显示名常是「中文译名 + 季度 + 篇名长串」，在 AniList 必然 0 结果。答案已经在库里，字幕侧却重猜一遍。
  3. **能力不可见**：下载流水线的字幕阶段默认 `bestEffort`（自动配字幕一直开着），但它没有名字、没有设置项、失败只落在任务行一句状态里。用户既不知道这个能力存在，也不知道要配 Jimaku key 才能用上。
- **[x] ① 已修复**
  - 新增 `fushi/lib/src/media/video/subtitle/video_subtitle_backfill.dart`：给缺字幕的视频补一条。**只补缺的**（DB `subtitleSource` 或磁盘 sidecar 任一存在就跳过——用户手放/手改的字幕不可再生），落 sidecar 不写 DB 选择（自动补的和用户选的不在同一字段上打架），先写 `.tmp` 再 rename（半截字幕比没字幕更糟：播放页会把它当可用字幕加载）。复用 BUG-1697 的时长校验 + 候选回退。
  - 新增 `fushi/lib/src/media/video/subtitle/scraped_subtitle_targets.dart`（**纯函数**）：刮削结论 → 字幕目标。单独成文件是因为这里就是准确率的分水岭，值得被单测钉死而不是埋在 service 里。带过去的三件事缺一不可：外部 id（Jimaku 按 anilist_id 直查 / OpenSubtitles 按 imdb）、`originalTitle`（id 没命中时的回退词，用中文译名等于不回退）、`discoveryCategory`（决定 BUG-1694 的 anime 过滤档）。季集号取**本地文件名解析**而不是刮削顺序——合集可能缺集/含特典/被拖拽重排；多集里认不出集号的成员**不生成目标**（配上去只能碰运气），单文件作品（电影/剧场版）例外。
  - `VideoSourceScrapeCoordinator` 加 `onWorkScraped` 回调 + `VideoScrapedWorkNotice`。协调器**不长出字幕依赖**、也不被字幕失败拖慢：回调异常吞进本次 run 的 warnings。
  - `AppModel._backfillSubtitlesForScrapedWork` 消费它，三道自然闸门（偏好关 / 没配任何来源 / 已有字幕）任一不满足就静默跳过；逐条串行不并发（一次刮削可能带来整季十几集，并发打同一个字幕站是滥用）。
  - **发现性**：设置 → 视频 → 字幕新增开关 `video.subtitle.backfill_after_scrape`（默认开），放在 Jimaku / OpenSubtitles 配置**正上方**——设置页有搜索（`settings_search.dart`），给能力一个名字它才第一次可被搜到，且配置项同屏可见。
  - 任务行文案跟上新行为：`subtitleUnavailable` 不再一律说「未匹配到」，还排得上 backoff 重试的说「字幕：还没上传，稍后自动重试」（判据是 `AnimeDownloadPlan.subtitleRetryPossible`，UI 不重算 backoff 算术）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/scraped_subtitle_targets_test.dart`（11 条）：外部 id 全量透传、originalTitle 必带、非数字 id 不炸、AniList id 决定 anime 档、季集号取文件名不取顺序、已有字幕标记、多集认不出集号不生成目标、单文件作品例外、runtime 逐集取并回落作品级、空输入不生成半截目标。
- **备注**：播放页的「自动获取字幕」入口本来就有（`subtitle.part.dart:136`），所以发现性的缺口不在播放页而在**设置页没有这个能力的名字**。另：播放页目前只接 Jimaku，OpenSubtitles 在播放页仍无入口——留作后续。
