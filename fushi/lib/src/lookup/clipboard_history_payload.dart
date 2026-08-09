import 'dart:convert';

import 'package:fushi/src/models/clipboard_history_repository.dart';

/// 构建注入 `window.__globalLookupHost.showClipboardHistory(...)` 的 payload。
///
/// 面板栏🕘 / 瞬态 root 卡🕘 打开历史时，Dart 从 DB 重载 [entries]（tail=最新），
/// 本函数转成 host JS 期望的对象字面量：`{entries:[{text,time}], title, clearLabel,
/// emptyLabel}`。entries 顺序在此 **reverse 成最新在前**（JS 逐行铺，天然新→旧）。
///
/// 用 [jsonEncode] 安全转义任意剪贴板文本（引号 / 反斜杠 / 换行 / 控制字符），再由
/// [_escapeJsLineSeparators] 补掉 JSON 合法但 JS 字符串里会截断的 U+2028/U+2029，
/// 使返回串可直接内插进 `showClipboardHistory(<此串>)`（是 JS 对象字面量，非二次编码）。
String buildClipboardHistoryPayloadJson({
  required List<ClipboardHistoryEntry> entries,
  required String title,
  required String clearLabel,
  required String emptyLabel,
  required DateTime now,
}) {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  for (int i = entries.length - 1; i >= 0; i--) {
    final ClipboardHistoryEntry entry = entries[i];
    rows.add(<String, Object?>{
      'text': entry.text,
      'time': formatClipboardHistoryTime(entry.copiedAt, now),
    });
  }
  final String encoded = jsonEncode(<String, Object?>{
    'entries': rows,
    'title': title,
    'clearLabel': clearLabel,
    'emptyLabel': emptyLabel,
  });
  return _escapeJsLineSeparators(encoded);
}

/// 复制时刻的紧凑本地时间：今天只显示 `HH:mm`，跨天加 `MM-DD`。传入 [now] 便于纯测。
String formatClipboardHistoryTime(DateTime copiedAt, DateTime now) {
  final DateTime at = copiedAt.toLocal();
  final DateTime ref = now.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final String hhmm = '${two(at.hour)}:${two(at.minute)}';
  final bool sameDay =
      at.year == ref.year && at.month == ref.month && at.day == ref.day;
  return sameDay ? hhmm : '${two(at.month)}-${two(at.day)} $hhmm';
}

/// U+2028 / U+2029 是 JSON 合法字符，但在 JS 源码里是行终止符，直接内插会截断字符串
/// 字面量。转成 `\uXXXX` 转义序列（JSON.parse 与 JS 引擎都能还原原字符）。
String _escapeJsLineSeparators(String json) {
  return json.replaceAll(' ', '\\u2028').replaceAll(' ', '\\u2029');
}
