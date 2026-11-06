## BUG-3646 · 纯图 EPUB 转漫画重页（KCC Panel View 每页出 5 份）
- **报告**：2026-10-21（用户：「Death Note, Vol. 1_ Boredom 这个重页是为啥，在fushi漫画里面」）
- **真实性**：✅ 真 bug。KCC 生成的 Kindle 漫画 EPUB 每个 spine 页 1 个可见 `<img>` + 4 个 `display:none` 的 Panel View 放大区（`.PV-P`），全指同一文件；197 个 spine 页导入成 985 页（788 张相邻字节相同）。根因 `packages/fushi_engine/lib/epub/epub_book.dart` 的 `chapterImageSrcs` 原样返回原生扫描的每个引用、不按文件去重（同文件的 `images` getter 却按 `normalizeEpubImageKey` 去重，判据两套），`packages/fushi_engine/lib/media/manga/manga_archive_importer.dart` 的 `_copyEpubPages` 逐引用写页。同一缺陷还波及：日式固定版式里 `<img>` + SVG `<image>` 指同一图的页（扫描向量里 427 章即此形态）、阅读器插图合并（`webview.part.dart` `_mergedChapterImagesHtml` 重复插图）、下一章图片预热重复请求。
- **[x] ① 已修复** — `chapterImageSrcs` 改为按 `normalizeEpubImageKey(resolveImageHref(...))` 去重、保留首次出现顺序（`data:` / 绝对 URL 按原串）；三个消费方一并受益。
- **[x] ② 已加自动化测试** — `fushi/test/epub/epub_image_only_chapter_test.dart`（KCC Panel View 同文件多写法合一 + 不同文件保序保留）、`fushi/test/media/manga/manga_archive_importer_test.dart`（KCC 结构 EPUB 端到端只出 2 页）；变异实测：换回旧实现 3 条全红。`packages/fushi_engine/test/epub/chapter_scan_vectors_test.dart` 三个扫描摘要有意重算（新旧转储逐行比对 20107 行，仅 427 行 `refs=` 栏变化且全是删重复引用）。
- **备注**：已导入的书不会自动修复：库里只有这一本中招（扫描全部漫画目录确认），删掉后用原 EPUB 重新导入即可。
