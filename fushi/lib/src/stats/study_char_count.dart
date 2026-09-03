/// 学习统计「字数」的**唯一**计数口径。
///
/// ## 为什么需要一个统一口径
///
/// 在此之前仓库里有三套互不相同的字数：EPUB / 漫画走 `japaneseCharCount` 的 ttu
/// 白名单逐码点计数、视频字幕走裸 `String.runes.length`、galgame hook 走
/// `countGalgameChars` 的混合口径。三个数落进同一列 `study_segments.chars`、同一
/// 张图表、同一个每日目标里相加，本身就不成立；而 ttu 白名单对非日语内容更是错的：
///
/// - 英语按**字母**计，数字虚高约 5 倍（"I don't know" 记 10 而不是 3）；
/// - 带变音的拉丁字母不在白名单，`café` 只记 3；
/// - 俄 / 韩 / 希腊 / 阿拉伯 / 希伯来 / 泰 / 天城文**整个脚本记 0**——连带
///   `computeBookProgress` 分母为 0、章内进度退化成「章号 / 章数」，每日目标分子恒 0。
///
/// ## 口径
///
/// 对齐 LunaTranslator `count_words_mixed` 与 exSTATic `charsInLine`（本仓 galgame
/// 路径 2026-04 起已用这套），一句话：**按该文字自己的分词方式计一个「学习单位」**。
///
/// 逐码点扫描，四类：
///
/// 1. **透明**——组合记号 \p{M}（阿拉伯 harakat、天城文 matra）、ZWJ / ZWNJ、
///    词内撇号。既不计数也不断词。撇号透明即可让 `don't` 记 1 个词；
///    `rock 'n' roll` 仍是 3（断词由两侧空白负责，不靠撇号）。
/// 2. **每码点计 1**——\p{L} 或 \p{N}，且属于 [kNoSpaceScripts]（汉字 / 假名 /
///    谚文 / 泰 / 老挝 / 高棉 / 缅甸 / 藏 / 注音 / 彝）。
/// 3. **连续串计 1**——其余 \p{L} / \p{N}（拉丁、希腊、西里尔、阿拉伯、希伯来、
///    天城文、亚美尼亚、格鲁吉亚…）。一串连续的字母数字算一个词。
/// 4. **断词且不计**——其余一切：标点、括号、空白、符号。
///
/// **判定顺序不可交换**：先看脚本再看类别。`〇`(U+3007) 是 \p{N} 但 Script
/// Extensions 是 Han，先看类别会把它当西文数字并进词串；`。`(U+3002) 的 Script
/// Extensions 同样含 Han，但它既非 \p{L} 也非 \p{N}，所以两个条件必须同时成立
/// 才算「每码点计 1」，否则标点会被计进去。
///
/// ## 与查词分词的关系
///
/// 这里的「空格分词脚本」判据与 `native/fushidicts/fushidicts_src/scan/word_scan.cpp`
/// 的 `is_space_delimited_letter` **不是同一张表，也不该是**：那边回答的是「查词候选
/// 该在哪切」，谚文在那边按码点切（어절 含助词，必须能切进去）；这里回答的是「读了
/// 多少个学习单位」，谚文按码点计（沿用 galgame 路径的既有口径，不改动已有数字）。
/// 两个问题不同，答案允许不同，但各自只有一份实现。
///
/// ## 计数口径版本
///
/// 改动本文件的分类规则**必须**同步 +1 `kChapterCharCountCaliber`
/// （`package:fushi/src/epub/epub_book.dart`），否则按旧口径算好的每章缓存永不重算。
/// 阅读器 WebView 侧有一份等价的 JS 实现（`reader_pagination_scripts.dart` 的
/// `countChars`），两份由 `fushi/test/stats/study_char_count_parity_test.dart` 逐样本
/// 对拍钉死。
library;

/// 不用空格分词的文字：这些脚本里一个码点就是一个学习单位。
///
/// 其余带 \p{L} 的文字一律按空格分词处理——世界上绝大多数文字用空格分词，把
/// 例外列成白名单比反过来更短，也让未列出的新文字落到更可能正确的那一侧。
const List<String> kNoSpaceScripts = <String>[
  'Han',
  'Hiragana',
  'Katakana',
  'Hangul',
  'Bopomofo',
  'Yi',
  'Thai',
  'Lao',
  'Khmer',
  'Myanmar',
  'Tibetan',
];

/// 组合记号 / 零宽连接符 / 词内撇号：既不计数也不断词。
///
/// 撇号必须透明，否则 `don't` 会被拆成 don + t 记 2 个词。它不需要「两侧都是字母」
/// 那种上下文判据（取词扫描才需要，见 BUG-2056）——这里断词由真正的分隔符负责，
/// 一个不断词也不计数的字符放在词首 / 词尾都不会改变结果。
final RegExp kStudyTransparentPattern =
    RegExp(r"[\p{M}\u200C\u200D'\u2019\u02BC]", unicode: true);

/// \p{L} 或 \p{N}：够格成为学习单位的码点（标点 / 符号 / 空白都不是）。
final RegExp kStudyLetterOrNumberPattern =
    RegExp(r'[\p{L}\p{N}]', unicode: true);

/// 属于 [kNoSpaceScripts] 之一。用 Script **Extensions** 而不是 Script：长音符
/// `ー`(U+30FC) 与迭代符 `々`(U+3005) 的 Script 是 Common，只有 Script Extensions
/// 才把它们归到假名 / 汉字；半角片假名同理。
final RegExp kStudyNoSpaceScriptPattern =
    RegExp('[${kNoSpaceScripts.map(_scriptClass).join()}]', unicode: true);

/// 单个脚本的 Unicode 属性转义前缀（raw 字面量，避免在字符串里再转义反斜杠）。
const String _kScriptExtensionsPrefix = r'\p{Script_Extensions=';

String _scriptClass(String script) => '$_kScriptExtensionsPrefix$script}';

/// 一段文本的学习单位数。纯函数；口径见库注释。
int countStudyChars(String text) {
  int count = 0;
  bool inWord = false;
  for (final int rune in text.runes) {
    final String char = String.fromCharCode(rune);
    if (kStudyTransparentPattern.hasMatch(char)) {
      continue; // 不计数、不断词
    }
    if (kStudyLetterOrNumberPattern.hasMatch(char)) {
      if (kStudyNoSpaceScriptPattern.hasMatch(char)) {
        if (inWord) {
          count++;
          inWord = false;
        }
        count++;
      } else {
        inWord = true;
      }
      continue;
    }
    if (inWord) {
      count++;
      inWord = false;
    }
  }
  if (inWord) count++;
  return count;
}
