#pragma once

#include <cstdint>

namespace fushi {

// 「还原链里用过要求词性的规则」标记位，挂在 DeinflectionResult::conditions 的最高位。
//
// transforms JSON 的规则可以带 `"requiresPartOfSpeech": true`：经它得到的还原形只对
// **自带词性且匹配**的词条成立，词性通配（`rules = "*"`：MDX / StarDict / DSL 与整本
// 不带 rules 的 Yomitan 词典，见 Deinflector::pos_to_conditions）的词条不接受。用于
// 歴史的仮名遣い这类罕见正字法的短规则（`へ → う`、`はない → う`、`ふ → う`）：它们的
// 词尾正是现代文最高频的助词「へ / は」，在通配词典上几乎只会造出误配（うちへ → 宇宙
// 〔うちう〕）。
//
// 不是词性条件：Deinflector 只在载入时把它或进带标记规则的 conditions_out，递归时沿
// 链传下去（判 conditions_in 时先去掉它）；Lookup::filter_by_pos 见到它就只按词条自带
// 的真词性做匹配、通配 "*" 不算数（一条词条的 rules 是各词典并起来的，可以同时有真词性
// 和 "*"：有真词性且匹配就成立）。各语言的条件位从 0 往上分配（最多用到二十几位），
// 最高位留给它。
inline constexpr int kRequiresPartOfSpeechBitIndex = 63;
inline constexpr uint64_t kRequiresPartOfSpeechBit = uint64_t{1} << kRequiresPartOfSpeechBitIndex;

}  // namespace fushi
