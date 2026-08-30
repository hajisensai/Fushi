## BUG-1968 · Windows 漫画 OCR detector 未实际启用 DirectML
- **报告**：2026-08-30（用户：）
- **真实性**：✅ 真 bug。截图里的
  `detector: directml -> cpu (INVALID_PROVIDER: Provider is not supported: DIRECT_ML)`
  来自真实 provider 降级链。根因有两层：
  `third_party/flutter_onnxruntime/windows/CMakeLists.txt` 下载普通
  `onnxruntime-win-x64`，该官方 archive 是 CPU 版、不含
  `DmlExecutionProvider`；同时
  `third_party/flutter_onnxruntime/windows/flutter_onnxruntime_plugin.cpp`
  的 session provider 分支只实现 CPU/CUDA，收到 `DIRECT_ML` 必然返回
  `INVALID_PROVIDER`。因此 Windows 无 CUDA 时 detector 虽按策略首选
  DirectML，实际始终回退 CPU。
- **[x] ① 已修复** — Windows 插件改用 SHA-256 固定的官方
  `Microsoft.ML.OnnxRuntime.DirectML` 与 `Microsoft.AI.DirectML` NuGet
  产物，随包带齐 `onnxruntime.dll`、`onnxruntime_providers_shared.dll`、
  `DirectML.dll`；`DIRECT_ML` 分支设置顺序执行、关闭 memory pattern，并
  经 `OrtDmlApi::SessionOptionsAppendExecutionProvider_DML` 创建真实 DML session。
  提交：本提交。
- **[x] ② 已加自动化测试** —
  `fushi/test/ocr/onnxruntime_windows_directml_guard_test.dart` 守卫官方 DML
  package、校验哈希、三份运行时 DLL 与 native DML factory 接线，防止
  re-vendor 后静默退回 CPU-only archive。按用户要求直接开 PR，本地测试
  未执行，交 PR CI 验证。
- **备注**：仅 detector 使用 DirectML；recognizer 继续走 CPU 是既定性能策略，
  因为自回归逐步解码在 DML 上会产生更高往返开销。真实 Windows GPU 推理
  尚待构建产物/设备复测，PR 不据此宣称真机已验证。
