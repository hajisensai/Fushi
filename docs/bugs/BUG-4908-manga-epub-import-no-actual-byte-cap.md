## BUG-4908 · 纯图 EPUB 漫画导入不按实际解出字节封顶、探测白解整本
- **报告**：2026-11-20（路线图 #3722 c26 / manga-23，复核结论「部分成立」）
- **真实性**：✅ 真问题：
  - 封顶：`MangaArchiveImporter.importArchive` 的 EPUB 分支（基线 `packages/fushi_engine/lib/media/manga/manga_archive_importer.dart:589`）走 `EpubParser.parseSyncFromPath` → `native_zip.extractZipEntryToFile`，只有中央目录声明大小的预检；`writeZipEntryStreaming` 的大小核对（基线 `packages/fushi_engine/lib/utils/archive/native_zip.dart:131` `_checkEntrySize`）在整条写完之后才做——声明 1000 字节、实际 inflate 出几 GB 的条目会先把磁盘写满再报错；诚实的超大条目也不受单条上限约束。ZIP 分支（`_ZipEntryStreamer`）早已按实际字节封顶，两条分支口径不一。
  - 重复解压 / 多次落盘：每次导入前都先探测（`looksLikeImageArchive` → `_looksLikeImageEpub`，基线 `:975-984`）把整本解进系统临时目录，导入再解一遍；导入里页图又从解压树读进内存、再写进暂存目录（每页两次写盘 + 一次改名）。
- **[x] ① 已修复** — `native_zip` 加可选的 `ZipExtractionCap`（声明超限开解前拒；实际字节越过声明大小当场按损坏中止；越过单条 / 总量上限抛 `ZipExtractionLimitException`），`parseSyncFromPath` 透传；漫画 EPUB 分支用与 ZIP 分支同一份 `MangaArchiveExtractionLimits` 预算，超限报 `Manga archive is too large`。小说导入与同步包不传，行为不变。探测改为不落盘页图条目（判据只看 spine 文档），导入时页图从本次独占的解压树直接 rename 进暂存目录（同图多页引用第二次起从新位置拷）。
- **[x] ② 已增加自动化测试** — `fushi/test/media/manga/manga_import_fastpath_test.dart` 的 manga-23 组：页图 CRC 坏的 EPUB 探测仍判成漫画（旧探测解页图而误判）；诚实的超单条上限页被拒（旧路径照常导入）；声明 1000 字节、实际 64 MiB 的页在越过声明处中止（旧路径写满 64 MiB 后才报「wrote … header says 1000」）；同图多页引用挪走后两页齐全。
- **备注**：`_looksLikeImageEpub` 仍用系统临时目录放 spine 文档（现在只有几 KB 的 XML / XHTML，finally 里删除），c07 提到的「探测残留在系统临时目录」未收，已登记到路线图 c39（`pr/manga-import-dialog-async`）随定性改异步一并收。
