/// 剪贴板去重：trim 后为空或与 [last] 相同返回 null（不触发查词），
/// 否则返回 trim 后的新文本。避免挖词/复制写回剪贴板时自触发循环。
String? dedupeClipboard(String raw, String? last) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed == last) return null;
  return trimmed;
}

/// 一次性剪贴板忽略集（spec 2026-07-10 §8 抓选区泄漏根修）。全局查词抓选区
/// （selection_capture_ffi）对剪贴板的写入会触发 WM_CLIPBOARDUPDATE，此刻 app
/// 必不在前台，DesktopLookupService 会把「捕获文本」「恢复的旧文本」当成用户
/// 复制排进查词管线（假查词）。抓取方登记这批文本；监听端处理事件时先
/// [consume]——命中即吞掉并移除（一次性）；未命中说明捕获窗口期已过，整批清空，
/// 防陈旧登记吞掉用户后续的真实复制。纯 Dart，无平台依赖，直接单测。
class ClipboardIgnoreSet {
  final Set<String> _texts = <String>{};

  bool get isEmpty => _texts.isEmpty;

  void register(Iterable<String> texts) {
    for (final String t in texts) {
      final String trimmed = t.trim();
      if (trimmed.isNotEmpty) _texts.add(trimmed);
    }
  }

  /// true = 该文本是抓选区自产事件，调用方应丢弃本次剪贴板变化。
  bool consume(String text) {
    if (_texts.remove(text.trim())) return true;
    _texts.clear();
    return false;
  }
}
