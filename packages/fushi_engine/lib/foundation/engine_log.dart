/// 引擎侧结构化日志装配点。
///
/// 引擎（本包）不依赖 Flutter，也不认识 app 的 `ErrorLogService`；所有从 app
/// 平移进来的 `ErrorLogService.instance.log*` 调用改为 [engineLog]，由宿主装配：
/// - Flutter app：`ErrorLogService implements EngineLogSink`，`main()` 里
///   `engineLog = ErrorLogService.instance`（行为与从前逐字节一致）。
/// - 无头服务端：stderr + 滚动文件。
/// - 纯 Dart 测试：默认 [StderrEngineLogSink]，不吞、不抛。
///
/// 三个方法与 `ErrorLogService` 同名同签名，`implements` 即可，零适配代码。
library;

import 'dart:io';

abstract interface class EngineLogSink {
  /// 可恢复错误（与 `ErrorLogService.log` 同契约）。
  void log(String source, Object error, [StackTrace? stack]);

  /// 诊断信息（非错误）。
  void logDiagnostic(String source, Object info);

  /// 致命错误（宿主可能据此触发上报）。
  void logFatal(String source, Object error, [StackTrace? stack]);
}

/// 默认 sink：写 stderr，不缓存、不上传。
class StderrEngineLogSink implements EngineLogSink {
  const StderrEngineLogSink();

  @override
  void log(String source, Object error, [StackTrace? stack]) {
    stderr.writeln('[fushi-engine] $source: $error');
    if (stack != null) stderr.writeln(stack);
  }

  @override
  void logDiagnostic(String source, Object info) {
    stderr.writeln('[fushi-engine] $source: $info');
  }

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) {
    stderr.writeln('[fushi-engine] FATAL $source: $error');
    if (stack != null) stderr.writeln(stack);
  }
}

/// 全局装配点。宿主进程入口写一次。
EngineLogSink engineLog = const StderrEngineLogSink();
