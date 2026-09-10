/// 服务端日志：stderr + `<data>/logs/fushi_server.log` 滚动文件。
///
/// 同时是引擎的 [EngineLogSink] 实现（`engineLog = ServerLog(...)`）和
/// `fushiDebugPrint` 的落点。滚动策略很朴素：超过 [maxBytes] 就把当前文件改名为
/// `.1` 覆盖上一份——服务端日志是排障用，不是审计用。
library;

import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';

class ServerLog implements EngineLogSink {
  ServerLog({required this.file, this.maxBytes = 8 * 1024 * 1024, this.verbose = false});

  final File file;
  final int maxBytes;
  final bool verbose;
  IOSink? _sink;
  int _written = 0;

  /// 最近 N 行环形缓冲，供 WebUI `/api/admin/logs` 直接读。
  final List<String> recent = <String>[];
  static const int _recentCap = 500;

  Future<void> open() async {
    await file.parent.create(recursive: true);
    if (await file.exists()) _written = await file.length();
    _sink = file.openWrite(mode: FileMode.append);
  }

  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }

  void _emit(String level, String line) {
    final String stamped = '${DateTime.now().toIso8601String()} [$level] $line';
    stderr.writeln(stamped);
    recent.add(stamped);
    if (recent.length > _recentCap) recent.removeAt(0);
    final IOSink? sink = _sink;
    if (sink == null) return;
    sink.writeln(stamped);
    _written += stamped.length + 1;
    if (_written > maxBytes) _rotate();
  }

  void _rotate() {
    final IOSink? sink = _sink;
    _sink = null;
    sink?.close();
    try {
      final File rolled = File('${file.path}.1');
      if (rolled.existsSync()) rolled.deleteSync();
      file.renameSync(rolled.path);
    } catch (_) {
      // 滚动失败不致命：继续往新文件写。
    }
    _written = 0;
    _sink = file.openWrite(mode: FileMode.append);
  }

  void info(String line) => _emit('info', line);

  void debug(String? line) {
    if (verbose) _emit('debug', line ?? 'null');
  }

  @override
  void log(String source, Object error, [StackTrace? stack]) {
    _emit('error', '$source: $error');
    if (stack != null && verbose) _emit('error', '$stack');
  }

  @override
  void logDiagnostic(String source, Object info) => _emit('diag', '$source: $info');

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) {
    _emit('fatal', '$source: $error');
    if (stack != null) _emit('fatal', '$stack');
  }
}
