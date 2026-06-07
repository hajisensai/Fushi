/// 剪贴板去重：trim 后为空或与 [last] 相同返回 null（不触发查词），
/// 否则返回 trim 后的新文本。避免挖词/复制写回剪贴板时自触发循环。
String? dedupeClipboard(String raw, String? last) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed == last) return null;
  return trimmed;
}
