## BUG-4891 · 本机 Manga CTC 把正文短列当注音删掉、把疏排竖排读成横排（漫画 OCR 丢列与串列乱码）
- **报告**：2026-11-17（用户：「ocr的效果太差了」，附《世界で一番おっぱいが好き！１》第 9 页查词弹窗截图：气泡「は〜〜〜〜 / 癒やされる〜〜〜」只读出后一列）
- **真实性**：✅ 真 bug。用带人工真值的 JMangaBench_Read（muscgab，前 1,480 个文字框，官方评分脚本）量出三处，都在识别之前的版面处理，不是识别器认错字：
  1. **正文短列被当注音整列删掉**（丢列 85 框，占全部字错的四成）：`packages/fushi_engine/lib/ocr/ocr_line_layout.dart:79` `dropOcrRubyLines` 的 `sideRatio = 0.82` 只看行框厚度（`:110`）。行框厚度是检测器连通域外扩出来的，同一段正文各列能差出两三成，贴着较厚一列的短列（「あ？」「でも…」「は〜〜〜」）就落进注音口径。
  2. **竖排读成横排**（25 框）：竖长块里字距比列距大（疏排、斜体）时，行检测器沿小空隙把字连成横行，`ocr_line_layout.dart:53` `voteOcrLineOrientation` 跟着投成横排，逐行读出「しど言 / てんっ / くなた」这样串列的字。
  3. **几列被并成一列**：一条横跨多列列首的检出框让 `ocr_line_layout.dart:282` `mergeOcrLineFragments` 把它压到的每一列都判成同一列的碎片，连锁并成一条。
- **[x] ① 已修复** — 分支 `claude/ocr-performance-optimization-05596d`：
  - 注音判定加墨迹复核 `dropOcrRubyLinesByInk`（`ocr_ruby_trim.dart`）：几何上像注音的行再量框内字宽和它与相邻正文之间的空白，**字小且贴着正文**才删；量字宽时只量候选框独占的那一段（注音框常压着它标注那一列的边）。
  - `CtcColumnOcrRecognizer.recognizeWithLines`：竖长块投出横排时把裁图横向拉宽 2 倍重检一次（`PpOcrLineDetector.detectLayoutInBlock(stretchX:)`），列能连出来就按竖排读。
  - `absorbOcrCrossLines`（`ocr_line_layout.dart`）：横跨多列的框拆掉，它的范围并回各列。
  - `kMangaOcrPipelineRevision` v7 → v8，旧逐页缓存不复用。
- **[x] ② 已加自动化测试** — `fushi/test/ocr/ocr_ruby_ink_test.dart`（墨迹字宽、正文短列保留、小字注音照删、隔着列距的小字正文列保留、压边的注音框）、`fushi/test/ocr/ctc_column_orientation_test.dart`（拉宽重检、真横排不变、宽扁块不重检、跨列框不再并列）。
- **备注**：
  - 实测（官方评分，EM / CER）：前 1,480 框 83.99% / 5.86% → 87.43% / 3.27%；丢列 85 → 48 框，方向误判 25 → 2 框，多读进注音 7 → 8 框。方法与模型对比见 [docs/reviews/2026-11-17-manga-ocr-jmangabench.md](../reviews/2026-11-17-manga-ocr-jmangabench.md)。
  - 页级回归（无头 `fushi_server ocr screen --mode page`，改前改后逐块对比）：用户截图页两列都读出、「揉」旁的注音没读进来；全注音的《ドラえもん 第1巻》20 页 226 块只变 1 块（补回「…。」）；另两卷 44 页 286 块变 2 块，都是改对。
  - 未做：阅读器内 `paginated` / `continuous` / `vn` 三种 view mode 的设备复测——这次只改识别结果，没动覆盖层与排版；缓存升版后要整卷重跑才看得到，无头管线已覆盖同一条识别路径。
  - 剩余差距在识别器本身（替换 55 框、标点 49 框）和手写小字，换模型才追得上，见评测记录。
