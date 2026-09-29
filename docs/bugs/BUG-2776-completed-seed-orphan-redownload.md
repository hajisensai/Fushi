## BUG-2776 · 改来源后旧来源的已完成种子仍做种且文件删后重下
- **报告**：2026-09-29（用户：把订阅都改成 `D:\smb\动漫` 后仍在 `D:\smb` 下载，删掉还在下。用户拍板：改来源也要把旧的种子清掉）
- **真实性**：✅ 真 bug（用户真实数据取证 + 沿代码路径确认，见下「根因」）
- **[x] ① 已修复** — `a5e47afb99a`（PR 分支 pr/video-dl-prune-orphan-seeds）
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart`（group `BUG-2776 completed seeds leave the engine with their source`，3 条）、`fushi/test/media/torrent/resume_prune_guard_test.dart`（keepIds 走 `loadEmbeddedTorrentResumeIds`）
- **备注**：未真机验证；用户现存的 19 颗孤儿种子要装上含本修复的构建后重启一次才会被剪掉。

### 取证（用户生产数据根 `%APPDATA%\Fushi\Fushi`）

- 唯一来源 `id=5 → D:/smb/动漫`，三个订阅 14:46–15:05 已改指它；15:06 前后**没有任何新任务**。
- 内置引擎 resume 目录 `D:\文档\anime_downloads\resume` 有 21 颗种子，19 颗 `save_path = D:/smb`，
  文件已被整理改名为 `作品 (2026)/Season XX/… - SxxEyy.mkv`；对应任务全是 import/scrape
  **completed**，`target_source_id` 全为 NULL（原根为 `D:/smb` 的来源被删、FK 置空）。
- 用户删掉 `D:\smb` 下的目录后，引擎续传在原处重建目录重下（Re:0 468/1388 块、BLEACH E42 1028/1799 块…）。

### 根因

1. 受管任务整理完成后 moveStorage 到来源根**继续做种**（`video_download_organizer.dart:382-385`，
   `video_download_pipeline_service.dart` 仅「仅下载」策略完成时 removeTorrent）。
2. resume keepIds `legacyEmbeddedTorrentResumeIds` 保留所有非 legacy 的 completed embedded 任务，不看来源
   是否还在；启动时 `ht_load_resume_dir` 清 paused 直接开跑，缺文件按正常优先级重下。
3. 删来源（`deleteMediaSource`，`database_library.part.dart`）只迁移未完成任务（BUG-2755），
   已完成任务的种子无人处理；改订阅来源（`updateVideoDownloadSubscriptionRetargetingJobs`）同样只改未完成任务。

### 修复

- 判据 `videoDownloadJobIsOrphanedCompletedSeed`：已完成的受管任务（`videoDownloadJobUsesManagedSource`，
  排除 legacy / 按域入库 / 仅下载），目标来源为 NULL 或已不存在。
- `legacyEmbeddedTorrentResumeIds` 加必填 `liveSourceIds`，按判据剔除；新 helper
  `loadEmbeddedTorrentResumeIds(db)`（任务行 + 当前来源）供 app 两处与 fushi_server 两处共用。
  重启时孤儿 resume 被剪、不再续传——存量孤儿也由此清掉。
- 流水线 `releaseOrphanedCompletedSeeds()`：运行中把孤儿种子 `removeTorrent(deleteFiles: false)`，
  成功（或确认后端已无此种子）后清 `backendTaskId` / `torrentHash`；失败保持原样下次再摘。
  `removeSourceLibrary` 删来源后调用。
- `releaseSubscriptionSeedsOutsideTarget(subscriptionId)`：改订阅来源后摘掉该订阅名下目标来源 ≠ 新来源的
  已完成集；订阅面板改来源后调用。未完成的集照旧由 BUG-2755 改绑流程带进新来源。
- DB 新增 `getVideoDownloadSubscriptionJobIds`（改订阅来源事务复用）。

### 后续 / 风险

- 只摘种子不删文件：旧来源下已整理的文件与任务行保留，用户可在库里照常播放 / 自行删除。
- 被摘种子不再做种、下载页不再显示其上传数据（与「仅下载」任务完成后同形态）。
- 外接 qBittorrent 的存量孤儿只在下次删来源时由 `releaseOrphanedCompletedSeeds` 顺带摘除，启动时不主动扫。
