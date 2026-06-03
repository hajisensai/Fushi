import 'package:flutter/foundation.dart';
import 'package:hibiki/src/utils/misc/frame_safe_notifier.dart';
import 'package:hibiki/utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DebugLogService extends ChangeNotifier with FrameSafeNotifier {
  DebugLogService._();
  static final DebugLogService instance = DebugLogService._();

  static const int _maxEntries = 500;
  static const String _enabledKey = 'debug_log_enabled';

  final List<DebugLogEntry> _entries = [];
  List<DebugLogEntry> get entries => List.unmodifiable(_entries);

  bool _enabled = false;
  bool get enabled => _enabled;

  DebugPrintCallback? _originalDebugPrint;

  Future<void> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    _installHook();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    if (!value) {
      _entries.clear();
    }
    notifyListenersFrameSafe();
  }

  void _installHook() {
    if (_originalDebugPrint != null) return;
    _originalDebugPrint = debugPrint;
    debugPrint = _interceptedDebugPrint;
  }

  void _interceptedDebugPrint(String? message, {int? wrapWidth}) {
    _originalDebugPrint?.call(message, wrapWidth: wrapWidth);
    if (!_enabled || message == null) return;
    _entries.add(DebugLogEntry(
      timestamp: DateTime.now(),
      message: message,
    ));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListenersFrameSafe();
  }

  String getFullLog() {
    if (_entries.isEmpty) return t.no_debug_logs;
    final StringBuffer buf = StringBuffer();
    for (final DebugLogEntry e in _entries.reversed) {
      buf.writeln('[${e.timestamp.hour.toString().padLeft(2, '0')}:'
          '${e.timestamp.minute.toString().padLeft(2, '0')}:'
          '${e.timestamp.second.toString().padLeft(2, '0')}.'
          '${e.timestamp.millisecond.toString().padLeft(3, '0')}] '
          '${e.message}');
    }
    return buf.toString();
  }

  void clear() {
    _entries.clear();
    notifyListenersFrameSafe();
  }
}

class DebugLogEntry {
  const DebugLogEntry({required this.timestamp, required this.message});
  final DateTime timestamp;
  final String message;
}
