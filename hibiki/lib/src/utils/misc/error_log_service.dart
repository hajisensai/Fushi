import 'dart:io';
import 'package:path_provider/path_provider.dart';

class ErrorLogEntry {
  final DateTime timestamp;
  final String source;
  final String error;
  final String? stackTrace;

  ErrorLogEntry({
    required this.timestamp,
    required this.source,
    required this.error,
    this.stackTrace,
  });

  String format() {
    final buf = StringBuffer()
      ..writeln('[$timestamp] $source')
      ..writeln(error);
    if (stackTrace != null && stackTrace!.isNotEmpty) {
      buf.writeln(stackTrace);
    }
    buf.writeln('─' * 60);
    return buf.toString();
  }
}

class ErrorLogService {
  ErrorLogService._();
  static final instance = ErrorLogService._();

  static const int _maxEntries = 200;

  final List<ErrorLogEntry> _entries = [];
  List<ErrorLogEntry> get entries => List.unmodifiable(_entries);

  File? _logFile;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/error_log.txt');
  }

  void log(String source, Object error, [StackTrace? stack]) {
    final entry = ErrorLogEntry(
      timestamp: DateTime.now(),
      source: source,
      error: error.toString(),
      stackTrace: stack?.toString(),
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    _appendToFile(entry);
  }

  void _appendToFile(ErrorLogEntry entry) {
    try {
      _logFile?.writeAsStringSync(entry.format(), mode: FileMode.append);
    } catch (_) {}
  }

  String getFullLog() {
    if (_entries.isEmpty) return '暂无错误日志';
    final buf = StringBuffer();
    for (final e in _entries.reversed) {
      buf.write(e.format());
    }
    return buf.toString();
  }

  Future<File?> getLogFile() async {
    if (_logFile == null) return null;
    try {
      final content = getFullLog();
      await _logFile!.writeAsString(content);
      return _logFile;
    } catch (_) {
      return null;
    }
  }

  void clear() {
    _entries.clear();
    try {
      _logFile?.writeAsStringSync('');
    } catch (_) {}
  }
}
