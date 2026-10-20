## BUG-3641 · manga-detected-epub-no-force-book-import
- **报告**：2026-10-21（用户：书籍导入框弹「这看起来是漫画」后「没办法强制导入啊」，附截图；追加「类似的都修复」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/audiobook/book_import_dialog.dart` 的 `_handoffIfManga` 在载体被判成漫画后只给「取消 / 按漫画导入」，取消也返回 `true`（丢弃该路径），且选文件 / 拖入 / `_doImport` 兜底三道闸门都走它——漫画判据误判（插图小说、绘本、图文书的图片型 EPUB）时这本书根本进不了书架。同类：`fushi/lib/src/platform/desktop/ctl/ctl_library_import.dart` 的 `_importBookLike` 在用户显式 `--kind book` 时也把图片型 EPUB 静默改成漫画导入。
- **[x] ① 已修复** — 新判据 `canImportMangaCarrierAsBook`（`import_carrier.dart`，只放行图片型 `.epub`：书籍管线吃得下；`.cbz/.zip/.mokuro`/页图目录书籍侧没有 importer，不给出口）。书籍框确认框加第三个按钮「仍按书籍导入」，选中后路径记进 `_forcedBookPath`，`_classifyCarrier` 对它返回 `epub`，后续兜底闸门与 `_importEpubOnly` 分派一致放行、不再二次弹框；CLI 显式 `--kind book` 同判据按书导。未指定种类（含外部双击打开）仍按自动判定转漫画。
- **[x] ② 已加自动化测试** — `fushi/test/media/import/book_import_dialog_real_carrier_memo_test.dart`（拖入→仍按书→点导入不二次弹框且真 `EpubImporter` 落库；去掉覆盖的变异实测在 :359 变红）、`fushi/test/media/import/external_book_test.dart`（`--kind book` 图片型 EPUB 落成书；变异实测变红）、`fushi/test/media/import/import_carrier_test.dart`（判据纯函数）。
- **备注**：漫画框拒收文字 EPUB、书架拖图片型 `.zip/.cbz` 直接进漫画框这两处不加强制出口——目标管线吃不下该载体，给了只会换来一次导入失败。
