## BUG-2612 · 视频刮削演员/声优表显示不全、照片缺失
- **报告**：2026-09-20（用户：刮削出来的演员表和声优表显示不全、照片缺失；要求对照 Shoko 修）
- **真实性**：✅ 真 bug，七个根因叠加（沿 MAL / TMDB / AniDB provider → 合并层 → 落库 → 详情页真实路径逐层验证；Shoko 对照见 `references/ShokoServer`：AniDB 角色图 `<character><picture>` / 声优图 `<seiyuu picture="">`，空 picname 不建图；TMDB 剧集逐集 `credits` 再按 (人, 角色) 汇总成剧级 cast，人物图走 `person/{id}/images`；creator 名字/图只补空不覆盖）
  - **显示不全**
    1. Jikan `anime/{id}/characters` / `staff` 一失败就吞成空表（`mal_video_metadata_provider.dart` `_optionalCredits`），只在 `rawPayload` 记标记；作品照样落库。MAL transport 钉死 `maxAttempts: 1`，重试权全在 `MalVideoMetadataRequestGate`，而它只重试 429、不重试 5xx / 超时。2026-09-20 实测 Jikan `anime/{id}` 200 而 `characters` / `people` 整批 504（`Jikan failed to connect to MyAnimeList`）——正是用户看到声优表空的现场。
    2. TMDB 剧集人物表来自 `/tv/{id}` 的 `credits`（TMDB 对剧只给常驻主演），季级请求带的 `aggregate_credits` 拉回来后**从未被映射消费**（`tmdb_video_metadata_provider.dart` 无任何 `roles[]` / `jobs[]` 读取）。
    3. MAL 多 cour 展开（`video_source_scrape_coordinator.dart` `_expandMalSeasons`）对其它 cour 只取 seasons / episodes，`work.credits` 直接丢——第二季新登场角色的声优永远不进作品级人物表。
    4. 合并层 `_creditKey` = kind|人名|角色名：MAL `voiceActor` + 「姓, 名」 vs TMDB `actor` + 「名 姓」 + 「角色 (voice)」永不相撞，同一声优出现两次，且 `profileUrl: primary ?? supplement` 永远补不进 TMDB 的照片。
  - **照片缺失**
    5. Jikan 无图时不给 null 而是站点占位图（`images/questionmark_23.gif`、`img/sp/icon/apple-touch-icon-256.png`），`_image` 原样落库 → 详情页把问号 gif 当真照片加载，还挡住合并层补图。
    6. `upsertVideoMetadataPeople` / `upsertVideoMetadataCharacters` 用 `insertAllOnConflictUpdate` 整行覆盖：后来一次带 null `profileUrl` 的写入（AniDB 职员无图、NFO 回灌、占位归 null 后的 MAL）把上一轮拿到的照片抹掉。
    7. 声优卡只用人物照（`media_collection_detail_page.dart` `_buildCreditRail`），AniDB / MAL 都给了的**角色图**从不展示；`video_work_detail_page.dart` 的演职人员区只画文字 `Chip`，结构上就没有照片。人物 / 角色的 `profilePath` / `imagePath` 两列全库无写入方（照片不落地，纯在线加载）——本轮未改，见备注。
- **[x] ① 已修复** — PR 分支 `pr/cast-photos`：
  - MAL：`isMalPlaceholderImageUrl` 把占位 URL 归一成无图；gate 新增 `maxTransientRetries` / `transientBackoff`（5xx / 超时原地重试 2 次，2 s / 4 s，不推后全局 `_nextStart`）；`hasIncompleteMalCredits` 抽成共享 helper。
  - TMDB：剧集 `fetchWork` 追加 `aggregate_credits`，`_mapWorkCredits` 把 `roles[]` / `jobs[]` 展平后复用同一套映射、`credits` 只补汇总表没有的；cast 角色名带 `(voice)` 的归 `voiceActor` 并剥后缀（`stripVoiceRoleSuffix`，同 Shoko）。
  - 合并：`mergeVideoMetadataCredits` 公开；key 里 actor / voiceActor 同组、人名按词集合比较、角色名剥配音后缀。
  - 协调器：`_SeasonExpansion.extraCredits` 带回其它 cour 的人物表，按上面的合并规则并进作品。
  - 落库：人物 / 角色 upsert 改 `DoUpdate.withExcluded` + `coalesce`（只补空）；`replaceVideoMetadataCredits(keepExisting:)` 追加模式，`VideoMetadataDatabaseStore.apply` 在 MAL 人物表残缺且库里已有表时只追加不覆盖。
  - UI：抽 `fushi/lib/src/media/video/metadata/video_credit_rail.dart`（`VideoCreditRail` + `videoCreditCardImage`：人物照 → 声优退角色图），合集详情页与单文件作品页共用；单文件作品页照片轨道替换文字 Chip。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/mal_video_metadata_provider_test.dart`（5xx 原地重试、4xx 不重试、重试预算耗尽仍标残缺、占位图归 null）、`fushi/test/media/video/metadata/tmdb_aggregate_credits_test.dart`（aggregate_credits 展平 / (voice) 归类 / 电影不带）、`fushi/test/media/video/metadata/video_metadata_merge_test.dart`（跨源同一关系并、不同角色不并、导演不误并、后缀剥离）、`fushi/test/media/video/metadata/video_metadata_database_store_test.dart`（只补空不抹掉、残缺表只追加）、`fushi/test/media/video/metadata/multi_season_coordinator_test.dart`（第二季新声优进作品表）、`fushi/test/media/video/metadata/video_credit_rail_test.dart`（照片来源优先级、角色图回退、两页共用守卫）。
- **备注**：未做的两项——① 人物 / 角色照片不落地（Shoko 会下载到本地图片库；本仓 `AppCachedHttpImage` 首次在线加载后有磁盘缓存，离线首开仍是占位）；② TMDB `profile_path` 为空时 Shoko 还会拉 `person/{id}/images`（一人一请求，动画声优在 TMDB 上多半本来就没图，收益低）。NFO 回灌整表替换（`mergeNfoAuthority` 只要 NFO 有一个 actor 就替换在线全表、且 builder 不写 MAL/AniDB 人物 id）是另一条会让列表变短、照片丢失的路径，属既定「NFO 权威」语义，本轮未动。真机 UI 本轮未跑（Jikan 当天 504）。
