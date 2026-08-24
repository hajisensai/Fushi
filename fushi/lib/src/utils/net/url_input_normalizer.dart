/// 把用户手输/粘贴来的 URL 里的全角字符折回半角。
///
/// 为什么需要：中文/日文输入法在普通文本键盘下会把 URL 的结构字符转成全角
/// —— `:` → `：`、`/` → `／`、`.` → `。`。这些字符在 URL 里**没有任何合法用途**，
/// 出现即是输入法转换的产物，但 `Uri.tryParse` 对它们的处理是灾难性的：
///
/// | 输入 | 解析结果 |
/// |---|---|
/// | `https：//host/p`（全角冒号） | scheme 为空 → 整串变 path，无 authority |
/// | `https:／／host/p`（全角斜杠） | authority 为空 |
/// | `https://host．com/p`（全角句点） | authority = `host%EF%BC%8Ecom`，**不报错**，带着垃圾域名走到网络层 |
///
/// 前两种被校验拦成「地址无效」，第三种更糟——它会通过校验，最终报成一个与
/// 真实原因毫无关系的网络错误。所以归一化必须发生在**解析之前**，而不是解析
/// 失败后的补救。
///
/// 归一化范围刻意收窄到「在 URL 里必定是错误」的三类，不做通用全角→半角转换：
///
/// 1. 全角 ASCII 区 U+FF01–U+FF5E，与 U+0021–U+007E 一一对应（无损）。
/// 2. 表意句号 U+3002（`。`）→ `.`：拼音输入法句号键的产物，是实测中最常见的一个。
/// 3. 各种非 ASCII 空白（表意空格 U+3000、不换行空格 U+00A0 等）直接剔除。
///
/// **不碰** path/query 里的其他非 ASCII 字符：合法 URL 里的中文本该 percent-encode，
/// 而未编码的中文路径应当原样交给 `Uri` 去处理，不是这里的职责。
String normalizeUrlInput(String raw) {
  final StringBuffer buffer = StringBuffer();
  for (final int rune in raw.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      // 全角 ASCII 区与半角区偏移恒为 0xFEE0。
      buffer.writeCharCode(rune - 0xFEE0);
      continue;
    }
    if (rune == 0x3002) {
      buffer.write('.');
      continue;
    }
    if (_isNonAsciiWhitespace(rune)) continue;
    buffer.writeCharCode(rune);
  }
  return buffer.toString().trim();
}

/// ASCII 空白交给调用方的 `trim()`；这里只剔除 `trim()` 覆盖不到、
/// 又会让 `Uri.tryParse` 产出垃圾 authority 的非 ASCII 空白。
bool _isNonAsciiWhitespace(int rune) {
  return rune == 0x00A0 || // NO-BREAK SPACE
      rune == 0x3000 || // IDEOGRAPHIC SPACE
      rune == 0x200B || // ZERO WIDTH SPACE
      rune == 0xFEFF; // ZERO WIDTH NO-BREAK SPACE / BOM
}
