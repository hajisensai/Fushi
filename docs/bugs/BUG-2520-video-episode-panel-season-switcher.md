## BUG-2520 · 播放器「选集」面板对多季合集没有季切换
- **报告**：2026-09-13（用户：截图「选集 · まひろとおしまいとこれから」，一条平铺长轨道，「选集缺少切换季」）
- **真实性**：✅ 真 bug。季分组在本仓是文件名纯函数（`packages/fushi_engine/lib/media/collections/collection_season_groups.dart` `collectionGroupKeyForFilename`），合集详情页据此出季 tab（`media_collection_detail_page.dart` `_rebuildSections`）；但播放器把合集成员平铺成 `_episodes`（`video_fushi_page.dart:2559` 建 `_PlaylistEpisodeRef`），`episode.part.dart` `_episodePanelEntries()` 转成 `VideoEpisodeEntry` 时从没带分组键，`VideoEpisodePanel` 也没有任何分节概念——多季合集在播放器内只有一条混着 S01/S02/PV 的长轨道。
- **[x] ① 已修复** — `VideoEpisodeEntry.groupKey`（页面层用同一 `collectionGroupKeyForFilename(path ?: title)` 派生，本地/远端同口径）；`VideoEpisodePanel` 内按 `buildCollectionSeasonSections` + `sortCollectionSeasonSections` 切成季（季升序、PV·特典殿后），≥2 节时头部下出 `ChoiceChip` 季行，默认停在当前集所在季、换集跟随；`VideoEpisodeRail` 新增 `indices` 把切片位置映回全局下标（卡片 key / 选中态 / 点击回调全是全局下标，顺位号回落用轨道内位置）。单季/纯电影零变化。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_episode_panel_seasons_test.dart`：单季不出 chip；多季 chip 序与默认停在当前季；切季换轨道、点卡片报全局下标、PV 组顺位号从 01 起、换集 chip 跟随。
- **备注**：远端成员没有路径，组键从 host 下发的 title 解析（与既有集号解析同口径）；title 不带季号时全表同键 → 不出 chip，行为与修前一致。
