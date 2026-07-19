import 'package:flutter/foundation.dart';

/// 收到的 texthooker 文本行 buffer。单例 + ChangeNotifier（仿 DebugLogService），
/// 由 [TexthookerWsClient] 调用 [appendLine]（外部 texthooker 软件经 WebSocket 接入）。
/// 注意：galgame UX 统一后，独立 texthooker tab / TexthookerPage 已删；galgame 台词改走
/// [DesktopLookupService.submitText] 进悬浮查词面板（见 GalgameSessionController）。本
/// WS 通路仍保留（供外部 texthooker 软件接入），但不再有专属常驻 UI 落点。
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
