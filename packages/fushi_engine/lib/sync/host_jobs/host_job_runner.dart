/// 一种任务类型的执行器契约。
library;

import 'dart:io';

/// 协作式取消：runner 在长循环里查 [isCancelled]，或订阅 [onCancel]。
class HostJobCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final void Function() l in List<void Function()>.of(_listeners)) {
      l();
    }
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }
}

class HostJobCancelledException implements Exception {
  const HostJobCancelledException();

  @override
  String toString() => 'HostJobCancelledException';
}

/// runner 看到的任务上下文。
class HostJobContext {
  const HostJobContext({
    required this.jobId,
    required this.params,
    required this.inputsDir,
    required this.outputsDir,
    required this.onProgress,
    required this.cancel,
  });

  final String jobId;
  final Map<String, Object?> params;

  /// 客户端上传的输入（文件名 = 上传时的 name）。
  final Directory inputsDir;

  /// 产物落点；runner 把文件写在这里并在 [HostJobOutcome.outputs] 里登记。
  final Directory outputsDir;
  final void Function(double progress, String? message) onProgress;
  final HostJobCancelToken cancel;

  File input(String name) => File('${inputsDir.path}/$name');

  File output(String name) => File('${outputsDir.path}/$name');
}

class HostJobOutcome {
  const HostJobOutcome({
    required this.outputs,
    this.primaryOutput,
    this.message,
  });

  /// 产物名 → outputs/ 下的文件名（可同名）。
  final Map<String, String> outputs;
  final String? primaryOutput;
  final String? message;
}

abstract interface class HostJobRunner {
  /// wire 上的 kind（`asr` …）。
  String get kind;

  /// `/api/capabilities` 里 `jobs.<kind>` 的内容（模型是否就绪、支持的语言…）。
  Future<Map<String, Object?>> capability();

  /// 创建时校验参数；不合法抛 [FormatException]（→ 400）。
  void validateParams(Map<String, Object?> params);

  Future<HostJobOutcome> run(HostJobContext ctx);

  /// 产物 content-type（按名）。
  String contentTypeFor(String outputName);
}
