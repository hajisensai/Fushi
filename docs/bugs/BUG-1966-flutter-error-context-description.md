## BUG-1966 · Flutter 错误日志显示 ErrorDescription 实例名
- **报告**：2026-08-30（用户截图：错误日志每条握手失败的来源均显示 `FlutterError: Instance of 'ErrorDescription'`）
- **真实性**：✅ 真 bug。`fushi/lib/main.dart:582` 的全局 `FlutterError.onError` 把 `FlutterErrorDetails.context` 直接调用 `toString()` 后写入日志来源。该字段的静态类型是 `DiagnosticsNode?`，截图路径实际传入 `ErrorDescription`；Flutter SDK 明确要求它承载“异常在哪里被捕获”的人类可读说明，但 `Object.toString()` 只给出实例类型，真正说明由 `DiagnosticsNode.toDescription()` 暴露。因此握手异常正文仍在，捕获位置却稳定丢失。
- **[x] ① 已修复** — `67edc877a5`：新增 `flutterErrorLogSource`，统一通过 `details.context?.toDescription()` 提取捕获位置，空上下文显式降级为 `FlutterError: unknown`；`main.dart` 的致命同步落盘、异常正文与堆栈保持原样。
- **[x] ② 已加自动化测试** — `67edc877a5`：`fushi/test/utils/misc/flutter_error_log_test.dart` 直接构造带 `ErrorDescription('while resolving an image codec')` 的 `FlutterErrorDetails`，断言日志来源得到可读文本且不再泄漏实例名，并覆盖无 context 的 fallback。
- **备注**：本修复改善错误日志的定位信息，不吞掉或伪装截图中的 `HandshakeException`；网络失败仍作为下一行异常正文和原堆栈保留。
