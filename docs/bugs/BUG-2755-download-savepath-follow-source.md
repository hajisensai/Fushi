## BUG-2755 · 删除/更换来源后视频下载仍落旧位置
- **报告**：2026-09-28（用户：删掉来源后下载仍落在旧位置；把订阅改到新来源后仍在旧位置下载。用户拍板：下载直接进来源目录，不再先落全局下载根再搬）
- **真实性**：✅ 真 bug（沿代码路径确认，见下「根因」；行号均为 develop `3d5d1608ed2`）
- **[x] ① 已修复** — `bcf5a464c0e`（分支 claude/video-dl-source-savepath）
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart`（group `BUG-2755 download save path follows the target source`，10 条）、`fushi/test/media/source_library/source_library_removal_test.dart`（8 条）、`fushi/test/media/video/download/video_download_subscription_service_test.dart`（「目标来源失效的旧任务恢复前改绑到订阅的当前来源」）、`fushi/test/media/torrent/download_save_root_test.dart`（group `BUG-2755 来源暂存目录`）、`fushi/test/torrent/qbittorrent_client_test.dart`（savepath 带 `autoTMM=false`）
- **备注**：未真机验证（内置 libtorrent 显式 savePath 与远程 qB 路径映射只有单测/代码审查覆盖）；fushi_server 的来源重建后孤儿订阅重绑留作后续，见下。

### 根因

1. **下载器落点只看全局下载根**。`packages/fushi_engine/lib/media/torrent/embedded_torrent_backend.dart:116`
   `savePath = _saveRoots.categoryPathFor(category)`（根来自偏好 `downloadSaveRoot`），
   qB `qb_torrent_backend.dart:68` 只 `ensureCategory` 不传 savepath；管线
   `_enqueueTorrent`（`video_download_pipeline_service.dart:1780-1838`）只传 category。
   来源只在整理阶段 `_organizeDownload` 经 `_managedSource(job)`（:3849）+ organizer
   `moveStorage` 用到——所以下载期间文件总在旧的全局根里。
2. **删来源只让 FK 置空**。`packages/fushi_core/lib/src/database/database_library.part.dart:39-50`
   只回写 grouping 后硬删，`VideoDownloadSubscriptions.targetSourceId`（tables.dart:2360）与
   `VideoDownloadJobs.targetSourceId`（:2181）被 setNull，偏好 `video_download_target_source_id`
   不清。在途任务整理时 `_managedSource` 抛 `managed video source no longer exists` →
   needsAttention；`retryJob`（:1173）不重新解析来源；订阅 `_enqueueItem` 恢复的旧任务同样不改绑。
3. **改订阅来源只写订阅行**。`video_download_subscriptions_panel.dart:246-262`；订阅派生任务
   固化 `targetSourceId`（`video_download_subscription_service.dart:689-693`），已派出的集照旧
   整理进旧来源。
4. **同 hash 旧任务永久拦路**。`(fingerprint, torrent_hash)` 唯一索引
   （`database_infra.part.dart:199-204`）：`enqueue()` 直接插带 hash 的新行会撞索引；hash 物化
   后才知道的新任务被 `findVideoDownloadJobByFingerprintAndTorrentHash`（:1796-1801）拦成
   「already managed」。

### 修复

- `TorrentBackend.addTorrent` / `TorrentMetainfoBackend.addTorrentMetainfo` /
  `TorrentPausedMetainfoBackend.addTorrentMetainfoPaused` 加可选 `String? savePath`（后端视角）；
  内置引擎显式落点优先（`_prepareSavePath`），qB 传 `savepath` 并带 `autoTMM=false`（否则分类
  开了自动管理时 qB 无视 savepath）。
- 管线 `_incomingSavePath`：受管任务落 `<来源根>/.fushi-incoming/<category>`（`download_save_root.dart`
  的 `kSourceIncomingDirName` / `sourceIncomingCategoryPath`），配了路径映射就经
  `_mappingForLocalPath(...).localToRemote` 换成后端视角；非受管任务 / 无来源 / 来源不可用 /
  来源不在任何映射里时返回 null，回退全局下载根。整理阶段逻辑不动，同盘 move 变目录内改名。
- 暂存目录不在任何下载根下：`TorrentSaveRoots.ownsCategoryPath` 加
  `isSourceIncomingCategoryPath` 认领，否则内置引擎按分类列任务找不到种子、下载阶段把它判丢。
  扫描器经 `excludeSourceIncomingEntries`（`source_library_scanner.dart`）跳过本地来源的暂存目录，
  不导入下到一半的文件。
- 删来源：`countVideoDownloadReferencesToSource` 统计订阅与未整理完任务（阶段
  `kVideoDownloadSourceRebindableStages` = enqueue/download/organize）；`deleteMediaSource` 加
  `migrateVideoDownloadsTo` / `disableVideoDownloadSubscriptions`，同一事务改写或停用；
  UI（`media_sources_view.dart` `_SourceRemovalDialog`）有引用时给迁移目标下拉（默认第一个可用
  来源，可选「不迁移（暂停这些订阅）」）；`removeSourceLibrary` 同时把指向被删来源的默认下载来源
  偏好改指迁移目标或清空。新 i18n key：`media_source_remove_download_refs` / `media_source_remove_download_keep`。
- 改订阅来源：`updateVideoDownloadSubscriptionRetargetingJobs` 同事务把经 `subscription_items.job_id`
  关联、未完成且仍在 enqueue/download（`kVideoDownloadPreOrganizeStages`）的任务改到新来源；已交下载器
  的种子不强制搬，整理阶段搬进新来源。整理中的任务不动（可能已把文件改名进旧来源）。
- `retryJob`：failed/needsAttention 且来源不可用时先改绑到订阅当前来源，再退到
  `defaultTargetSourceId`（app = `_defaultVideoDownloadSourceId`，服务端 = 自己的下载来源）。
  订阅自动恢复旧任务前同样改绑（`_rebindUnusableJobSource`）。
- 同 hash：`enqueue()` 遇到来源失效的 failed/needsAttention 旧任务时改绑到本次请求的来源并按
  用户重试恢复、返回旧 jobId（不再撞唯一索引）；`_enqueueTorrent` 物化后才对上 hash 的情况用
  `supersedeVideoDownloadJob` 让新任务接管（订阅条目改指新任务、删旧任务行，后端种子不动）。

### 后续 / 风险

- **远程 qB 路径映射**：落点换成后端视角依赖用户配置的映射覆盖来源根；来源不在任何映射里时回退
  全局根（整理阶段照旧报 outside mapping）。没配映射时按「同机同视角」直接传本机路径——远程 qB
  没配映射本来整理也过不去，但现在下载阶段就会让 qB 往一个它那边不存在的本机路径建目录。
- **fastResume 旧任务**：已在引擎里的旧种子 save_path 不变（还在全局根或被删来源的暂存目录），
  整理阶段 moveStorage 搬进新来源；若被删来源的目录连同下到一半的文件一起被删，旧种子需要重新校验/重下。
- 接管后若新任务是「合集内选择单个文件」（暂停态添加），`_addSelectedTorrentPaused` 仍拒绝接管
  后端里已有的同 hash 种子（保持原安全边界）。
- `enqueueManual` 的同 hash 路径未改（仍撞唯一索引）。
- **fushi_server**：服务端没有删来源入口；`_ensureDownloadSource` 在来源行缺失时新建一行，但
  已置空 `targetSourceId` 的订阅不会自动改绑——留作后续（启动时把孤儿订阅绑到新行）。app 作为互联
  host 时删来源走的是同一个 UI / 同一个库，已被本修复覆盖。
