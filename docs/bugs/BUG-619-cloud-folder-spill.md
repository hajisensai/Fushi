## BUG-619 · 云盘进度文件溢出到父目录

- **报告**：2026-07-08（用户：真机截图，云盘文件浏览器 `我的文件 > hibiki-data`）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/sync/sync_manager.dart:261`（`ensureBookFolder(bookTitle: book.title)`）+ `hibiki/lib/src/sync/ttu_filename.dart:10`（`sanitizeTtuFilename('')` 原样返回 `''`）+ 各后端书夹拼接（如 `hibiki/lib/src/sync/webdav_sync_backend.dart:109` `path = '$rootFolderId${Uri.encodeComponent(sanitized)}/'`，空名时 == 同步根）。

### 根因

云盘同步的所有 per-book JSON（`progress_*` / `statistics_*` / `audioBook_*`）与内容（cover / epub / `.hibikiaudio`）唯一写入路径是 `SyncManager`：它按 **EpubBooks 行**迭代，对每行无条件用 `ensureBookFolder(bookTitle: book.title)` 定位书夹。`sanitizeTtuFilename('')` 返回空串，各后端把书夹拼成 `<root>/<sanitized>/`，**空 sanitized 时塌缩成同步根 `hibiki-data/` 本身**，于是一行 **title 为空的 EPUB 行**会把它的 `audioBook_1_6_<ms>_<sec>.json` 等文件写进根，散落在真实书夹（`屍人荘の殺人` 等）旁边。

- 云盘唯一写 `audioBook_*.json` 的业务调用点 = `sync_manager.dart:653`（`_handleExport`），folderId 恒 = 上面的 `ensureBookFolder`。局域网 live / host 接收走 `audiobook_pos_<bookKey>` prefs + HTTP 端点，**不写文件**，不会溅根。
- **跨设备/不对称点**：LAN sweep 经 `audiobookKeyFromPositionPrefKey` 天然过滤空 bookKey（`'audiobook_pos_'`→null，`hibiki_library_host_service.dart:492`），而云盘 `SyncManager` 对空 title 行**零守卫**——所以只有云盘会溅。删书从不清 `audiobook_pos_<bookKey>` prefs，孤儿进度让空 title 壳行 `posMs>0`、导出时真的写出 audioBook 文件到根。截图里「屍人荘の殺人 有正常标题却溢出」是用户按库归属的推断；溅根文件实际来自一行空 title 壳行（迁移边界 / 无标题导入残留）。

### 修复

- **[x] ① 已修复** — 分支 `todo1329-cloud-folder-spill`。防御纵深，对齐 LAN sweep「空 key 不同步」语义：
  1. 主修：`sync_manager.dart:_syncBookOnce` 顶部对 `sanitizeTtuFilename(book.title).isEmpty` 早退返回 `SyncResult.skipped`（覆盖 classic + 对比弹窗唯一 audioBook/progress/stats/cover/epub 写入路径）。
  2. 后端 backstop：新增单一守卫 `requireBookFolderName(bookTitle)`（`sync_backend.dart`），空名抛 `SyncBackendError`；7 个后端 `ensureBookFolder`（webdav / hibiki_client / dropbox / onedrive / sftp / ftp / google_drive_handler）统一走它——任何现/未来调用者都无法把书夹塌缩到根。
  3. `sync_orchestrator.dart:syncAudiobookPackages` 对 `book.bookKey.isEmpty` 跳过（防 `.hibikiaudio` 包溅根；bookKey ≡ sanitize(title)，且避开 BUG-414 源码守卫禁用的 `sanitizeTtuFilename(book.title)` 字面）。
  4. `sync_orchestrator.dart:isReservedSyncFolderName` 把空 / 纯空白名判为保留名（永不当作书夹导入）。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_empty_title_folder_spill_test.dart`（分支 `todo1329-cloud-folder-spill`）：
  - 路径契约单测：`requireBookFolderName('')` 抛 `SyncBackendError`、非空返回 sanitized；`isReservedSyncFolderName('')` / 纯空白 → true。
  - `SyncManager` 行为测试（记录型 fake backend）：空 title 书 → `skipped`，`ensureBookFolder` / 任何写入方法**从不被调用**（零根目录写入）；正常 title 书 → 导出进 `<root>/<name>/` 书夹，所有写入 folderId != 根。
  - 全 6 例绿；`flutter test test/sync/` 1169 例全绿；`flutter analyze` 净。

- **备注**：后续可选清理（本次未做，不影响 spill）：删书时一并清 `audiobookPositionPrefKey(bookKey)` / `audiobookPositionAtPrefKey(bookKey)` 消灭孤儿进度（`reader_hibiki_source.dart:deleteBook` / `audiobook_repository.dart:deleteAudiobook`）；并排查空 title 壳行的迁移 / 无标题导入来源。已溅到根的历史文件本修复不自动迁移（仅止血，不再新溅）。
