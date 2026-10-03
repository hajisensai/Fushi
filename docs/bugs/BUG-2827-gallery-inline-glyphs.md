## BUG-2827 · 插图册把外字与章节号小图当插图展示
- **报告**：2026-10-01（用户：书架 › 插图册截图，ダンまち一卷里章节号「ひとつ」等小图、质量差的 EPUB 用图片顶替的汉字「鍵挽…」一张张占满网格，「已解锁 55 / 65」也把它们算进总数）
- **真实性**：✅ 真 bug。`EpubBook.images`（`packages/fushi_engine/lib/epub/epub_book.dart:352`）收正文里每一个 `<img>`，不看尺寸；插图册 `ReaderGalleryPage._images`（`fushi/lib/src/reader/reader_gallery_page.dart`）原样展示。而阅读器正文早就把宽、高都 ≤ 256 的图当行内小图排进文字流（`fushi/lib/src/reader/reader_pagination_scripts.dart:2384` 的 `block-img` 判据）——同一张图正文当字、插图册当插图，两处判据不一致。
- **[x] ① 已修复** — 插图册开页本来就在 isolate 里读每张图文件头（BUG-2589 的横版两列），探针改为返回像素尺寸（`probeIllustrationSizes`），新增与正文同一把尺的 `isInlineSizedImage`（`kInlineImageMaxSide = 256`）；`_images` 剔除行内小图，OPF 封面豁免、探不到尺寸的照常展示。三个入口（阅读器内、兄弟卷、书架端）与计数同时生效；尺寸到达时查看器按图本身重映射下标。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_gallery_page_test.dart`「外字 / 章节号小图（宽高都 ≤ 256）不进插图册，封面再小也保留」（真 PNG + 真 isolate 探测）；`fushi/test/reader/illustration_aspect_probe_test.dart` 判据边界 + 「阈值与分页脚本 block-img 判据同一个数」守卫。
- **备注**：本机 1837 张书内图片实测：真插图几乎都 > 600px，≤ 256 的只有作者小照、出版社 logo 与一张 180×256 的封面（封面已豁免）。阈值目前固定，不开设置项。
