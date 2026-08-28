## BUG-1896 · 播放器选集横排缩略图乱序：番剧下载入库从不重排合集
- **报告**：2026-08-28（用户：截图，`Re：从零开始的异世界生活 第四季 丧失篇 - S04E14` 的选集轨显示顺序 `13 | 01 02 | 07 08 | 05 | 03 04 06`）
- **真实性**：✅ 真 bug。

### 根因

卡片的**位置**和卡片上的**角标集号**来自两条互不相干的通道：

- **位置** = `media_collection_items.sortIndex`。装配在
  `fushi/lib/src/pages/implementations/video_fushi_page.dart:2182`（`getCollectionItems` →
  `_episodes`），排序在
  `packages/fushi_core/lib/src/database/database_library.part.dart:636`
  （`orderBy sortIndex, entryKey, mediaType`）。而 `sortIndex` 是**纯尾插序** ——
  `database_library.part.dart:676` 的 `_nextCollectionSortIndex` 取当前 max+1。
- **角标** = 渲染时从文件名现算的真集号。
  `fushi/lib/src/pages/implementations/video_fushi/episode.part.dart:225`
  （`parsedEpisodeNumberOf`）→ `fushi/lib/src/media/video/video_episode_rail.dart:157`。

番剧下载导入器 `fushi/lib/src/media/torrent/anime_download_importer.dart:70` 只用
`sortVideoPathsByEpisode` 排了**本批**路径，随后 `importSplitPlaylist`
（`fushi/lib/src/media/video/video_book_repository.dart:159`）对**已存在**的合集是尾插
（`:218` 的 `addToCollection` 循环）。于是每批下载 = 「批内升序、整段追加到表尾」的区块，
跨批次顺序 = 下载完成先后。用户看到的 `13 | 01 02 | 07 08 | 05 | 03 04 06` 正是这个形状。

仓库里**已有**确定性修序原语 `VideoBookRepository.reorderDownloadedCollectionEpisodes`
（`video_book_repository.dart:232`，走 `regroupMembersBySeason` 按季/集重排），
但只有下载中心 pipeline 调它（`video_download_pipeline_service.dart:2760`），
番剧下载这条路 `grep reorder` 零命中。

播放器浮层、合集详情页（`collection_episode_slot.dart:77`）、视频库页
（`video_library_overview.dart:118`）读的是同一个坏 `sortIndex`，所以三处一起乱；
详情页因为有手动「按季重排」菜单（`media_collection_detail_page.dart:2292`）才救得回来，
播放器浮层没有任何入口。

### 修复与测试

- **[x] ① 已修复** — `anime_download_importer.dart` 在 `importSplitPlaylist` 之后显式调用
  `reorderDownloadedCollectionEpisodes(result.collectionId)`，与下载中心 pipeline 用同一条
  纪律、同一个原语，让「自动下载填充的合集按季/集有序」成为入库语义的一部分。
  同时改正 `sortVideoPathsByEpisode` 那段说「保证入库后合集成员顺序 = 集号顺序」的注释
  —— 那句话正是本 bug 的认知根源（批内排序被误当成合集顺序的真相源）。
  与 pipeline 侧一致**不吞异常**：重排失败就让 `AnimeDownloadService` 把计划标 failed，
  而不是留一个顺序错乱的合集装作成功。
- **[x] ② 已加自动化测试** — `fushi/test/media/torrent/anime_download_importer_reorder_test.dart`：
  模拟「独立任务乱序完成 + 分两批到达」，断言入库后合集成员顺序 = 集号顺序。

### 备注

- **存量数据不会自动痊愈**：本修复只作用于此后每一次番剧下载入库。已经乱掉的合集会在
  该系列**下一集下载完成时**被整体重排（重排作用于整个合集，不只本批）；已完结、不会再有
  新集的合集需要用户在合集详情页手动「按季重排」。没有做一次性迁移 —— 手动 playlist
  导入的作者序是有意保留的（`reorderDownloadedCollectionEpisodes` 的方法注释即此约定），
  全库盲扫重排会破坏它。
- 调查中发现的**相邻不一致**（未修，另计）：自动修序的两个入口用了两种文件名解析口径 ——
  `video_folder_group_coordinator.dart:288` 用 `parseVideoFilename(basename)`（只看文件名），
  `collection_season_groups.dart:122` 用 `parseVideoPath`（看整条路径，认得出 `Season 2/` 父目录）。
  角标用的是后者。`Show/Season 2/01.mkv` 这类布局下两者会得出不同的季号。
- 未做真机复测（本轮为纯 DB 顺序修复，行为由单测覆盖）。
