## BUG-5033 · 互联对端删书，host 上的有声书副本和自定义封面不清
- **报告**：2026-11-20（路线图 #3722 c37 审查遗留，与 BUG-4906 同根因）
- **真实性**：✅ 真 bug（读代码坐实）。`packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:420` 在删行前调注入的 `cleanupBookOnDisk`，但 app 的接线 `fushi/lib/src/models/app_model.dart:1262`（`libraryServiceFactory: () => LocalLibraryHostService(...)`）从来没传这个参数，回调是 null。host 服务自己只删行、墓碑和解压目录；有声书 / 配对字幕书的持久目录（`<docs>/audiobooks/<hash>/`）与 override 书名 / 封面文件只有 app 知道位置，对端删书后一直留在 host 上，同名书重新导入（同一个 bookKey）还会带出旧封面。
- **[x] ① 已修复** — `ReaderFushiSource.cleanupBookFilesForHostDelete`（删行前：删有声书与配对字幕书持久目录，失败只记日志；再独立清 override 书名与封面）；`AppModel` 的 host 服务接到 `cleanupBookOnDisk`。`deleteBook` 里的封面清理抽成同一个 `_clearBookOverridesLogged`。
- **[x] ② 已增加自动化测试** — `fushi/test/media/sources/reader_fushi_delete_cleanup_test.dart`「#3722 c37 审查遗留」组：真实内存库 + 真实 `LocalLibraryHostService.deleteBook`，删后两份持久目录与封面都不在、同名重导无封面；注入持久目录删除失败仍删行、清封面；静态断言 `AppModel` 接了这个回调。
- **审查补修**（#3722 遗留组 L4 独立审查，2026-11-20）：回调原先在删行**之前**跑，删有声书持久目录 / 清封面之后若 `deleteEpubBook` 失败，书还在、副本和封面已经没了（与 `ReaderFushiSource.deleteBook`「先删行、再清尾活」的顺序相反）。改为 host 服务删行前取配对字幕书 uid、删行成功（`deleted > 0`）后才调 `cleanupBookOnDisk(row, pairedSrtUid)`；回调挪到删行之后，`item_images` 附加图文件也就能在这里当场回收（`ItemScrapeStore.reclaimUnreferencedFiles`）。测试：同组「删行失败：书还在……」（触发器注入删行失败，修复前持久目录与封面被先删即红）、「对端删书后回收……条目附加图文件」。
- **备注**：真机未验证。
