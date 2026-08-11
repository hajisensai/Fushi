## BUG-1547 · TMDB 未配置时全部刮削整批失败：resolver 不回退到零密钥的 Bangumi/AniList，且错误是英文裸串
- **报告**：2026-08-11（用户截图：视频-来源页「播放列表合集」全部刮削 → 成功 0、失败 27，每条都是 `tmdb is not configured`；另反馈合集页「刮削分集资料」点了只弹「请先刮削合集资料」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/metadata/video_metadata_resolver.dart:127-134`（修复前）：主源 `isAvailable == false` 就直接 `providerUnavailable` 返回，**不尝试 registry 里其它已配置的源**。而 `_createRegistry`（`video_source_scrape_coordinator.dart:63-77`）注册的 Bangumi / AniList 两个源 `isAvailable => true`（零密钥，见 `bangumi_video_metadata_provider.dart:33`、`anilist_video_metadata_provider.dart:28`），本可无缝顶上；`VideoMetadataProviderRegistry.availableProviders`（`video_metadata_resolver.dart:73-78`）这个现成 getter 全仓无人调用——回退能力写了一半没接上。
  三条放大链路：
  1. **默认值处处推向 tmdb**：`video_source_scrape_config.dart:26`（parse 失败/fanart 一律回落 tmdb）、`:34`（const 默认）、`:62`（读偏好默认串 `'tmdb'`）。而入库的 `kBuiltinTmdbApiKey`（`scraper/tmdb_default_key.dart:20`）是空串，fresh clone / fork 构建恒为「未配置」——该文件自己的注释写着「留空时 TMDB 自动降级，其余数据源照常工作」，实现并没做到。
  2. **失败丢了结构**：`video_source_scrape_coordinator.dart:463-465`（修复前）把 `VideoMetadataResolutionStatus` 丢掉、只留 `String reason`，于是 UI（`video_source_scrape_dialog.dart:389-393`）既分不清「源没配」与「没匹配上」，也没法翻成中文 —— 面板外壳中文、每条原因英文。
  3. **27 条刷同一句**：错误按条目累加，没有「整批同因」的聚合。
- **[x] ① 已修复** — resolver 引入**降级链** `_resolutionChain()`：主源可用时只用主源（严格单主源语义不变）；主源未配置时按 `VideoMetadataProviderKind.values` 顺序取其余已配置的源逐个试，先 matched 者胜，全 notFound 才算没找到。识别（`FilenameParser` 解出标题/季/集）与刮削（provider 查询）本就分离，换源不需要重新识别。同时：
  - 绑定身份 / 文件名显式 id 所属的源未配置时，**落到标题搜索降级链**而不是整条失败（原先直接 `providerUnavailable`）。
  - `VideoMetadataResolution` 新增 `providerKind`（真正给出结果的源）。协调器构造歧义候选的 lookup 改用它（`video_source_scrape_coordinator.dart` `_resolveWork`）——否则降级到 Bangumi 后仍按 selectedProvider 取 id，一个候选都取不到。
  - `_ResolvedWork` 保留 `status`，新增 `describeVideoScrapeFailure()` 把结构化状态翻成中文可操作说明（未配置 → 引导去设置填 TMDB key 或改用 Bangumi/AniList；没匹配上 → 提示改文件名或写明 tmdbid=/bgm.tv 链接）。
  - 一个源都不可用时**整批只报一条聚合错误**（`registry.availableProviders.isEmpty` 前置判断），不再每条刷一遍。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_metadata_resolver_test.dart` 新增 4 条：未配置主源降级到 Bangumi（并断言未配置的源 `searchCalls == 0`，一次网络请求都不发）、主源可用时不碰其它源、绑定身份的源未配置时降级到标题搜索、一个源都没配仍报 `providerUnavailable` 且 reason 不再是 `tmdb is not configured`。原有 9 条（含 `unconfigured selected provider fails before network`）全绿，语义未破。`flutter test test/media/video/metadata test/torrent test/media/video/scraper --no-pub` → 689 passed。
- **备注**：合集页「刮削分集资料」入口在同一轮删除（TODO-2791）——它硬门「合集已刮削」，未刮时只会弹「请先刮削合集资料」，已刮时集名/集号本就由合集刮削管线 `VideoMetadataDatabaseStore.apply → _writeLegacyProjection` 写好了，是个死按钮。守卫 `fushi/test/pages/collection_manage_menu_guard_test.dart`（负向断言已做变异实测）。`episode_scrape_service.dart` 保留（仅剩测试引用），未随入口一并删除。
