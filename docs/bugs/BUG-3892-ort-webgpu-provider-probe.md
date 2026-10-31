## BUG-3892 · ort-webgpu-provider-probe
- **报告**：2026-10-28（应用内反馈 eEnV5gBn1K，OnePlus CPH2747 / Android 16，3.0.1-debug.21889：转录面板「GPU 探测失败，按 CPU 规划：Invalid argument(s): Provider WEBGPU is not a valid OrtProvider.」）
- **真实性**：✅ 真 bug（根因 `third_party/flutter_onnxruntime/lib/src/onnxruntime.dart` `getAvailableProviders` 的 `firstWhere(orElse: throw ArgumentError)` + `android/.../FlutterOnnxruntimePlugin.kt` `mapProviderNameToEnumName` 没有 `WEBGPU` 映射：Android ORT 1.28（PATCHES #14）回报 `WEBGPU`，Dart 枚举叫 `WEB_GPU`）
- **[x] ① 已修复** — Dart 侧未知 EP 名丢弃而非抛错（枚举表达不了的 EP 本来也无法请求）；Kotlin 侧补 `WEBGPU -> WEB_GPU`；vendored 记录 `third_party/flutter_onnxruntime/PATCHES.md` #15（分支 pr/fb-onnx-webgpu）
- **[x] ② 已加自动化测试** — `fushi/test/onnx/onnxruntime_available_providers_test.dart`（经真实 method channel 回报含未知名 / `WEB_GPU` 的列表，断言解析结果；静态钉 Kotlin 映射）
- **备注**：Android 加速 EP 选择本来只认 CUDA / DML / CoreML，实际仍走 CPU；修的是探测整体失败带来的误报与降级说明。未在 Android 真机复看探测文案。
