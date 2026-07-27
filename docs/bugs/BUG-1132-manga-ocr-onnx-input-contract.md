## BUG-1132 · 漫画 OCR 按 ONNX 元数据适配单输入模型名称
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/ocr/ocr_inference_ort.dart:67`
  把检测器输入硬编码成 `pixel_values`，而实际下载的 RT-DETR 声明输入
  `images` 与 `orig_target_sizes`，运行时报 `Invalid input name: pixel_values`；
  其输出也是图内后处理的 `scores/labels/boxes`，并非旧版 raw logits。
- **[x] ① 已修复** — session 按模型元数据解析输入名，支持
  `pixel_values → images` 语义别名且不对多输入模型按顺序盲猜；检测器补入
  `orig_target_sizes`，同时兼容 raw 与图内后处理两套 RT-DETR 输出。
- **[x] ② 已加自动化测试** —
  `hibiki/test/ocr/ocr_inference_ort_test.dart` 覆盖单/多输入解析，
  `hibiki/test/ocr/text_detector_test.dart` 覆盖当前真实模型输入输出契约。
- **备注**：Windows 真实模型成功完成封面检测与识别并写入 8 个 OCR 块。
