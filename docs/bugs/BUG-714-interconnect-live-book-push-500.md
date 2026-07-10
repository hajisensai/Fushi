## BUG-714 · 互联 live 书籍推送全部 HTTP 500(host 未接线 importBookFromFile)
- **报告**：2026-07-10（用户：截图 `SyncRunReport.errors`）
- **现象**：自动/立即同步时 `SyncRunReport.errors` 报
  `live push book "<书名>": SyncBackendError: PUT /api/library/books/<书名> failed: HTTP 500`。
  截图里是两本中文书（`一桩事先张扬的凶杀案` / `朝花夕拾`），但与书名/CJK 无关——凡有
  本端独有书要推给 host，**每一本都 500**，截图那次恰好只有两本待推。
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/models/app_model.dart:419`
  （`libraryServiceFactory` 构造 `AppModelLibraryHostService` 时**漏传**
  `importBookFromFile`）。
  - 调用链：client `sync_orchestrator.dart:553 putRemoteBook` → host
    `hibiki_sync_server.dart` books `PUT` 分支写 tmp `.epub` 后 `svc.importBook(tmp)`
    → `app_model_library_host_service.dart:298 importBook`：`_importBookFromFile` 为
    null 时抛 `UnsupportedError('importBook requires importBookFromFile callback ...')`
    → 服务端 `catch (e) { return shelf.Response(500, body: 'Import failed: $e'); }`
    → client `webdav_ops.dart:254 checkStatus` 把 `>=400` 统一成
    `SyncBackendError('$context failed: HTTP $statusCode')`（**丢弃了服务端响应体**，
    所以用户只看到裸 `HTTP 500`，看不到真正的 `Import failed: UnsupportedError`）。
  - 为何单测没挡住：`hibiki_library_host_service_*` / `hibiki_sync_server_books_test`
    都自己注入了 `importBookFromFile` 假回调，唯独生产工厂忘了注入，测试照样绿。
- **[x] ① 已修复** — `app_model.dart:419` 工厂接线
  `importBookFromFile: (File epubFile) => EpubImporter.importFromPath(db: database,
  filePath: epubFile.path, fileName: path.basename(epubFile.path))`
  （文档约定的生产实现），并新增 `import '.../epub/epub_importer.dart'`。提交见分支
  `worktree-fix-live-book-push-500`。
- **[x] ② 已加自动化测试** — 源码级接线守卫
  `hibiki/test/sync/host_book_import_wiring_guard_test.dart`：断言生产工厂里
  `importBookFromFile:` 存在且接到真实原语 `EpubImporter.importFromPath(`。已验证
  该守卫在剥掉接线后失败、接回后通过（防静默回退）。
- **备注**：
  - **相关未修（本 bug 范围外，另记）**：同一工厂也漏传 `cleanupBookOnDisk`，故 host 的
    `DELETE /api/library/books/<title>` 只删 DB 行、不清 AudiobookStorage/SrtBook 等
    磁盘资源（潜在孤儿文件，非本次 500 症状）。
  - **可诊断性欠账**：`checkStatus` 只透传状态码、丢弃服务端 `Import failed: <e>` 响应体，
    未来 import 失败仍只显示裸 `HTTP 500`。建议 `putRemoteBook` 读取并附上响应体片段
    （另开条目，非本 bug 根因）。
