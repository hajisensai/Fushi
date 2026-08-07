/// BUG-1025：同词重复复制的「回声 vs 用户显式重查」时间窗。挖词/抓选区写回剪贴板的
/// 自触发回声在毫秒级到达；用户手动再次复制同一个词通常隔数秒。窗口内的同词判为回声
/// 跳过，超窗口的同词判为用户显式重查放行。自触发回声另有 [ClipboardIgnoreSet] 精确
/// 拦截，此窗口是第二层保险，取值宽松到足以覆盖抓选区往返、又远小于人手重复复制间隔。
const Duration kClipboardRecopyWindow = Duration(milliseconds: 800);

/// 剪贴板去重：trim 后为空返回 null（不触发查词）。与 [last] 相同的处理见下——
/// BUG-1025 前是「相同即 null」永久去重，导致用户手动重复复制同一个词无法再查。
///
/// 现改为**时间窗**去重：仅当与 [last] 相同 **且** 距上次（[lastAt]）在 [window] 内，
/// 才判为自触发回声跳过；超窗口的同词视为用户显式重查，放行。只有同时给出 [lastAt] 与
/// [now] 才启用时间窗；裸 2 参调用（无时序）保持历史「相同即跳过」行为，供纯函数单测。
String? dedupeClipboard(
  String raw,
  String? last, {
  DateTime? lastAt,
  DateTime? now,
  Duration window = kClipboardRecopyWindow,
}) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed == last) {
    if (lastAt == null || now == null) return null;
    if (now.difference(lastAt) < window) return null;
  }
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
