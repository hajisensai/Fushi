## BUG-2750 · 浏览视频发现搜索为空且结果不准
- **报告**：2026-09-28（用户：浏览里的视频发现搜不到东西；搜出来的也不准、结果不对）
- **真实性**：✅ 真 bug，两段根因，均用真网络探针（生产 `VideoDiscoveryService.production`）复现：
  - **搜不到**：`fushi/lib/src/media/video/discovery/video_discovery_service.dart:95` 的 `searchProviderIds` 只登记刮削 registry 派生的 MAL / TMDB（BUG-2398「来源统一」时把 AniList 排除出搜索）。2026-09-28 实测 Jikan 全站 504、TMDB 未配 key（开发构建内置 key 为空，401），两路全失败 → 所有查询 `successfulProviderCount=0`，而同一时刻 AniList 搜索正常、推荐流也正常。
  - **不准**：`fushi/lib/src/pages/implementations/video_discovery_page.dart:103` 搜索时仍下发默认排序 `popularity`：AniList 适配器据此用 `POPULARITY_DESC` 而不是 `SEARCH_MATCH`，TMDB 把多页搜索结果按 popularity 重排——沾边的热门作品排到精确命中前面。另外 `video_metadata_discovery_provider.dart` 对番剧分类先拼完整页剧场版再拼 TV，MAL 的正片被一串剧场版模糊命中挤到后面。
- **[x] ① 根因修复** — AniList（发现域来源，不进刮削 registry）重新登记为搜索源，AniList 结果带 MAL id，与 MAL 结果按强 ID 合并不重复；页面排序改为「用户没选时：搜索默认相关度、浏览默认热度」，显式选择原样下发、清空关键词后相关度回落热度；元数据搜索适配器按名次交错各类型结果（TV 在前）。
- **[x] ② 自动化测试** — `fushi/test/pages/video_discovery_page_test.dart`（搜索默认相关度 / 显式排序 / 清空回落）、`fushi/test/media/video/video_metadata_discovery_provider_test.dart`（TV 与剧场版按名次交错）、`fushi/test/media/video/discovery/video_discovery_aggregated_sources_guard_test.dart`（生产搜索源含 AniList 且 AniList 不在刮削 registry）。定向 96 项通过（退出码 0）。
- **备注**：真网络探针（修复后）：Jikan 504 + TMDB 无 key 条件下，`葬送のフリーレン` → 葬送のフリーレン 及续季，`进击的巨人` → 進撃の巨人，`孤独摇滚` → ぼっち・ざ・ろっく！。本条修改了 BUG-2398「AniList 不再参与生产作品搜索」的决定：该决定让番剧搜索单点依赖 Jikan。未在真 app 界面里复测。
