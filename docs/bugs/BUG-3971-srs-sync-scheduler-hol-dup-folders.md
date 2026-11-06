## BUG-3971 · srs-sync-scheduler-hol-dup-folders
- **报告**：2026-11-02（PR #2768 / #2764 审查：SRS 同步调度 / 旧根媒体后台迁移的并发与排队问题）
- **真实性**：✅ 真 bug（沿代码路径核实，四处）
  1. 文件夹位置的后台迁移每补一批绑定就 `unawaited(_publishFolderV1Bindings())` → `syncFolderLocations()` 直接 `_serially(...)`，不像 `syncWithBackend` 那样合并排队请求：大库排上百轮全量文件夹轮次，堵住通道与互联 host 目录（队头阻塞）。根因 `fushi/lib/src/srs/srs_sync_scheduler.dart:1166`（修前 `syncFolderLocations() => _serially(...)`）。
  2. 一轮同步、发段前媒体上传、完整媒体对账、后台旧根迁移各建一个 `SrsAssetLocationStore`，建文件夹只在实例内 `_once` 去重；Google Drive `ensureFolder` 先查后建不原子 → 并发建出同名 `media/<前2>/`，按路径只认第一个，另一个里的对象对所有读者不可见。根因 `packages/fushi_engine/lib/srs/sync2/srs_location_store.dart:315`（修前 `_folder()` 实例内单飞 + 取第一个同名文件夹）。
  3. quiesce 置 halted 后，`SrsV1MediaMigrations` 的 finally 仍无条件起 `_again` 里排着的下一次，`run()` 在首个 `_halt()` 检查前先整树列旧根和新根内容目录，关库被多拖两次全量列目录。根因 `packages/fushi_engine/lib/srs/sync2/srs_location_migration.dart:1587`（start / finally）与 `:1004`（run 开头）。
  4. 每位置复习同步开关只在一轮开头检查，正在跑的那一轮与它的后台迁移只认全局 `_halted`，关掉卡住的位置无法即时生效。根因 `fushi/lib/src/srs/srs_sync_scheduler.dart:637`（修前 runner / 迁移的 `shouldStop: () => _halted`）。
- **[x] ① 已修复** —
  1. `syncFolderLocations` 加「排着未开跑就复用」合并（`_queuedFolderRound`，与 `syncWithBackend` 同语义），`settle` 一并等它。
  2. 建文件夹 / 顶层命名空间按后端身份进程内单飞（`srsEnsureFolderShared` / `srsEnsureNamespaceShared`，`Expando` 按身份只记在途）；调度器经 `srsAssetLocation` 建实例，身份取防扫盘混淆包装的里层（`srsBackendIdentityOf`）。读路径重写为「一个路径 = 全部同名文件夹」（`_dirs`）：列目录取并集、get / getFile / exists / putNew 在每个里找、delete / 覆盖写删掉每个里的同名旧份；存量重复目录里的对象重新可见。
  3. `SrsV1MediaMigrations` 接 `shouldStop(locationId)`：收手时 `start` 不起不记、finally 丢掉排着的；`_MediaMigration.run()` 在列旧根前后、列新根内容目录后各检查一次。
  4. 调度器 `_locationStopped(id) = _halted || 位置被关`：通道 runner、后台迁移、文件夹位置（含新传入 `srsSync2Round` 的 `shouldStop` 与完整媒体对账前检查）都用它；一轮跑完 / 收手后位置已被关就按 `kSrsSyncLocationDisabled` 交回、跳过发布与媒体对账。迁移本就在后台（不进 `_serially`），加上 1 的合并，一个位置的长迁移不再挡别的位置。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/sync2/srs_location_duplicate_folders_test.dart`（不同实例 / 每次新包一层的后端并发建目录只建一次；存量同名文件夹读写删都看全部）、`packages/fushi_engine/test/srs/sync2/srs_v1_media_migration_stop_test.dart`（收手后排着的不起、run 不列目录）、`fushi/test/srs/srs_sync_scheduler_test.dart` 组「按位置收手与发布轮合并」（文件夹发布轮合并、轮中关位置按关掉交回不做媒体对账、关位置后台迁移收手）。
- **备注**：完整媒体对账 `srsSyncMedia`（srs_media_sync.dart，不在本次改动范围）内部没有收手检查点：位置关掉时只能在它开头前拦住，已开跑的一次媒体对账跑完才停。`srsPrepareLocation`（设备段搬迁）也没有收手点。
