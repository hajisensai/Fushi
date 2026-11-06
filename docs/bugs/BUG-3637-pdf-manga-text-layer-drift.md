## BUG-3637 · pdf-manga-text-layer-drift
- **报告**：2026-10-20（用户：「这个怎么标准的pdf，字的位置还会偏移」——带文字层的竖排小说 PDF 进漫画库后，OCR 逐字框整体错位，越往列尾越偏）
- **真实性**：✅ 真 bug。两层原因：
  1. PDF 进漫画库只栅格化页图、丢掉 PDF 自带文字层：`fushi/lib/src/media/manga/book_format_rebuild.dart` `_rasterizePdfPages`（只写 PNG）→ `MangaImporter.payloadFromImageFolder` 生成空块的 `manga.json`，字框全靠事后 OCR。
  2. OCR 引擎只给行框时，覆盖层按字数均分字格：`fushi/lib/src/media/manga/manga_overlay_html.dart` `_mangaGeometryTextRegions`（`lineRect.height / characters.length`）。竖排里「、」「。」「……」「──」占的高度与普通字不同，误差沿列累积。
- **[x] ① 已修复** — PDF 文字层直接写成文字块（真实逐字坐标）：`packages/fushi_engine/lib/media/manga/manga_pdf_text_layer.dart`（逐字框 → 切行 → 段落块，注音细列单独成块）+ `fushi/lib/src/media/manga/pdf_text_layer_backfill.dart`（PDFium 取字，转换完成时与开书时补老书）。块带 `pdf_text_layer`、卷带 `pdf_text_layer_version`；`writeMangaJsonAtomically`（及服务端 `_writeMangaJson`）覆写前把磁盘上的文字层并回，任何 OCR / 向导 / 大模型重写都冲不掉；`mangaVolumeOcrSettled` 不把文字层块算识别结果（扫描页照样自动 OCR，整本完整文字层则不跑 OCR）；大模型识别跳过文字层块。没有文字层的页仍走 OCR，均分字格的偏移（原因 2）本次未改。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_pdf_text_layer_test.dart`（竖排逐字命中区不漂移、注音单独成块、字表对齐、合并规则、是否需要 OCR、JSON 往返、写盘保留文字层）+ `fushi/test/media/manga/book_format_rebuild_test.dart`（PDF 转漫画端到端写出文字层块）。
- **备注**：未在真实 PDF 上实测（本机没有该书的文件、也没有竖排 PDF 样本）；PDFium 竖排逐字框的几何是按 pdfrx 自带格式化器的 vrtl 处理推定的。混排 PDF（部分扫描页）仍会整卷 OCR，文字页的 OCR 结果在写回时被丢弃——按页子集跑 OCR 需要五个引擎都支持页过滤，留待后续。
