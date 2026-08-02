## BUG-1416 · 番剧下载自动入库不记 added 活动事件
- **报告**：2026-08-02（TODO-2556）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/torrent/anime_download_importer.dart` 全文 `grep -n "Activity\|recordActivity"` 零命中（129 行，入库主体 :58-127）：番剧下载完成后 `importSplitPlaylist` 返回就直接去绑 AniList / 抽封面，从不记 `added` 活动事件。视频域其它入库路径（对话框 5 处 `video_import_dialog.dart:366/462/481/559/634`、扫描首导 `source_library_scanner.dart:758`）全都经 `VideoBookRepository.recordVideoImportActivity`（`video_book_repository.dart:140`）记账，只有下载这条漏了 → 首页 dashboard / 时间轴看不到番剧入库。引入者 `buildAnimeDownloadImporter`（commit `5dbd4b179`）自始未接活动流。
- **[x] ① 已修复** — `anime_download_importer.dart:73-87` 在 `importSplitPlaylist` 返回后按既有范式记 1 条（整本 1 条，`title=plan.seriesTitle`、`mediaKey=首集 uid`，与对话框 / 扫描首导同粒度）。

  **重复 emit 的根因处置**：`reuseExistingPaths: true` 存在崩溃重放（DB 已提交、计划 flag 未回写）——旧返回值 `({collectionId, episodeUids})` **区分不了「本次真新建」与「复用既有」**：`episodeUids` 是新旧混合列表，`collectionId` 也可能是 `createMediaCollection` 按自然键复用出来的既有 id。所以修的是**判据的数据结构**，不是在活动流侧兜：`importSplitPlaylist` 事务内本来就知道哪几集是自己插的，只是把这个事实丢掉了 → 现在返回 `SplitPlaylistImportResult`（`video_book_repository.dart:24-45` typedef）多带一个 `createdEpisodeUids`（有序子集），emit 条件 = `createdEpisodeUids.isNotEmpty`。全复用 → 一条不记；同系列后续批次带来新集 → 记 1 条（那是真新增内容）。

  为什么**不**在活动流侧做幂等：`addActivityEvent` 的契约明写「纯追加，不去重、不累加」（`packages/hibiki_core/lib/src/database/database.dart:4111`），`activity_events` 表也无唯一索引；read/watch/game 三类事件依赖这个纯追加语义。为一类事件在共享写入点加去重会破坏其余三类。也**没有**用时间窗 / sleep / 去重表这类掩盖手段。

  为什么**不**在 importer 里于调用外自己重扫一遍路径判新旧：那份判据必须与事务内的 `normalizeVideoPath` 归一规则逐字节一致，一旦漂移就把重放误判成新增——同一判据两处实现正是这个 bug 的复发温床。

- **[x] ② 已加自动化测试** — `hibiki/test/torrent/anime_download_importer_test.dart`（4 条新用例，全部变异实测过）：
  - `下载入库真新增：整本记 1 条 added（title=系列名、mediaKey=首集 uid）` — 变异 `episodeUids.first` → `.last`，仅此条红。
  - `崩溃重放（同批路径重跑复用既有条目）：不重复记 added` — 变异守卫 `createdEpisodeUids.isNotEmpty` → `episodeUids.isNotEmpty`（= 本 bug 的天真修法），仅此条红。
  - `added 事件的 media_type 落 ActivityMediaKind.video，不是裸字符串` — 变异 `kActivityMediaVideo` → `kActivityMediaBook`，仅此条红。
  - `同系列后续批次带来新集：真新增，再记 1 条（幂等判据不是「合集已存在」）` — 变异守卫为 `createdEpisodeUids.length == episodeUids.length`（过严的「全新才记」），仅此条红。
- **备注**：`SplitPlaylistImportResult` 是新增 typedef，替换了原先在 4 个 lib 调用点 + 7 个测试断言里手抄的匿名 record 类型；`reuseExistingPaths == false` 的路径（对话框 / 扫描首导）行为一字未变（每集都是新建，`createdEpisodeUids == episodeUids`）。
