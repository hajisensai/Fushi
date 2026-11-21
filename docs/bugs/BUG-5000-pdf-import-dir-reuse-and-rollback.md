## BUG-5000 · PDF 导入书目录存在即复用、失败无条件删除
- **报告**：2026-11-20（路线图 #3722 第 3 节 c07 遗留，并入 c26）
- **真实性**：✅ 真 bug：`fushi/lib/src/pdf/pdf_importer.dart`（基线 7745effa2e）在锁外定书名（`:73-79`），随后 `EpubStorage.bookDirectory(bookKey)`（`:81`，目录存在即复用）直接往 `<bookKey>/` 里拷 PDF / 写封面，失败回滚无条件整个删掉该目录（`:150-152`）。后果：① 两份同名 PDF 并发导入（suffix 策略）定出同一个书名、写进同一个目录，后插行的撞主键失败，回滚把先成功那本的书目录删掉（书行还在、文件没了）；② 撞上崩溃残留 / 删书清理失败留下的同名无主目录时，导入失败会把「找回书库」本可恢复的孤儿一起删掉。EPUB 与漫画导入已在 BUG-4840 / BUG-4837 改成暂存 + 落位锁，PDF 是剩下的那条。
- **[x] ① 已修复** — 拆出 `PdfImporter.persistRendered`：`document.pdf` 与封面先备进 `EpubImporter.createStagingDir` 建的书库根 `.tmp-*`，经 `EpubImporter.placeUnderResolvedTitle` 在落位锁内「重取快照 → `EpubStorage.moveDirIntoPlace` → 插行」；回滚只删本次的暂存目录与已落位而行没插成的目录。
- **[x] ② 已增加自动化测试** — `fushi/test/pdf/pdf_import_dir_ownership_test.dart`：并发导入同名 PDF 两本都入库、各自的 `document.pdf` 不串；源文件缺失导致失败时同名无主目录（含 `keep.txt`）原样保留、暂存目录被回收。
- **备注**：PDF 栅格化要 pdfium，单测从 `persistRendered`（页数 + 封面字节已在手）切入。
