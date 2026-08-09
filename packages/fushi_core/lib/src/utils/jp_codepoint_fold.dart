/// 日文归一化**码点原语**（G7 去重）：全角 ASCII 折叠、片假名→平假名平移、
/// 半角片假名折叠查表。
///
/// 此前多套 normalizer——媒体库搜索 `normalizeMediaSearchText`、视频刮削
/// `TitleNormalizer`、有声书/阅读器匹配 `AudioTextNormalizer` 及其
/// `ReaderPaginationScripts` Dart 影子——各自手写同一批码点变换。本文件只收拢
/// **底层原语**；策略层（保留白名单 / 丢弃集 / 繁简映射 / 装饰符处理）是各
/// normalizer 的真实语义差异，仍留在各自实现里，不在此统一。
///
/// ⚠️ 这些变换参与搜索归一化与 sasayaki 匹配坐标系：任何输出变化都会改变既有
/// 匹配/高亮行为。改动必须保持逐码点输出不变（各 normalizer 既有测试 +
/// `fushi/test/utils/jp_codepoint_fold_test.dart` 的 JS parity 测试锁定）。
library;

/// 全角 ASCII（U+FF01..U+FF5E ！..～）→ 半角 ASCII（平移 -0xFEE0）；范围外
/// 码点原样返回。**不含**全角空格 U+3000——各策略对它语义不同（丢弃 / 转半角
/// 空格），由调用方自理。
int fullwidthAsciiToHalfwidth(int codePoint) {
  if (codePoint >= 0xFF01 && codePoint <= 0xFF5E) {
    return codePoint - 0xFEE0;
  }
  return codePoint;
}

/// 片假名基本区（U+30A1..U+30F6 ァ..ヶ）→ 平假名（平移 -0x60）；范围外原样
/// 返回。刻意**不含**长音符 ー(U+30FC) 与叠字符 ヽヾ——它们无平假名基本区对应。
int katakanaToHiragana(int codePoint) {
  if (codePoint >= 0x30A1 && codePoint <= 0x30F6) {
    return codePoint - 0x60;
  }
  return codePoint;
}

/// 半角片假名（U+FF66..U+FF9D ｦ..ﾝ）→ 全角片假名（查
/// [kHalfwidthKatakanaToFullwidth]）；范围外原样返回。**不含**半角浊点 ﾞ
/// (U+FF9E) / 半浊点 ﾟ(U+FF9F)，与既有各副本口径一致（不做浊音合成）。
int halfwidthKatakanaToFullwidth(int codePoint) {
  if (codePoint >= 0xFF66 && codePoint <= 0xFF9D) {
    return kHalfwidthKatakanaToFullwidth[codePoint - 0xFF66];
  }
  return codePoint;
}

/// 半角片假名 U+FF66..U+FF9D → 全角片假名查表（索引 = 码点 - 0xFF66，56 项）。
///
/// ⚠️ reader 注入 JS（`reader_pagination_scripts.dart` 的 `hwKataToFw`）持有
/// 同表的 JS 字符串副本（跨语言无法引用 Dart 常量），由
/// `fushi/test/utils/jp_codepoint_fold_test.dart` 的 parity 测试逐项锁定一致。
const List<int> kHalfwidthKatakanaToFullwidth = <int>[
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
