/// 日文正文归一化工具。
///
/// 白名单规则：只保留假名/汉字/CJK 扩展/字母数字，其余剥掉。
/// `audiobook_bridge.dart` 的 JS `__hoshiIsSkippable` 必须与此严格镜像。
class AudioTextNormalizer {
  AudioTextNormalizer._();

  /// 归一化文本：剥掉非白名单字符，大小写统一，片假名转平假名。
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
      int out = cp;
      if (cp >= 0x41 && cp <= 0x5A) {
        out = cp + 0x20; // ASCII A-Z → a-z
      } else if (cp >= 0xFF21 && cp <= 0xFF3A) {
        out = cp - 0xFEC0; // 全角 Ａ-Ｚ → ASCII a-z
      } else if (cp >= 0xFF41 && cp <= 0xFF5A) {
        out = cp - 0xFEE0; // 全角 ａ-ｚ → ASCII a-z
      } else if (cp >= 0xFF10 && cp <= 0xFF19) {
        out = cp - 0xFEE0; // 全角 ０-９ → ASCII 0-9
      } else if (cp >= 0xFF66 && cp <= 0xFF9D) {
        out = _hwKataToFw[cp - 0xFF66]; // 半角片假名 → 全角片假名
      }
      // 片假名 → 平假名 (ァ-ヶ → ぁ-ゖ)
      if (out >= 0x30A1 && out <= 0x30F6) {
        out -= 0x60;
      }
      buf.writeCharCode(out);
    }
  }

  // 半角片假名 (U+FF66..U+FF9D) → 全角片假名 查找表
  static const List<int> _hwKataToFw = <int>[
    0x30F2, // ｦ → ヲ
    0x30A1, // ｧ → ァ
    0x30A3, // ｨ → ィ
    0x30A5, // ｩ → ゥ
    0x30A7, // ｪ → ェ
    0x30A9, // ｫ → ォ
    0x30E3, // ｬ → ャ
    0x30E5, // ｭ → ュ
    0x30E7, // ｮ → ョ
    0x30C3, // ｯ → ッ
    0x30FC, // ｰ → ー
    0x30A2, // ｱ → ア
    0x30A4, // ｲ → イ
    0x30A6, // ｳ → ウ
    0x30A8, // ｴ → エ
    0x30AA, // ｵ → オ
    0x30AB, // ｶ → カ
    0x30AD, // ｷ → キ
    0x30AF, // ｸ → ク
    0x30B1, // ｹ → ケ
    0x30B3, // ｺ → コ
    0x30B5, // ｻ → サ
    0x30B7, // ｼ → シ
    0x30B9, // ｽ → ス
    0x30BB, // ｾ → セ
    0x30BD, // ｿ → ソ
    0x30BF, // ﾀ → タ
    0x30C1, // ﾁ → チ
    0x30C4, // ﾂ → ツ
    0x30C6, // ﾃ → テ
    0x30C8, // ﾄ → ト
    0x30CA, // ﾅ → ナ
    0x30CB, // ﾆ → ニ
    0x30CC, // ﾇ → ヌ
    0x30CD, // ﾈ → ネ
    0x30CE, // ﾉ → ノ
    0x30CF, // ﾊ → ハ
    0x30D2, // ﾋ → ヒ
    0x30D5, // ﾌ → フ
    0x30D8, // ﾍ → ヘ
    0x30DB, // ﾎ → ホ
    0x30DE, // ﾏ → マ
    0x30DF, // ﾐ → ミ
    0x30E0, // ﾑ → ム
    0x30E1, // ﾒ → メ
    0x30E2, // ﾓ → モ
    0x30E4, // ﾔ → ヤ
    0x30E6, // ﾕ → ユ
    0x30E8, // ﾖ → ヨ
    0x30E9, // ﾗ → ラ
    0x30EA, // ﾘ → リ
    0x30EB, // ﾙ → ル
    0x30EC, // ﾚ → レ
    0x30ED, // ﾛ → ロ
    0x30EF, // ﾜ → ワ
    0x30F3, // ﾝ → ン
  ];

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
