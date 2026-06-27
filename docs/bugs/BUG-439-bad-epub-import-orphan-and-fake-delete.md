## BUG-439 · 坏EPUB导入留孤儿壳行+删除假成功
- **报告**：2026-06-27（用户：TODO-887）
- **真实性**：✅ 真 bug（纯代码可复现，双缺陷叠加）。根因 file:line：
  1. 坏书能入库 → `hibiki/lib/src/media/audiobook/book_import_dialog.dart:699`：`_importSubtitleBook` 的 EPUB 生成/导入 `catch` 把 `FormatException` 整个吞掉（只 log），`bookKey` 保持空串初值，`:755` 仍无条件 `repo.save(book)` 写一条没有 `EpubBooks` 行、磁盘无解压目录的 `SrtBook` 孤儿壳行。
  2. 打开「找不到书籍」→ 卡所指内容不存在，EPUB 行经 `reader_hibiki_page.dart` `_locateBookOnDisk` 返回 exists:false → book_file_not_found 并 pop。
  3. 假删除（核心）→ `hibiki/lib/src/media/sources/reader_hibiki_source.dart:408`：`deleteBook` 在 `getEpubBook(bookKey)` 返回 null（行不存在/key 不匹配/重复删）时仍删 0 行并无条件 `return true` 谎报成功；批量删 `hibiki/lib/src/pages/implementations/reader_history/books.part.dart:267` SRT 分支对 `repo.delete(uid)` 实删结果零校验，直接 `deleted++`，末尾无条件弹「已删除 N 本」。
- **[x] ① 已修复** —
  - `book_import_dialog.dart:699-708`：坏 EPUB（FormatException 等）`catch` 末尾 `rethrow`，与上面 `DuplicateImportCancelledException` 同理冒泡到顶层中止整次导入，不再吞异常后落孤儿壳行（EPUB 是字幕书正文载体，载体失败这本书不可读）。提交 `b1274d902`。
  - `reader_hibiki_source.dart`：`deleteBook` 删前早退守卫 `if (bookRow == null && srt == null) return false`（孤儿壳行 bookKey==''、key 不匹配、重复删都不再谎报、不跑磁盘清理/VACUUM）；`deleteEpubBook` 返回值入 `deletedRows`，末尾 `return deletedRows > 0 || srt != null` 如实回报。提交 `b1274d902`。
  - `packages/hibiki_core/.../database.dart` `deleteSrtBookByUid` 改返 `Future<int>`（srt_books 实删行数）；`packages/hibiki_audio/.../srt_book_repository.dart` `delete` 改返 `Future<int>` 透传；`books.part.dart` 批量删 SRT 分支改 `final int removed = await repo.delete(uid); if (removed > 0) deleted++;`，「已删除 N 本」只计真删成功。提交 `b1274d902`。
  - 启动孤儿清理：**未做**。`bookKey==''` 也是纯字幕/歌词书（cues 为空、从未生成 EPUB）的合法状态，无可靠判据把孤儿壳行与合法字幕书区分；存量清理会误删合法字幕书。根因修复（① rethrow）已阻断新孤儿产生，存量留待有可靠判据时再清。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/audiobook/book_import_dialog_test.dart`：源码守卫断言 `_importSubtitleBook` 坏 EPUB catch 含 `rethrow`（red→green：撤 rethrow 转红实测）。
  - `hibiki/test/media/sources/reader_hibiki_source_test.dart`：`deleteBook` 行存在→true 且删行；bookKey=='' / 缺失 key→false（red→green：撤早退/honest-return 转红实测）。
  - `hibiki/test/database/srt_books_test.dart`：`deleteSrtBookByUid` 删到行返 1、未删到返 0。
  - `hibiki/test/pages/reader_history_batch_delete_count_guard_test.dart`：源码守卫断言批量删 SRT 分支按实删数计数（`if (removed > 0) deleted++`）（red→green：撤计数门控转红实测）。
- **备注**：与 TODO-739（互联下载侧 container.xml 大小写 epub_parser.dart）不同源，独立。
