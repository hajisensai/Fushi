## BUG-3774 · epub-import-title-shows-filename
- **报告**：2026-10-25（用户：导入 EPUB 显示的是文件名，而不是 EPUB 元数据里的书名）
- **真实性**：✅ 真 bug（对话框层）。导入对话框选中 EPUB 的三处回填点（initState 预填 `fushi/lib/src/media/audiobook/book_import_dialog.dart:198`、拖入 `:355`、选择器 `:756`）只把文件名去扩展名填进标题框，从不读 OPF。引擎入库本身正确：`EpubParser.parseFromExtracted` 取 `dc:title`，缺了才退文件名（`packages/fushi_engine/lib/epub/epub_parser.dart:180`），`EpubImporter._persistParsed` 用它落库，且 EPUB 路径不使用标题框的值。所以用户在导入框里看到的是文件名，入库的却是 OPF 书名，两边不一致。核对开发版库（`D:\hibiki-dev-data`）近期导入的几本：入库书名都等于各自 OPF 的 `dc:title`，印证引擎层没问题。
- **[x] ① 已修复** — 新增 `_fillTitleFromEpubMetadata`（`book_import_dialog.dart:642`）：三处选中 EPUB 后在后台 isolate 跑 `EpubParser.readTitleSync`，经 `_autoFillTitle` 以同一 `ImportTitleSource.epub` 来源换成 OPF 书名；用户手打过的标题不覆盖，读取期间换了文件不回写，OPF 没写书名时保留文件名。读取放在顶层函数 `readEpubTitleInBackground`（`:1422`）：写在 State 方法里的 `Isolate.run` 闭包会和同方法里的 `setState` 闭包共享捕获上下文、把 State 带过 isolate 边界而发送失败（初版这样写，新测试实测红）。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/import/book_import_dialog_epub_metadata_title_test.dart`：真对话框 + 真 EPUB（文件名与 `dc:title` 不同）断言标题框显示 OPF 书名、真 `EpubImporter` 入库书名与之一致；OPF 无书名时保留文件名。
- **备注**：EPUB 路径仍然忽略用户在标题框里手改的书名（入库永远取 OPF / 文件名），这是另一处既有不一致，本次未改。
