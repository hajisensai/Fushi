## BUG-4702 · 在线漫画不跟随下载目录设置，删书后已下载章节无法重新入库
- **报告**：2026-11-15（用户：Android 用户反馈，经委托方转述）
- **真实性**：✅ 真 bug，三个根因：
  1. 下载根偏好 `download_save_root` 只被 torrent / 发现页消费（`fushi/lib/src/models/app_model.dart:7619`（`downloadSaveRoot` getter，消费方只有 torrent 与 `discoveryDownloadDirFor`）），在线漫画书目录从书库根派生：`fushi/lib/src/media/manga/library/online_manga_library_service.dart:127`（`MangaStorage.bookDirectory(bookKey)`）与 `:378`（`ensureBookDirectory` 目标 `MangaStorage.bookPath`），改下载目录对漫画无效；音乐插件下载同理固定在 `<documents>/music_downloads`。
  2. 删书只有「整本连目录删」一条路：`fushi/lib/src/media/sources/reader_fushi_source.dart:1232`（`EpubStorage.deleteBookDir(bookRow.extractDir)`），入口 `fushi/lib/src/media/manga/library/manga_series_page.dart:1269` `_removeFromLibrary`。
  3. 书目录里没有可逆的源身份：bookKey 是 sha256 单向哈希，行删掉后目录无从重建书架行，卡片背面的来源（按 uid → bookKey 找书，`card_source_router.dart:38-50`）随之失联。
- **[x] ① 已修复** — PR 分支 `pr/unified-download-root`：一个下载根 + 各域子目录（`download_layout.dart`），在线漫画落 `<下载根>/manga/<bookKey>` 并在首次访问时把存量目录搬过去；改根可选搬移已下载内容（`download_root_migrator.dart`，合并复制可续、失败回报）；删书默认「保留已下载章节」，书目录写侧车 `fushi_shelf.json`；下载任务页「重新入库」按侧车原样还原 bookKey + uid；备份新增 `download_manga/` 前缀。
- **[x] ② 已加自动化测试** — `fushi/test/storage/download_root_test.dart`、`fushi/test/media/manga/manga_series_page_remove_from_shelf_test.dart`、`fushi/test/pages/reader_history_delete_dialog_test.dart`、`fushi/test/media/manga/online_manga_library_test.dart`。
- **备注**：未在 Android 真机复测改根搬移与外置目录（SAF 实路径）写入；用户已删掉的漫画文件不可恢复（旧版删书连目录删了）。没有侧车的存量书目录（本功能之前删书残留）无法重新入库。
