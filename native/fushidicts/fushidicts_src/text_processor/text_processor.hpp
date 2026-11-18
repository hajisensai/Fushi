#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

/// 一个查询变体。[min_rewrite] / [max_rewrite] 约束拿它做变形还原时**允许改写的尾部
/// 码点数**（上游 hoshidicts ad0be91）：还原形与变体逐字节比，从第一个不同处到变体
/// 末尾的码点数记为改写量（只在尾部追加不算改写，见 lookup.cpp rewritten_chars）。
///  - 改写量 > max_rewrite 的还原丢弃：原文里的中点 / 被折叠掉的っ 这一处不许被变形
///    跨过——「行・った」删点成「行った」后不得经「った → く」还原成 行く（改写 2 个
///    码点，越过了点）；只改写点右边的部分照常允许（見・た → 見た → 見る 改写 1 个）。
///    原文本身含中点时同样受限（变体「見・た」也只许改写 1 个码点）。
///  - 0 < 改写量 < min_rewrite 的还原丢弃：原文以「平假名 + 片假名词」收尾时，变形
///    要么不动片假名词，要么把整段片假名一起改写（行きマス → 行く 可以，只改写片假名
///    词末尾一两个字不行）。
struct TextVariant {
  std::string text;
  int steps;
  std::size_t min_rewrite = 0;
  std::size_t max_rewrite = SIZE_MAX;
};

namespace text_processor {
/// [chinese_simp_to_trad]：这次查词按中文处理时才置 true，额外产出另一种字形的拼写，
/// **双向**：简体 → 繁體（OpenCC STCharacters 全部候选 + 台/港字形，见
/// simplified_to_traditional_variants）让按繁體建索引的词典命中简体查询；繁體 → 简体
/// （OpenCC TSCharacters 全部候选，见 traditional_to_simplified_variants）让按简体建
/// 索引的词典命中繁體查询（之間 → 之间）。原形变体照常保留，另一种字形是额外的变体，
/// 所以「我们」能命中更长的「我們」，而不是只在原文零结果时才回落。默认 false：非中文
/// （日语的汉字大量有简体 / 繁體形）查询的变体集与耗时都与此前逐字节一致。
/// （字段名沿用历史的 simp_to_trad，语义已是双向。）
///
/// [next_char]：原文里紧跟在 [src] 后面的那个码点（扫描窗口外或串尾传 0）。[src] 以
/// 「平假名 + 片假名词」收尾、而 [next_char] 还在这个片假名词里（片假名或长音符）时，
/// [src] 的结尾落在一个片假名词的中间：只返回原文一个变体、且不许变形还原
/// （max_rewrite = 0），即只认词典里正好这么写的词条——「はテスト」不会在「はテ」
/// 处经平假名化命中「果て」（上游 hoshidicts ad0be91）。
std::vector<TextVariant> process(const std::string& src, bool chinese_simp_to_trad = false,
                                 char32_t next_char = 0);

/// 一次中文查词每个文本变体最多展开的繁體拼写数。
inline constexpr std::size_t kMaxChineseTraditionalVariants = 16;

/// 一次中文查词每个文本变体最多展开的简体拼写数。
inline constexpr std::size_t kMaxChineseSimplifiedVariants = 16;

/// 简体 → 繁體的全部拼写（逐字取 OpenCC 候选做组合，一简多繁全展开：头发 →
/// 頭發 / 頭髮；按候选序号和从小到大截到 [max_variants] 个，首选项组合排第一）。
/// 不含与 [text] 相同的那一个；不含表内字符时返回空、不分配。单独导出供测试断言。
std::vector<std::u32string> simplified_to_traditional_variants(
    const std::u32string& text, std::size_t max_variants = kMaxChineseTraditionalVariants);

/// 繁體 → 简体的全部拼写（逐字取 OpenCC TSCharacters 候选做组合：乾燥 → 干燥 / 乾燥
/// 原形除外；之間 → 之间；按候选序号和从小到大截到 [max_variants] 个，首选项组合排
/// 第一）。不含与 [text] 相同的那一个；不含表内字符时返回空、不分配。单独导出供测试。
std::vector<std::u32string> traditional_to_simplified_variants(
    const std::u32string& text, std::size_t max_variants = kMaxChineseSimplifiedVariants);

/// 谚文预合成音节 → Hangul 兼容字母序列（复合字母拆到简单字母：ㅘ → ㅗㅏ，
/// ㄺ → ㄹㄱ）。非谚文字符原样透传。ko.json 的 transform 表就写在这个字母域里，
/// 不拆字则韩语词形还原一条都匹配不上（BUG-2148）。已在 [process] 里注册为一个
/// 预处理器；单独导出是为了给 [reassemble_hangul] 做往返测试。
std::u32string disassemble_hangul(const std::u32string& text);

/// 兼容字母序列 → 预合成音节。词形还原在字母域里做完之后必须拼回音节，否则查不到
/// 词典索引（索引键是预合成的）——这就是 Yomitan `textPostprocessors` 那一段。
/// 非谚文字符与拼不成音节的散字母原样透传。
///
/// 在**完整音节**上是 [disassemble_hangul] 的逆（11172 个音节单字与混排语料实测
/// 往返无损），但不是它在任意输入上的逆：独立的复合字母没有初声打头，
/// `disassemble("ㅘ") == "ㅗㅏ"` 而 `reassemble("ㅗㅏ") == "ㅗㅏ"`（原样透传）。
/// 这不丢结果——查询链里未拆字的原形变体照样精确命中词典里的 `ㅘ` 条目。
std::u32string reassemble_hangul(const std::u32string& text);

/// UTF-8 版 [reassemble_hangul]，带字节级前置判据：串里没有兼容字母时**原样返回，
/// 一次编码转换都不做**。查询侧对每个还原形都要调它，而一次日语查词的还原形是
/// 几十上百个——无条件做 utf8↔utf32 往返是白烧 CPU（弹窗慢有前科，BUG-1868）。
std::string reassemble_hangul_utf8(const std::string& text);
}
