## BUG-3510 · manga-local-ocr-boxes-misaligned
- **报告**：2026-10-17（用户：Android 漫画阅读器 OCR 点击框和实际文字不贴合——横排人物资料页上块框大片重叠、一个从页顶到页底的巨框盖住多块、有的块框只框第一行；单行标题「第13話 — クリスマス」字格轻微偏移）
- **真实性**：✅ 真 bug（读代码定性；屏幕映射层核查无坐标系问题，问题在本地 ONNX OCR 产出的几何）。三个独立根因：
  1. `packages/fushi_engine/lib/ocr/manga_ocr_pipeline.dart` `_suppressRecognizedContainedBlocks`：包含判重只在父框宽≥高且父文本逐字包含子文本时删子块，竖长大父框永不处理，检测器给出的大框与其内小块全部落进 manga.json（NMS `text_detector.dart` 只删 IoU≥0.7）。
  2. `packages/fushi_engine/lib/ocr/ocr_line_layout.dart` `mergeOcrLineFragments`：只看跨轴重叠、沿轴间距无上限，左右分栏同一高度的行被并成跨栏长行。
  3. 本地识别只用 `recognizeLineScored`，CTC token 位置被丢掉，覆盖层（`manga_overlay_html.dart`）只能按行宽均分字格，半角数字 / 破折号 / 空格处越往后偏得越多。
- **[x] ① 已修复** — ① 新增 `_dropContainerBlocks`：几何包含 ≥2 个已识别子块且行面积 ≥75% 被子块覆盖的父块让位给叶子块（不看宽高、不依赖文本包含；父块无行几何时不删）；② `kOcrFragmentMaxGapRatio = 3`（× 较厚段行厚）作沿轴间距上限，合并时向前回溯所有已合并行；③ 新增 `ctcGreedyDecodePositioned` / `recognizeLinePositioned` 与 `ocr_glyph_boxes.dart`，本地识别把 token 位置映射回页面写成块的 `regions`（正立行才写，拿不全位置退回均分）；`kMangaOcrPipelineRevision` 升 `v7-leaf-blocks-glyph-boxes` 使旧逐页缓存失效。
- **[x] ② 已加自动化测试** — `fushi/test/ocr/manga_ocr_pipeline_test.dart`、`fushi/test/ocr/ocr_line_layout_test.dart`、`fushi/test/ocr/ppocr_line_recognizer_test.dart`、`fushi/test/ocr/ctc_column_ocr_recognizer_test.dart`、`fushi/test/ocr/routing_ocr_recognizer_test.dart`、`fushi/test/media/manga/manga_local_ocr_tap_geometry_test.dart`。
- **备注**：已有 manga.json 需重跑本地 OCR 才生效。阈值（0.75 / 3 / 字格 0.6 倍行厚）按推理取值，未用真实卷对拍；未在 Android 真机复测原始页面。用户若用的是 Google Lens 引擎，另有一处未修的段落方向误判（`google_lens_protocol.dart` 段落外接框长宽比压过行投票）。
