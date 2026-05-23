import 'dart:io';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:path_provider/path_provider.dart';

class ErrorLogEntry {
  ErrorLogEntry({
    required this.timestamp,
    required this.source,
    required this.error,
    this.stackTrace,
  });
  final DateTime timestamp;
  final String source;
  final String error;
  final String? stackTrace;

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
  static const int _maxFileBytes = 512 * 1024;

  final List<ErrorLogEntry> _entries = [];
  List<ErrorLogEntry> get entries => List.unmodifiable(_entries);

  File? _logFile;
  String _persistedLog = '';

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}/error_log.txt');
    try {
      if (await _logFile!.exists()) {
        var content = await _logFile!.readAsString();
        if (content.length > _maxFileBytes) {
          content = content.substring(content.length - _maxFileBytes);
          final firstSep = content.indexOf('─' * 60);
          if (firstSep != -1) {
            content = content.substring(firstSep + 60).trimLeft();
          }
          await _logFile!.writeAsString(content);
        }
        _persistedLog = content;
      }
    } catch (_) {}
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

  Future<void> _appendToFile(ErrorLogEntry entry) async {
    try {
      await _logFile?.writeAsString(entry.format(), mode: FileMode.append);
    } catch (_) {}
  }

  String getFullLog() {
    if (_entries.isEmpty && _persistedLog.isEmpty) return t.error_log_empty;
    final buf = StringBuffer();
    for (final e in _entries.reversed) {
      buf.write(e.format());
    }
    if (_persistedLog.isNotEmpty) {
      if (_entries.isNotEmpty) {
        buf.writeln('═' * 60);
        buf.writeln('▼ ${t.error_log_previous_run}');
        buf.writeln('═' * 60);
      }
      buf.write(_persistedLog);
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

  Future<void> clear() async {
    _entries.clear();
    _persistedLog = '';
    try {
      await _logFile?.writeAsString('');
    } catch (_) {}
  }
}
