## BUG-2764 · CoreAudio 有声书同一合集连点多卷下载，第二卷报「无法创建下载」
- **报告**：2026-09-29（用户：「coreaudio有声书下载不能同时下载多个」，截图为「浏览 › 发现 › 书架 › 有声书」CoreAudio 源连点
  《やはり俺の青春ラブコメはまちがっている。》各卷「下载」，toast「无法创建下载。请检查下载设置和任务列表后重试。」）
- **真实性**：✅ 真 bug。CoreAudio 各卷都是同一颗 TMW 合集 torrent（截图每卷都标「TMW Part 1」）里的一个 m4b，
  `CoreAudioDiscoverySource.resolvePayload` 给出「整颗 .torrent + 只选这一卷的文件序号」，经
  `enqueueSelectedDiscoveryTorrent` 进 `VideoDownloadPipelineService.enqueueManual`。那里按
  `(fingerprint, torrentHash)` 查到上一卷的任务就直接抛 `VideoDownloadPipelineActionRequired('This torrent is already
  managed by job …; remove that task before selecting another volume from the same pack')`
  （`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart` 原 1032-1042 行），
  `download_actions.dart` 把它吞成 `GenericPushOutcome.pushFailed` → 「无法创建下载」。只下载型任务完成时本来就会把
  torrent 从后端摘掉并清空 `torrentHash` 让出槽位（同文件 `_resolveDiscoveryDownloadPaths` 收尾），所以上一卷没下完之前
  同包任何一卷都加不进来；`_enqueueTorrent` 的同一判据也会把这种任务直接打成「需要处理」。
- **[x] ① 已修复** — commit `aea2da1f3de`：保持「一颗 torrent 同时只归一个任务」的不变式，同包后一卷不再被拒，而是建成独立的
  只下载任务、先不占 `torrentHash`（唯一索引是 `WHERE torrent_hash IS NOT NULL` 的部分索引），身份留在
  `selectedResourceId`；`_enqueueTorrent` 撞上同包持有者时释放 claim、下个轮询周期再来（不进「需要处理」、不耗重试预算），
  持有者完成摘种子（或被用户删掉）后自动接手、按自己的文件选择暂停添加再恢复。`.torrent` 物化的 hash 复核回落到
  `selectedResourceId`。同一卷点两次（与同包未完成任务的文件选择重叠）抛新的 `VideoDownloadAlreadyQueued`，UI 提示
  「这一项已在下载队列中」（新 i18n key `download_selection_already_queued`，info 级 toast）。
  效果：可以一次把多卷都点进下载列表；同一合集里的卷按顺序一卷接一卷下，不同合集的卷照常并行。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart`
  「同包多卷选择（CoreAudio/TMW，BUG-2764）」：三文件合集 metainfo + 能暂停添加 .torrent 的假后端，走真实 `enqueueManual` 与
  worker：第二卷入队成功且不占槽位、重复点同一卷抛 `VideoDownloadAlreadyQueued`、worker 跑一轮后第二卷仍在 enqueue 且
  lifecycle active / lastError 空 / attemptCount 0、后端只加了一次、优先级只放行第一卷；模拟第一卷完成摘种子后第二卷接手并只放行
  第二卷。撤掉引擎修复时该测试以用户原始报错 `already managed … remove that task before selecting another volume` 失败。
- **备注**：未在真 app 里连点真实 CoreAudio 条目验证（需要真实下载 TMW 合集）；验证停在引擎层真实入队 + worker 路径。
