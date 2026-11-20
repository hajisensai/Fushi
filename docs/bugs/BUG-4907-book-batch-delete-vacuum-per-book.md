## BUG-4907 · 批量删书每本都跑一次整库 VACUUM + wal_checkpoint
- **报告**：2026-11-20（路线图 #3722 c37 novel-7 + novel-d1）
- **真实性**：✅ 真 bug。
  - 根因：`fushi/lib/src/media/sources/reader_fushi_source.dart:1251-1252` 在 `deleteBook` 每次删完都无条件跑 `VACUUM` + `PRAGMA wal_checkpoint(TRUNCATE)`。书架批删（`reader_history/books.part.dart` 的 `_runBatchDelete`）、合集连删（`reader_fushi_history_page.dart` 的 `_deleteCollectionMembersMedia`）、同步删除确认（`app_model.dart` 的 `_applyConfirmedDeletions`）、Kavita 淘汰 / 一键清理（`kavita_book_service.dart` 的 `trimCache` / `clearCache`）逐本调用，N 本 = N 次整库重写。
- **[x] ① 已修复** — `deleteBook` / `deleteSrtShelfBook` 加 `compactDatabase`（默认 true，单删不变）；回收抽成 `ReaderFushiSource.compactAfterBookDeleteBestEffort`。上面四类批量调用方逐本传 false，确有书被删时在循环结束后回收一次（书架批删、合集连删、Kavita 放在 `finally`；`_applyConfirmedDeletions` 逐条自带 catch，放在循环后）。Kavita 新增 `KavitaDatabaseCompactor` 注入点。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/sources/reader_fushi_delete_cleanup_test.dart`「BUG-4907」组（Drift 拦截器数 VACUUM：单删 1 次；5 本 compactDatabase:false 为 0 次，批末 1 次且以 checkpoint 收尾）；`fushi/test/media/kavita/kavita_book_cache_test.dart`（淘汰 3 本 / 一键清理 2 本各只回收 1 次，没删不回收，移除下载 1 次）。
- **备注**：没有做真机批删 20 本的耗时 / 磁盘回收实测（本轮不做设备验证）。
