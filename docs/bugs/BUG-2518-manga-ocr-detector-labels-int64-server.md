## BUG-2518 · 无头服务端漫画 OCR 第一页空指针：检测器 labels 只认 float
- **报告**：2026-09-13（用真实模型 + `fushi_server` 的纯 Dart FFI 会话跑 `runMangaOcrFolderJob` 时发现）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/ocr/text_detector.dart` `TextDetector.detect` 对图内后处理导出读 `labels.floatData!`；flutter_onnxruntime 插件把一切输出读成 float 所以 app 侧没炸，而 `fushi_asr_onnx_ffi` 的会话按 ORT 元素类型原样返回 int64 → `floatData` 为 null → 「Null check operator used on a null value」。服务端用当前清单的 int8 检测器（输出 scores/labels/boxes）跑漫画 OCR 必崩。
- **[x] ① 已修复** — `b2a9cfc5e5`：`_labelValues` 三型（float32/int64/int32）都吃，`decodeProcessedRtdetrOutputs` 收 `List<num>`。
- **[x] ② 已加自动化测试** — `fushi/test/ocr/text_detector_test.dart`「图内后处理导出的 labels 是 int64 时同样解码」。
- **备注**：
