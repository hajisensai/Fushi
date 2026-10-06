library;

String? metadataString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? metadataInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? metadataDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

bool? metadataBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    return switch (value.trim().toLowerCase()) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => null,
    };
  }
  return null;
}

Map<String, Object?>? metadataObject(Object? value) =>
    value is Map<String, Object?> ? value : null;

List<Object?> metadataList(Object? value) =>
    value is List<Object?> ? value : const <Object?>[];

int? metadataYear(String? date) {
  if (date == null || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}

/// 来源简介（AniList `description`、Jikan `synopsis`）里的 HTML 转成纯文本：
/// `<br>` / 段落尾 → 换行、其余标签剥掉、常见命名实体与数字实体（`&#039;` /
/// `&#x27;` / `&nbsp;` …）还原、连续空行压成一个。`&amp;` 最后还原，
/// `&amp;lt;` 才不会被二次解码成 `<`。
String? metadataStripHtml(String? value) {
  if (value == null) return null;
  final String result = value
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAllMapped(RegExp(r'&#([xX][0-9a-fA-F]+|[0-9]+);'), _numericEntity)
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&hellip;', '…')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return result.isEmpty ? null : result;
}

String _numericEntity(Match match) {
  final String code = match.group(1)!;
  final int? point = code.startsWith('x') || code.startsWith('X')
      ? int.tryParse(code.substring(1), radix: 16)
      : int.tryParse(code);
  if (point == null || point <= 0 || point > 0x10ffff) return match.group(0)!;
  return String.fromCharCode(point);
}

List<String> metadataUniqueStrings(Iterable<String?> values) {
  final Set<String> seen = <String>{};
  final List<String> result = <String>[];
  for (final String? value in values) {
    final String? normalized = metadataString(value);
    if (normalized != null && seen.add(normalized)) result.add(normalized);
  }
  return result;
}

final RegExp _latinLetter = RegExp(r'[A-Za-z]');
final RegExp _nonLatinScript =
    RegExp(r'[\u0400-\u04ff\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');

/// 标题是否是拉丁字母写成的（罗马音 / 英文等）：至少一个 A–Z，且不含假名、
/// 汉字、谚文、西里尔字母。`☆`、`:` 之类的符号不影响判断。
bool isLatinScriptTitle(String value) =>
    _latinLetter.hasMatch(value) && !_nonLatinScript.hasMatch(value);
