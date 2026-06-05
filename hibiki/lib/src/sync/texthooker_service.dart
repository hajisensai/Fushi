import 'package:flutter/foundation.dart';

/// 收到的 texthooker 文本行 buffer。单例 + ChangeNotifier（仿 DebugLogService），
/// 由 [TexthookerWsClient] 调用 [appendLine]，由 TexthookerPage 订阅刷新。
class TexthookerService extends ChangeNotifier {
  TexthookerService._();
  static final TexthookerService instance = TexthookerService._();

  static const int maxLines = 500;

  final List<String> _lines = <String>[];
  List<String> get lines => List<String>.unmodifiable(_lines);

  void appendLine(String line) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _lines.add(trimmed);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    notifyListeners();
  }

  void clear() {
    if (_lines.isEmpty) return;
    _lines.clear();
    notifyListeners();
  }
}
