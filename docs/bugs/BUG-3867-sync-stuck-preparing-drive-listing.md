## BUG-3867 · sync-stuck-preparing-drive-listing
- **报告**：2026-10-28（用户：复习页顶部同步进度条一直显示「正在准备同步」）
- **真实性**：✅ 真 bug。用户本机（Google Drive App Data 空间 + 互联 host）实测：12:57:29 启动后的自动 sweep 到 13:02:54 才写下 `sync_last_sync_ms__googleDrive`，整整 5 分多钟进度行停在「正在准备同步」。本机互联目录里 `fushi-srs` 有 80,919 个文件，其中 99.5% 是复习卡媒体（`v2/media` 40,319 个 + 旧格式 `<写入者>/media` 40,235 个），操作分段只有 346 个。根因三层：
  1. `packages/fushi_engine/lib/srs/srs_media_sync.dart` 的 `srsSyncMedia` 每轮对账都 `location.list('media')` 把位置上的媒体目录整个列一遍（旧格式兜底再列一遍），数万个文件在网盘上要按页列几十个请求；它跑在 `runOnAuthenticatedSyncChannels` / `syncChannelPostRunHook` 持有的全局同步锁里，书同步只能干等。内核早有 `Body::Media` 操作与 `sync2_media` 投影，但从没有生产代码写过，远端有什么只能靠列目录。
  2. `fushi/lib/src/sync/google_drive_handler.dart` 的 `snapshotListing` 用 `q: trashed=false` 把整个 appData 空间按页全部拉完，再在本地只留深度 1/2——同样被同步根下 `fushi-srs/…` 的数万个深层文件拖慢。
  3. `fushi/lib/src/sync/sync_orchestrator.dart` 的 `run()` 在解析根 / 列清单 / 清理残留这段网络步骤前不发阶段 tick，进度行退回兜底「正在准备同步」，与等锁 / 鉴权同形。
- **[x] ① 已修复** —
  - 媒体：新增操作 `MediaAt{location, flags, names}`（`native/fushi_fsrs/src/sync2/op.rs`，kind 12）与投影 `sync2_media_at` / `sync2_media_seeded`（`store/sync2/media.rs`，schema V7），FFI 命令 `media_known` / `media_record`。`srsSyncMedia` 传 `locationId` 时读日志投影：位置全系统只完整列举一次（结果带 SEEDED 写进日志），之后只对投影不认识的名字逐个查（`SrsLocationStore.exists`），确认结果写回日志；投影说在、读取时不在 → 记不在，持有者下一轮补传。设计文档 §6.4 已补。
  - Drive：`fushi/lib/src/sync/google_drive_listing.dart` 的 `listDriveSyncRoot` 只列根的直接子项与它们的直接子项（父目录 40 个一组 OR 查询），请求数与深层文件数无关；「只在 App Data 空间启用」的限制随之取消。
  - 进度：`run()` 开头新增 `SyncPhase.remoteListing` 阶段 tick（i18n `sync_progress_remote_listing`）。
- **[x] ② 已加自动化测试** — Rust：`store/sync2/tests.rs` 的 `media_presence_travels_in_the_log_and_converges`（两设备经段交换收敛、超限切条、不重复记）、`media_known_reports_absent_names_separately`，`op.rs` 编解码与超限拒绝；Dart：`packages/fushi_engine/test/srs/srs_media_presence_test.dart`（计数列目录次数：列举一次后不再列；被删自愈；不认识的名字逐个查并记账）、`fushi/test/sync/google_drive_listing_test.dart`、`fushi/test/sync/sync_orchestrator_test.dart`「第一个 tick 就是远端清单阶段」。
- **备注**：已知局限——记为「不在」之后由老版本设备补传上去的媒体，要等某台新版本设备本机持有它时才会重新记成「在」。Dropbox 的 `snapshotListing`（recursive `list_folder`）仍会翻到 `fushi-srs` 深层文件，API 无深度参数，未改。本地文件夹位置照旧列目录（本机文件系统）。旧格式 4 万个重复媒体仍留在位置上（设计 P7：用户手动清理）。真机未复测。
