#pragma once

#include <cstddef>
#include <string>
#include <vector>

struct TextVariant {
  std::string text;
  int steps;
};

namespace text_processor {
/// [chinese_simp_to_trad]：查询语言为中文时才置 true，额外产出「简体 → 繁體」拼写
/// （OpenCC STCharacters 全部候选 + 台/港字形，见 simplified_to_traditional_variants），
/// 让按繁體建索引的词典也能命中简体查询。原形变体照常保留，繁體是额外的变体，所以
/// 「我们」能命中更长的「我們」，而不是只在原文零结果时才回落。默认 false：非中文
/// （日语的汉字大量有简体形）查询的变体集与耗时都与此前逐字节一致。
std::vector<TextVariant> process(const std::string& src, bool chinese_simp_to_trad = false);

/// 一次中文查词每个文本变体最多展开的繁體拼写数。
inline constexpr std::size_t kMaxChineseTraditionalVariants = 16;

/// 简体 → 繁體的全部拼写（逐字取 OpenCC 候选做组合，一简多繁全展开：头发 →
/// 頭發 / 頭髮；按候选序号和从小到大截到 [max_variants] 个，首选项组合排第一）。
/// 不含与 [text] 相同的那一个；不含表内字符时返回空、不分配。单独导出供测试断言。
std::vector<std::u32string> simplified_to_traditional_variants(
    const std::u32string& text, std::size_t max_variants = kMaxChineseTraditionalVariants);

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
