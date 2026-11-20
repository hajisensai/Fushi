## BUG-4910 · 互联对端删书，host 上的有声书副本和自定义封面不清
- **报告**：2026-11-20（路线图 #3722 c37 审查遗留，与 BUG-4906 同根因）
- **真实性**：✅ 真 bug（读代码坐实）。`packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:420` 在删行前调注入的 `cleanupBookOnDisk`，但 app 的接线 `fushi/lib/src/models/app_model.dart:1262`（`libraryServiceFactory: () => LocalLibraryHostService(...)`）从来没传这个参数，回调是 null。host 服务自己只删行、墓碑和解压目录；有声书 / 配对字幕书的持久目录（`<docs>/audiobooks/<hash>/`）与 override 书名 / 封面文件只有 app 知道位置，对端删书后一直留在 host 上，同名书重新导入（同一个 bookKey）还会带出旧封面。
- **[x] ① 已修复** — `ReaderFushiSource.cleanupBookFilesForHostDelete`（删行前：删有声书与配对字幕书持久目录，失败只记日志；再独立清 override 书名与封面）；`AppModel` 的 host 服务接到 `cleanupBookOnDisk`。`deleteBook` 里的封面清理抽成同一个 `_clearBookOverridesLogged`。
- **[x] ② 已增加自动化测试** — `fushi/test/media/sources/reader_fushi_delete_cleanup_test.dart`「#3722 c37 审查遗留」组：真实内存库 + 真实 `LocalLibraryHostService.deleteBook`，删后两份持久目录与封面都不在、同名重导无封面；注入持久目录删除失败仍删行、清封面；静态断言 `AppModel` 接了这个回调。
- **备注**：`item_images` 附加图文件在 host 删书后不回收（行随事务删，文件要等下一次任一处 `reclaimUnreferencedFiles`）——回调在删行之前跑，回收只能放删行之后，需要给 host 服务加删后钩子，未做。真机未验证。
