## BUG-3867 · sync-stuck-preparing-drive-listing
- **报告**：2026-10-28（用户：复习页顶部同步进度条一直显示「正在准备同步」）
- **真实性**：✅ 真 bug。用户本机（Google Drive App Data 空间 + 互联 host）实测：12:57:29 启动后的自动 sweep 到 13:02:54 才写下 `sync_last_sync_ms__googleDrive`，整整 5 分多钟进度行停在「正在准备同步」；本机互联目录里 `fushi-srs` 有 80,919 个文件。根因两层：
  1. `fushi/lib/src/sync/google_drive_handler.dart` 的 `snapshotListing` 用 `q: trashed=false` 把整个 appData 空间按 1000 条一页全部拉完，再在本地只留深度 1/2。复习同步 v2（2026-10-25）把操作分段写在同步根下 `fushi-srs/<profileUid>/v2/devices/<设备>/…`，深层文件数随复习量线性增长，于是每轮同步开头要白翻几十页（≈80 页）与书无关的分段。
  2. `fushi/lib/src/sync/sync_orchestrator.dart` 的 `run()` 在 `findOrCreateRootFolder` / `snapshotListing` / `pruneRootSpill` 这段网络步骤前不发任何阶段 tick，进度行退回 `syncActivityLine` 的兜底「正在准备同步」，与等锁 / 鉴权同形。
- **[x] ① 已修复** — 新增 `fushi/lib/src/sync/google_drive_listing.dart` 的 `listDriveSyncRoot`：只列根的直接子项，再把子文件夹按 40 个一组 OR 成 `'<id>' in parents` 查询列它们的直接子项；请求数与深层文件数无关。查询以同步根为界，原先「只在 App Data 空间启用」的限制随之取消（共享到可见 My Drive 时也能一次列举）。`run()` 开头新增 `SyncPhase.remoteListing` 阶段 tick（i18n `sync_progress_remote_listing`）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/google_drive_listing_test.dart`（假 Drive 树带 200 个深层分段：快照与旧语义逐条一致、只问过根与其直接子文件夹、请求数有界）；`fushi/test/sync/sync_orchestrator_test.dart`「第一个 tick 就是远端清单阶段」。
- **备注**：Dropbox 的 `snapshotListing`（`dropbox_sync_backend.dart`，`list_folder` recursive）同样会翻遍 `fushi-srs` 深层分段，Dropbox API 没有深度限制参数，本次未改（用户用的是 Drive），留作后续。真机未复测（用户未授权截屏）。
