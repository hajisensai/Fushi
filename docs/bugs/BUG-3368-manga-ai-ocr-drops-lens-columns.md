## BUG-3368 · 大模型OCR回写丢失Lens列几何致查词错位
- **报告**：2026-10-15（用户群反馈：OCR 识别偶尔会有位置错位）
- **真实性**：✅ 真 bug（代码路径确认，未真机复现）。Lens 块只有一行 `lines: [sentence]` + 逐字 `regions`、没有 `linesCoords`（`fushi/lib/src/media/manga/ocr/google_lens_ocr_service.dart:329`）；`applyMangaAiOcrText`（`packages/fushi_engine/lib/ocr/manga_ai_ocr_refiner.dart:945`）一律丢掉 `regions`、又拿不到行框，退成整块单行，覆盖层沿长轴均分，多列竖排气泡里每个字的热区横跨所有列——点第二列查到第一列的字。偶发：只命中被大模型挑中并改写的多列 Lens 块，且是本地结果先出、几秒后大模型结果覆盖时才变坏（10-13 起低置信度默认交大模型，命中面变大）。
- **[x] ① 根因修复** — 模型文字与原文一致时原样保留 `regions`；文字变了时由 `_lineBoxesFromRegions`（`manga_ai_ocr_refiner.dart:1008`）按阅读序把逐字区聚回列 / 行框，再走既有 `layoutOcrTextOnLines` 重排。
- **[x] ② 自动化测试** — `fushi/test/ocr/manga_ai_ocr_refiner_test.dart`「Lens 块模型读出同样的字」「Lens 块文字变了：按逐字热区聚回列框排版」。
- **备注**：同次调查发现的次要错位源未修：系统 OCR 不按 EXIF 方向换算坐标、大模型裁图不 `bakeOrientation`、`_onStreamingPageMeasured` 在已有 OCR 块的页上改尺寸；长条页送 Lens 被缩到最长边 1500。
