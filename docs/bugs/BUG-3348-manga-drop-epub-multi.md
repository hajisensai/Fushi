## BUG-3348 · 漫画库拖入 EPUB 先走书籍导入、多选拖入只导一本
- **报告**：2026-10-14（用户：「我在漫画页面，拖动 epub 到漫画页面里面，会先弹出 epub 导入流程，然后告诉我可能是漫画。但是我明明已经在漫画里面了，应该优先告诉是漫画。而且我多选拖动的时候只会导出一本」）
- **真实性**：✅ 真 bug，两个独立根因：
  1. 拖放分类层刻意不对 `.epub` 开包（`fushi/lib/src/media/drag_drop/drop_classification.dart` 的 `kDragMangaExtensions` 注释：「书籍框会再判一次，最终照样导成漫画」），漫画库表面又把非漫画载体委托给书架规则（`drop_decision.dart` `DropSurface.manga` 分支）→ 图片型 EPUB 得到 `importNewBook`，先进 `BookImportDialog`，再被其 `_handoffIfManga` 提示「这看起来是漫画」。这个理由在书架成立，在漫画库不成立——落点已经说明了意图。`.pdf` 同理（漫画框本就能逐页栅格化成漫画）。
  2. `fushi/lib/src/pages/implementations/reader_history/books.part.dart` `_handleShelfDrop` 对每个意图只取 `files.books.first` / `files.mangas.first`，其余文件静默丢掉；`MangaImportDialog._handleDialogDrop` 同样只收第一个。
- **[x] ① 已修复** — `2af56ac05c`：`classifyDroppedFiles` / `probeDroppedImageArchives` 新增 `preferManga`（漫画库开启：`.epub` 进同一 `isImageArchive` 判据、`.pdf` 直接归漫画；文字 EPUB 仍归书，书架默认不变）；新增 `importMangaBatchPaths`（`importMangaBatchFolder` 委托给它，目录卷按自身载体处理、重复路径去重）；`MangaImportDialog.initialPaths` + 对话框拖入多选 → 逐卷批量模式；书架多本书逐本弹导入框（某本取消即停止）。
- **[x] ② 已加自动化测试** — `fushi/test/media/drag_drop/manga_drop_test.dart`（漫画库落点分组）、`fushi/test/media/drag_drop/drop_failure_visibility_test.dart`（preferManga 开包范围）、`fushi/test/media/manga/manga_folder_batch_test.dart`（多选路径逐卷导入）、`fushi/test/media/manga/manga_import_dialog_multi_drop_test.dart`（多卷预填进批量模式）。
- **备注**：漫画库里同时拖入「图片型漫画 + 文字书」时只处理漫画那组（决策层单意图，与改动前同形）。真机拖放未验。
