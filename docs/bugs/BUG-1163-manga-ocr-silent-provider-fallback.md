## BUG-1163 · 漫画 OCR GPU 加速降级到 CPU 完全静默
- **报告**：2026-07-27（用户：PR#474 审查）
- **真实性**：✅ 真 bug。两条静默降级路径：
  1. `hibiki/lib/src/ocr/ocr_inference_ort.dart:53-59`（旧行号）捕获
     `PlatformException(INVALID_PROVIDER)` 后用纯 CPU provider 重建 session，
     全程无日志、无事件、无 UI 提示；
  2. `hibiki/lib/src/ocr/manga_ocr_service_impl.dart:173-176`（旧行号）用
     `catch (_)` 吞掉 CUDA 探测异常。
  两个 OCR 目录 grep `debugPrint|developer.log|Logger` 零命中，isolate 只回发
  progress/done/error，i18n 无任何 EP/GPU 文案 ⇒ 用户以为在跑 GPU，实际在跑
  CPU，在整卷 OCR 这种耗时任务上毫无可观测信号。违反本仓「降级必须显式」硬规矩。
- **[x] ① 已修复** — `OcrProviderResolution`（`ocr_inference.dart`）把「实际生效
  的 provider + 降级原因」抬到接口面；`createOcrSessionWithProviderFallback` 新增
  `onResolved`，**无论是否降级都回报一次**并写 `dart:developer` 日志（`kOcrLogName`
  = `hibiki.ocr`，后台 isolate 无 Flutter binding，故不用 `debugPrint`）；CUDA 探测
  失败不再 `catch (_)`，异常进 `MangaOcrAcceleration.degradeReasons`；整卷 isolate
  汇总成 `MangaOcrAcceleration` 回发主 isolate，挂在每个 `MangaOcrVolumeEvent` 上，
  经 `MangaOcrBackgroundEvent` 传到阅读器：顶栏常驻显示当前后端标签（降级标黄）、
  tooltip 带一行加速状态、首次观测到降级弹一次 toast。新增 i18n
  `manga_ocr_acceleration_status` / `manga_ocr_acceleration_degraded`。
- **[x] ② 已加自动化测试** — `hibiki/test/ocr/ocr_inference_ort_test.dart`（降级必回报
  一次且带 `INVALID_PROVIDER`/`DIRECT_ML` 原因；不降级也必回报；观察者抛异常不影响
  会话创建）+ `hibiki/test/ocr/manga_ocr_service_impl_test.dart`（加速状态挂到每个
  进度事件与 finished 事件、未降级不误报）。负向验证：把 `_notifyResolved` 改成
  「降级时不回报」→ `unsupported DirectML provider retries once with CPU` 转红，已还原。
- **备注**：`OcrProviderResolution.effective` 的粒度就是插件边界的粒度——
  `flutter_onnxruntime` 只回报整张 provider 列表被接受/被拒，不回报 ORT 内部最终
  选中的 EP，doc 里已写明。
