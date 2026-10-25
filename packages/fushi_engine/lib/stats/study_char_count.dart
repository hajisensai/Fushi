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
/// 2. **每码点计 1**——\p{L} 或 \p{N}，且属于不用空格分词的文字（汉字 / 假名 /
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
/// ## 实现在哪
///
/// 分类表与计数循环只有一份，在 Rust（`native/fushi_compute/src/parse.rs`，表由
/// `native/fushi_compute/tool/gen_study_char_table.dart` 按上面四条规则生成）。这里
/// 只是 FFI 外壳，**没有 Dart 回退**：原生库缺失时 [countStudyChars] 抛 `FushiComputeUnavailableError`。
/// 原 Dart 实现逐码点 `String.fromCharCode` + 三次 Unicode 属性正则，十几万字的一本
/// 书光数字就要数百毫秒到数秒，比 `package:html` 建 DOM 还慢一个量级。
///
/// ## 计数口径版本
///
/// 改动分类规则（即重新生成上述表）**必须**同步 +1 `kChapterCharCountCaliber`
/// （`package:fushi_engine/epub/epub_book.dart`），否则按旧口径算好的每章缓存永不重算。
/// 阅读器 WebView 侧有一份等价的 JS 实现（`reader_pagination_scripts.dart` 的
/// `countChars`），两份由 `fushi/test/stats/study_char_count_parity_test.dart` 逐样本
/// 对拍钉死。
library;

import 'package:fushi_compute/fushi_compute.dart' show StudyCharsNative;

/// 码点的字数分类（与 Rust `StudyCharClass` 同序同值）。
enum StudyCharClass {
  /// 断词且不计：标点 / 括号 / 空白 / 符号 / 未分配。
  breaker,

  /// 透明：组合记号、ZWNJ / ZWJ、词内撇号——不计数也不断词。
  transparent,

  /// 每码点计 1：\p{L}/\p{N} 且属于不用空格分词的文字（汉字 / 假名 / 谚文…）。
  perCodePoint,

  /// 连续串计 1：其余 \p{L}/\p{N}（拉丁 / 西里尔 / 阿拉伯…）。
  word,
}

/// 码点 [rune] 的字数分类（孤立代理、越界值一律 [StudyCharClass.breaker]）。
StudyCharClass studyCharClassOf(int rune) =>
    StudyCharClass.values[StudyCharsNative.instance.classOf(rune)];

/// 一段文本的学习单位数。纯函数；口径见库注释。
int countStudyChars(String text) => (StudyCharCounter()..add(text)).count;

/// [countStudyChars] 的可续算版本：按顺序 [add] 多段文本，[count] 恒等于
/// `countStudyChars(所有段拼接)`。
///
/// 存在的理由是连续词串（拉丁等）跨段：逐段 `countStudyChars` 再相加，会把
/// `<p>abc</p><p>def</p>`（标签之间没有空白）数成 2，而拼接后数是 1——DOM
/// 遍历里「逐文本节点计数再相加」与「拼接前文再计数」（阅读器回报的位置、目录
/// 锚点偏移都是后者）因此不在同一把尺子上。需要在遍历中途读偏移的地方用它。
class StudyCharCounter {
  int _count = 0;
  bool _inWord = false;

  /// 接着已加入的文本继续计数（词串可以跨段延续）。码点按 `String.runes` 解码：
  /// 跨两次 [add] 的代理对按两个孤立代理处理（与逐段解码一致）。
  void add(String text) {
    if (text.isEmpty) return;
    final ({int count, bool inWord}) next = StudyCharsNative.instance.add(
      text,
      _count,
      _inWord,
    );
    _count = next.count;
    _inWord = next.inWord;
  }

  /// 目前为止的学习单位数（未收尾的词串按 1 计，与 [countStudyChars] 结尾一致）。
  int get count => _count + (_inWord ? 1 : 0);
}

/// [text] 里多个位置（UTF-16 偏移，升序、不超过 `text.length`）的学习单位前缀数，一次
/// FFI 算完：第 i 个结果 = `countStudyChars(text.substring(0, offsets[i]))`。给「一章里
/// 所有句子的起止」换算成阅读器锚点（`charAnchor`）用，不逐句跨 FFI。
List<int> studyCharPrefixTotals(String text, List<int> offsets) =>
    StudyCharsNative.instance.prefixTotals(text, offsets);
