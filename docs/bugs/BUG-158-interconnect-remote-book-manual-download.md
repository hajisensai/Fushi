## BUG-158 · Hibiki互联无法下载对端独有书籍
- **报告**：2026-06-09（用户：无法下载对端书籍；希望类似 Hibiki 互联的点击下载，而不是自动同步拉取）。
- **真实性**：是 bug。旧的“本地 vs 远端”对比路径主要按云端/WebDAV 书籍文件夹构造远端独有书籍；Hibiki 互联后端的实时书库列表没有合入对比结果，也没有保存可用于 `getRemoteBook()` 的 live title，所以互联对端独有书籍缺少可点击下载入口。根因落点：`hibiki/lib/src/sync/sync_compare_dialog.dart:168`、`hibiki/lib/src/sync/sync_compare_dialog.dart:280`、`hibiki/lib/src/sync/sync_compare_dialog.dart:727`。
- **[x] ① 已修复** - 提交：`a80acc1a6`。对比弹窗在 `HibikiClientSyncBackend` 下额外读取 `/api/library/books`，把 live remote-only 书籍合入条目；远端独有书籍默认不参与 Apply 和自动同步，只显示“下载”按钮。点击下载时，互联路径调用 `getRemoteBook(title)` 后走 `EpubImporter.importFromPath()`，云端路径继续走 `importRemoteBookFolder()`。
- **[x] ② 已加自动化测试** - `hibiki/test/sync/sync_compare_live_book_test.dart` 覆盖互联 live remote-only 书籍可作为可下载条目出现；`hibiki/test/sync/sync_compare_download_test.dart` 覆盖远端独有书籍以点击下载方式导入且不计入 Apply。
- **备注**：这条和 BUG-041 的区别是互联 live 书库入口；本次同时把远端独有书籍从自动 Apply/后台同步里移出，避免重新引入“自动拉远端内容”。
