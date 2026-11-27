## BUG-5580 · spine 直接引用位图的漫画 EPUB 打不开、导不进（no readable chapters）
- **报告**：2026-11-27（应用内反馈 8NPHawEd0I：开发者 Windows / 3.4.0-debug.32862，「无法打开 マホウショウジョニーマルイチイチ … .epub，请改从书架导入」+「导入失败: FormatException: EPUB spine contains no readable chapters」）
- **真实性**：✅ 真 bug，用原文件复现。这本是集英社的 Open Manga Format 电子版：`container.xml` 里的 `OPS/standard.opf`，spine 的 `<itemref>` 逐页直接指向 manifest 里的 `image/jpeg`，整本没有 XHTML 页。根因在 `packages/fushi_engine/lib/epub/epub_parser.dart` 的 `_parseSpine`（修前 `:789-792`）：它只收 HTML 类 spine 项，漫画口径下额外收 `image/svg+xml`（BUG-3845），位图项一律 `continue`。结果整本 0 章，抛 `EPUB spine contains no readable chapters`。漫画探测（`MangaArchiveImporter._imageEpubRejection`）判「不是漫画」，转去走书籍路径，书籍路径同样 0 章，于是外部打开和导入都失败。
- **[x] ① 已修复** — 漫画口径开关从 `includeSvgSpineDocuments` 改名为 `includeImageSpineItems`，开着时也收位图 spine 项（`image/*`，SVG 除外）。位图页不查盘存在：漫画导入先只解 container / OPF / spine 文档，页图延后补解，此刻页图还不在盘上；真缺图由拷页时报 `page not found`。`EpubChapter.isRasterImage` 标出这种章节，`EpubBook.isImageOnlyChapter` 对它直接返回 true，`chapterImageSrcs` 返回它自己的文件名，不把 JPEG 当 HTML 扫描。书籍 / 阅读器口径（默认 false）不变，存量书 chaptersJson 的章号不移位。
- **[x] ② 已加自动化测试** — `fushi/test/epub/epub_svg_cover_and_manga_test.dart` 新增两条：
  - 「spine 直接引用位图」：带 nav、文件名带空格、jpg 与 png 混排、spine 序与文件名序相反。断言 `looksLikeImageArchive` 为 true 且无否决日志；`stageImageEpub` 走真实的「延后补解 + 挪页」整卷导入，页序跟 spine 一致，字节与原图相同。
  - 「书籍口径默认不收位图 spine 项」。
- **备注**：这类 OMF 包在 `container.xml` 里还声明了第二个 rootfile（`advanced.opf`，固定版式脚本阅读器用），我们只读第一个 rootfile，`standard.opf` 正是纯图那份。
