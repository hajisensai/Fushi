## BUG-1131 · Windows 漫画本地 OCR 不支持 DirectML 时未回退 CPU
- **报告**：2026-07-27（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/ocr/ocr_inference_ort.dart:47`
  原先把 DirectML 放在 provider 首位，但本机 ONNX Runtime 不包含该 provider，
  会以 `PlatformException(INVALID_PROVIDER)` 直接终止整卷任务。
- **[x] ① 已修复** — 仅在错误码明确为 `INVALID_PROVIDER` 且配置中包含 CPU 时，
  以 CPU provider 重建一次 session；模型损坏、输入错误等真实异常保持原样抛出，
  不做掩盖式重试。
- **[x] ② 已加自动化测试** —
  `hibiki/test/ocr/ocr_inference_ort_test.dart` 覆盖 DirectML→CPU、CPU 不重试及
  非 provider 异常不吞。
- **备注**：真实 Windows 本地 OCR 已越过 `INVALID_PROVIDER` 并产出封面页缓存。
