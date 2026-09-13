## BUG-2517 · 漫画 OCR 同一块文字在 manga.json 里写两次（NMS 文字两类互不抑制）
- **报告**：2026-09-13（用户库「週に一度…」第 2 页人物名栏 `宮城志緒理` box 完全相同的两个 block，z_index 3/4）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/ocr/text_detector.dart` `decodeRtdetrOutputs` / 图内后处理导出按 (query, class) 对过阈值，同一 query 在 text_bubble(1) 与 text_free(2) 上都过 0.3 时产出两个 rect 逐字节相同的检测；`applyClassAwareNms` 旧实现 `keep.classId == candidate.classId` 才抑制，1 与 2 互不抑制，两块都被识别、都写进 manga.json。真实模型复跑第 2 页：修前 10 块（含 2 对重复）→ 修后 8 块。
- **[x] ① 已修复** — `766f31f0a7`：NMS 分组改为气泡 {0} / 文字 {1,2} 两组（`nmsGroupOf`），文字同框只留高分并带其 classId。
- **[x] ② 已加自动化测试** — `fushi/test/ocr/text_detector_test.dart`「text_bubble 与 text_free 同框只留高分」。
- **备注**：
