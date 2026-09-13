/// 搜索查询的**书写系统**判据，供公共索引器与 Nyaa 共用。
///
/// 这里只回答一个问题：**这条查询里有没有拉丁字母内容**。它不判断语言（本仓没有
/// 全局学习语言，别假设日语），也不枚举「哪些区段算 CJK」——后者是一条走不通的路：
/// 半角片假名 `ｦ-ﾟ`、Hangul 兼容字母 `㄰-㆏`、Jamo
/// `ᄀ-ᇿ` 都曾漏在区段外，而西里尔 / 希腊 / 泰文 / 阿拉伯文又会被
/// 「非拉丁 = 不可搜」的反向假设误伤。**正向判「有没有拉丁词」没有这些洞。**
library;

final RegExp _latinWord = RegExp(r'[A-Za-z]{2,}');
final RegExp _nonAscii = RegExp(r'[^\x00-\x7F]');

/// 全角 ASCII（`！`..`～`，U+FF01..U+FF5E）折回半角，外加全角空格。
///
/// `第２期` 与 `第2期` 必须归一成同一条，否则「这条查询等于媒体自己的标题吗」
/// 这个判据会因为用户从别处粘来全角数字而失配。
String foldFullWidthAscii(String value) {
  final StringBuffer out = StringBuffer();
  for (final int rune in value.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      out.write(' ');
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// 查询里是否有拉丁字母词（连续 2 个以上 ASCII 字母）。
///
/// 单个字母不算词：`第2期` 里的 `2`、`Re:` 之外的孤立字母都不足以让只索引拉丁
/// 标题的站点匹配到东西。
bool hasLatinWord(String value) => _latinWord.hasMatch(foldFullWidthAscii(value));

/// 整条查询是否纯 ASCII（`2012`、`300`、`9` 这类全数字/符号标题）。
bool isPureAscii(String value) => !_nonAscii.hasMatch(foldFullWidthAscii(value));

/// 只索引拉丁字母标题的站点能不能表达这条查询。
///
/// 判据是「有拉丁词，**或者**整条就是 ASCII」：
/// * `Fate/stay night 劇場版` → 有 `Fate`/`stay`/`night`，能表达（混排不该被拦，
///   最坏是结果少，不是结果错）。
/// * `薬屋のひとりごと 第2期` → 没有拉丁词、也不是纯 ASCII，不能表达。这正是
///   apibay 会退化成热门榜的形状（BUG-1985）。
/// * `2012` → 纯 ASCII，能表达。按「有没有拉丁词」单条判会把这类合法标题误杀。
/// * `ﾎﾟｹﾓﾝ` / `Ведьмак` / 韩文 → 不能表达。区段枚举法漏掉前两者，这里不会。
bool isLatinScriptExpressible(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  return hasLatinWord(trimmed) || isPureAscii(trimmed);
}
