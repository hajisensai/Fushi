/// 日文正文归一化工具。
///
/// 白名单规则：只保留假名/汉字/CJK 扩展/字母数字，其余剥掉。
/// `audiobook_bridge.dart` 的 JS `__hoshiIsSkippable` 必须与此严格镜像。
class AudioTextNormalizer {
  AudioTextNormalizer._();

  /// 归一化文本：剥掉非白名单字符，全角/ASCII 大写转小写。
  static String normalize(String s) {
    final StringBuffer buf = StringBuffer();
    appendNormalized(buf, s);
    return buf.toString();
  }

  /// 将 [s] 归一化后追加到 [buf]，用于拼接多段文本后统一处理。
  static void appendNormalized(StringBuffer buf, String s) {
    for (final int cp in s.runes) {
      if (!_isKeepable(cp)) {
        continue;
      }
      if (cp >= 0x41 && cp <= 0x5A) {
        buf.writeCharCode(cp + 0x20);
      } else if (cp >= 0xFF21 && cp <= 0xFF3A) {
        buf.writeCharCode(cp + 0x20);
      } else {
        buf.writeCharCode(cp);
      }
    }
  }

  static bool _isKeepable(int c) {
    return (c >= 0x30 && c <= 0x39) || // 0-9
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        c == 0x3005 ||
        c == 0x3006 ||
        c == 0x3007 || // 々〆〇
        (c >= 0x3041 && c <= 0x3096) || // ひらがな
        (c >= 0x309D && c <= 0x309F) || // ゝゞゟ
        (c >= 0x30A1 && c <= 0x30FA) || // カタカナ
        (c >= 0x30FC && c <= 0x30FF) || // ーヽヾヿ
        (c >= 0x3400 && c <= 0x4DBF) || // CJK 拡張 A
        (c >= 0x4E00 && c <= 0x9FFF) || // CJK 統合漢字
        c == 0x25CB ||
        c == 0x25EF || // ○◯
        c == 0x303B || // 〻
        (c >= 0x2E80 && c <= 0x2EFF) || // CJK 部首補助
        (c >= 0x2F00 && c <= 0x2FDF) || // 康煕部首
        (c >= 0xF900 && c <= 0xFAFF) || // CJK 互換漢字
        (c >= 0x20000 && c <= 0x2A6DF) || // CJK 拡張 B
        (c >= 0x2A700 && c <= 0x2EBE0) || // CJK 拡張 C-F
        (c >= 0x2F800 && c <= 0x2FA1F) || // CJK 互換漢字補助
        (c >= 0x30000 && c <= 0x323AF) || // CJK 拡張 G-H
        (c >= 0xFF10 && c <= 0xFF19) || // ０-９
        (c >= 0xFF21 && c <= 0xFF3A) || // Ａ-Ｚ
        (c >= 0xFF41 && c <= 0xFF5A) || // ａ-ｚ
        (c >= 0xFF66 && c <= 0xFF9D); // 半角カタカナ
  }
}
