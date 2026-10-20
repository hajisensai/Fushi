## BUG-3622 · 放送日历标题全是罗马字 + 关掉「显示本季全部」后为空
- **报告**：2026-10-20（用户：「日历好像是英文的」「不勾选选中本季全部的话是空的」，附截图）
- **真实性**：✅ 真 bug（两处）。
  1. 标题：`fushi/lib/src/pages/implementations/airing_calendar_page.dart` 条目标题用 `AniListMedia.displayTitle`（`fushi/lib/src/media/video/anilist_client.dart:41`，罗马字 → 英文 → 日文），这是给 nyaa / Jimaku 搜索用的口径；发现页 AniList 适配器（`packages/fushi_engine/lib/media/video/discovery/video_discovery_adapters.dart:921`）展示的是 `native ?? romaji ?? english`。两处口径不一致，中文界面整页罗马字。AniList 没有中文标题字段，能给的是日文原名。
  2. 「相关」视图：`_load()` 的订阅 id 集合只读旧版 `AnimeDownloadSubscriptionStore`，不读发现页订阅表 `video_download_subscriptions`——而从日历条目点进发现详情页订阅，写的正是后者，于是新订阅的番在「相关」视图里永远不出现、也不带「订阅中」徽章。用户库（只读查询）里合集绑定的 anilistId 只有 3 部完结旧番，发现页订阅 3 条（其中 Re:Zero 第四季走 Bangumi 元数据、无 AniList id），本周确实没有相关放送；空态只有一句话，没有出口。
- **[x] ① 已修复** — 新增 `AniListMedia.nativeFirstTitle`（日文原名优先，`displayTitle` 保持罗马字优先给搜索），日历标题与 `discoveryItemFromAiringEpisode` 改用它（罗马字留在 aliases）；新增纯函数 `anilistIdOfVideoDownloadSubscription`（identity_json 的 anilistId 优先，否则仅 metadata_provider=anilist 的 external_id；Bangumi / TMDB id 一律不当 AniList id），日历把两套订阅取并集；本周空态加「显示本季全部」按钮直达全量。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/airing_discovery_mapping_test.dart`（标题口径、订阅行 → anilistId 三种来源含 Bangumi 负例）。
- **备注**：Bangumi 元数据的订阅（无 AniList id）仍不会进「相关」视图，需要 Bangumi → AniList 的 id 映射才能补，本轮不做。
- **集成说明（2026-10-20 合批）**：同批的 #2423 按用户同日决定去掉了「显示本季全部」开关、放送表恒取当季全量，「相关」视图与它的空态按钮随之消失；两套订阅取并集的逻辑移进共享取数 `fushi/lib/src/media/video/airing_calendar_loader.dart` 的 `loadAiringCalendarWeek`（日历页与发现页「今日放送」共用），只驱动「订阅中」徽章。
