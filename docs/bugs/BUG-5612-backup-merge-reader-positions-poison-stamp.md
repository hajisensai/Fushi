## BUG-5612 · 备份合并的 LWW 没有毒戳防护：备份里的未来时间戳永久压住本机真实进度
- **报告**：2026-11-28（架构审计顺带发现，审计文档见 PR #4614）
- **真实性**：✅ 真 bug。备份「合并」导入按 `updated_at` 裸比较取较新的一方，没有同步侧 BUG-3367 那套未来余量防护（`kSyncFutureStampToleranceMs` / `capFutureSyncStamp` / `trustedStoredSyncStamp`，`packages/fushi_engine/lib/sync/fushi_library_host_service.dart:2377-2389`）。备份里一条时钟走快的设备写下的戳（> 现在 + 5 分钟）永远胜出：压住本机较新的真实进度，并原样落进本库，之后本机正常的写入在任何 LWW 比较里都盖不过它；反过来本机已有的毒戳也永远挡住备份里的正常值。根因（develop `4d853cf791` 行号）：
  - `fushi/lib/src/sync/backup_merge_engine.dart:1358`（`_mergeReaderPositions` 的 UPDATE，`s.updated_at > reader_positions.updated_at`）与 `:807`（预览计数 `_countReaderPositionChanges` 的镜像）；插入缺失行时 `s.updated_at` 原样落地。
  - 同一机制的其它 LWW 合并：音乐歌单 / 远程曲目 / 歌词 / MV 绑定 / 逐曲断点（`:2124` / `:2175` / `:2188` / `:2207` / `:2264`）、书自定义 CSS（`:2297`）、漫画按作品覆盖设置（`:2325`）、书名 override（`:2422`）。
- **[x] ① 已修复** — 口径只定义一处：在同步侧旁边加 `capFutureSyncStampSql` / `trustedStoredSyncStampSql`（`fushi_library_host_service.dart`，与 Dart 版同一常量、逐值同结果），备份合并引擎收成两个判据 `_srcStampNewer`（两侧都按可信戳比较，毒戳按 0，平局保留本机——与同步侧 `mangaChapterStateReplaces` 同一口径）与 `_landedStamp`（落地戳截到未来余量内），上面列出的全部 LWW 语句改用它们；ON CONFLICT 带 `WHERE excluded.updated_at > …` 的两处（远程曲目、逐曲断点）改成在 SELECT 里判胜负，避免拿截过的戳去比。一次合并只取一次「现在」。只补缺模式（`fillMissingOnly`）与墓碑 / 排除书闸门不变。
- **[x] ② 已加自动化测试** — `fushi/test/sync/backup_merge_poison_stamp_test.dart`（真 DB + ATTACH + 真引擎）：SQL 口径与 Dart 函数逐值一致（含余量边界）；备份毒戳不压本机较新进度、预览不计；本机毒戳被备份正常进度盖掉（自愈）；本机没有的书进度照插但戳被截断；只补缺模式不动既有行；音乐断点 / 自定义 CSS / 漫画覆盖设置 / 改名备份毒戳都不压本机。
- **备注**：
  - 未改：可移植设置合并（`_mergePortableSettingsFromSource` 走 `settings_sync.dart` 的 `settingsToAdopt`，与在线设置同步共用，在线侧同样没有毒戳防护）、学习事实段（`_mergeStudySegments` 注释明确与 `AggregateMergeService.mergeStudySegments` 逐字同语义，在线侧也没有防护）、图片揭开时刻（`revealed_at` 只影响时刻、不影响揭开与否）。这三处要改应连同在线同步侧一起改，属跨子系统，另行处理。
  - 真机 / 模拟器未复测。
