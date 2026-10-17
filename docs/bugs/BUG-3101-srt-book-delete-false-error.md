## BUG-3101 · 有声书书架条目删除总提示删除书籍失败
- **报告**：2026-10-09（用户：删除小说总是提示「删除书籍失败」，不管有没有勾选「从所有设备删除」）
- **真实性**：✅ 真 bug。书架上配对了 EPUB 的字幕书卡（`srt_<uid>`，有声书角标）走 `_confirmDeleteSrtBook`（`fushi/lib/src/pages/implementations/reader_history/books.part.dart`）：先调 `ReaderFushiSource.deleteBook(bookKey)`，其 `db.deleteEpubBook`（`packages/fushi_core/lib/src/database/database_content_misc.part.dart:1224`）在同一事务里按 bookKey 级联删掉 srt_books 行；随后又调 `SrtBookRepository(db).delete(book.uid)`，行已不在、回报 `deleted == 0`，页面据此弹「删除书籍失败」。书其实已删掉，与删除范围（`DeleteScope`）无关，所以「勾不勾从所有设备删除都失败」。批量删除同一分支把这本计成 0 本（「已删除 0 本」）。
- **[x] ① 已修复** — 新增 `ReaderFushiSource.deleteSrtShelfBook`（`fushi/lib/src/media/sources/reader_fushi_source.dart`）：按身份只走一条删除路径——`bookKey` 非空走 `deleteBook` 整本删（墓碑 `book`），纯字幕书走 `SrtBookRepository.delete`（墓碑 `srtbook`），结果与失败原因如实回传；单本删除与批量删除的 SRT 分支都改调它（提交见 PR `pr/reader-shelf-ui`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/sources/reader_fushi_source_test.dart`（`BUG-3101 配对字幕书卡删除如实回报成功` × 两种 scope + 纯字幕书删除 / 重复删除回报失败）；`fushi/test/pages/reader_history_batch_delete_count_guard_test.dart` 改为钉「SRT 分支经 `deleteSrtShelfBook`、不得在 deleteBook 后再按 uid 删一次」。
- **备注**：纯 EPUB 卡（`_confirmDeleteEpub`）路径本就只调一次 `deleteBook`，不受影响。
