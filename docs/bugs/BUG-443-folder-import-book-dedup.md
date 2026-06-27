## BUG-443 · 文件夹导入书籍缺去重

- **报告**：2026-06-28（用户：）
- **真实性**：✅ 真 bug。文件夹扫描导入书籍（书架页头「管理来源」→ 添加本地文件夹 → 扫描）缺少去重，已手动导入过的同名书在文件夹扫描后被再次导入，静默复制成 `X (2)`。
  根因：`hibiki/lib/src/media/source/media_source_scanner.dart:189` `_importBooks` 对每个 EPUB 无条件 `EpubImporter.importFromPath(...)`，既不传 `onDuplicateTitle` 也不预建 existing 集合查重；`EpubImporter` 无回调时 `resolveBookTitleConflict`（`hibiki/lib/src/epub/book_title_conflict.dart:30-40`）走「自动加后缀」分支把重复当成 `X (2)` 静默入库。
  强对照：同文件视频路径 `_importVideos`（`media_source_scanner.dart:218-220`）开头预建 `existingKeys` 并用 `uniqueVideoBookUid` 做同名去重；`_importBooks` 缺这一步——这就是丢去重的那一跳。
- **[x] ① 已修复** — 提交 `7d53e6a24`。复用既有标题身份 key（`sanitizeTtuFilename`）：
  - `book_title_conflict.dart`：`resolveBookTitleConflict` 加 `bool skipIfExists = false`，命中已存在 key 时抛 `DuplicateImportCancelledException`（不再静默加后缀），不新造判据。
  - `epub_importer.dart`：`importFromPath` / `_persistParsed` 透传 `bool skipIfExists = false`（默认 false，单文件手动导入弹窗去重契约零改动）。
  - `media_source_scanner.dart`：`_importBooks` 传 `skipIfExists: true`，捕获 `DuplicateImportCancelledException` 即 `continue` 静默跳过（对齐 `_importVideos` 的 silent dedup 语义，扫描批量后台流程不弹窗）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/source/media_source_scanner_test.dart`：
  - 「已含某标题书的 DB + 扫描含同名 EPUB 的文件夹 → 该书只有一条、不产生 X (2)」
  - 「新书仍正常导入」「同批两个同名只入一条」
  - 源码守卫：`_importBooks` 必含 `skipIfExists` 去重调用，防回归删 dedup。
- **备注**：EpubBooks 表无源路径列（`epubPath` 存 basename），故 schema 层无法表达「同源路径」；落地判据选标题身份 key（与单文件手动导入弹窗去重同一 spec），最小可落地。
