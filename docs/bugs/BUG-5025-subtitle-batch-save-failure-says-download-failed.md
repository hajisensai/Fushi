## BUG-5025 · 合集字幕批量写盘或登记失败的行文案仍是「下载失败」
- **报告**：2026-11-20（路线图 #3722 遗留（docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md 第 3 节），c23 留下的「持久化失败的行文案仍是下载失败」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/subtitle/subtitle_batch.dart` 的 `runSubtitleBatch` 把写盘抛错与 `onItemDone`（持久化：设为这一集的字幕）抛错都只记成 `failed`，`subtitle_collection_panel.dart` 的行副标题一律 `describeSubtitleFailure(video_jimaku_download_failed, …)`——文件明明下下来了，用户却被引去换来源。
- **[x] ① 已修复** — d4e761be0c：`SubtitleBatchItem.failureStage`（download / write / persist），行文案按阶段出「已下载，但字幕文件保存失败」/「已下载，但设为这一集的字幕时失败」。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_batch_test.dart`（下载失败记 download；保存目录是文件 → write；onItemDone 抛错 → persist 且路径保留）。
- **备注**：行文案本身没有 widget 级断言（持久化走真实数据库与字幕解析，测试里没有让它抛错的注入点）。
