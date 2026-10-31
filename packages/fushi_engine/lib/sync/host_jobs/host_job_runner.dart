/// 一种任务类型的执行器契约。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

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
    this.hostInputs = const <String, String>{},
  });

  final String jobId;
  final Map<String, Object?> params;

  /// 客户端上传的输入（文件名 = 上传时的 name）。
  final Directory inputsDir;

  /// 产物落点；runner 把文件写在这里并在 [HostJobOutcome.outputs] 里登记。
  final Directory outputsDir;
  final void Function(double progress, String? message) onProgress;
  final HostJobCancelToken cancel;

  /// 输入名 → host 本地已有的同内容文件（客户端没上传这份，见
  /// `HostJobRecord.hostInputs`）。runner 读输入一律经 [input] / [inputNames]，
  /// 不要直接列 [inputsDir]，否则看不到这些输入。
  final Map<String, String> hostInputs;

  /// 本任务全部输入名（上传的 + host 本地命中的），按名字排序——客户端用定宽序号
  /// 前缀命名，排序即提交顺序。
  List<String> get inputNames {
    final Set<String> names = <String>{...hostInputs.keys};
    if (inputsDir.existsSync()) {
      for (final FileSystemEntity e in inputsDir.listSync()) {
        if (e is File) names.add(p.basename(e.path));
      }
    }
    return names.toList()..sort();
  }

  /// 输入文件：host 本地命中的给本地路径，否则是上传落盘的那份。
  File input(String name) {
    final String? local = hostInputs[name];
    if (local != null) return File(local);
    return File('${inputsDir.path}/$name');
  }

  /// [name] 是不是 host 本地文件（runner 不得删改它，也不该把它当一次性中间件）。
  bool isHostInput(String name) => hostInputs.containsKey(name);

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
