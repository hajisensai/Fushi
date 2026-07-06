## BUG-566 · iOS EPUB 导入同名残留目录失败
- **报告**：2026-07-06（用户：）
- **真实性**：✅ 真 bug。`EpubImporter._persistParsed` 在解析完成后直接把 `.tmp-*` 解压目录 `renameSync` 到 `hoshi_books/<bookKey>`；当目标目录是数据库未引用的上次残留非空目录时，iOS/macOS `rename` 返回 `Directory not empty (errno=66)`，导入流程中断。根因：`hibiki/lib/src/epub/epub_importer.dart:161`。
- **[x] ① 已修复** — `8eec8fcb9`：导入前检查目标路径，只删除没有任何 `epub_books.extract_dir` 引用的 orphan 文件/目录/链接，再执行临时目录改名；仍被数据库引用的目录保持不动。
- **[x] ② 已加自动化测试** — `hibiki/test/epub/epub_importer_test.dart` 覆盖同名非空 orphan 目录存在时，真实 `EpubImporter.importFromPath` 仍能导入并替换残留目录。
- **备注**：已跑 `flutter test --no-test-assets test/epub/epub_importer_test.dart test/epub/book_title_conflict_test.dart`；真机原始导入路径待设备可用后补测。
