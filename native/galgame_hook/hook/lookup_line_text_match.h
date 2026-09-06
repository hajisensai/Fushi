// 查词命中的整句（引擎渲染面读出）与文本道里的行（LunaHook 抓到的字符串）是否是同一句。
//
// 用途：把点击载荷的 text_generation 填成该句在文本道里的 TextSlot.seq（host 按它解析
// 制卡 occurrence，BUG-2085 家族）。两侧字符串来源不同，允许的差异只有空白：渐进渲染
// 会补全角空格，Luna 侧可能带换行。除此之外一律要求逐字相等——放宽成包含/前缀会把
// 「同句被翻译行紧跟」的多语言引擎（KiriKiri Z 官方多语言版）绑到错的行。
#pragma once

#include <cstddef>

namespace fushi_voice_hook {

inline bool IsLookupLineWhitespace(wchar_t c) {
  return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n' || c == 0x3000;
}

// 忽略空白后逐字相等。任一侧为空（全空白）返回 false：空句不是身份。
inline bool LookupLineTextMatches(const wchar_t* a, size_t a_len,
                                  const wchar_t* b, size_t b_len) {
  if (a == nullptr || b == nullptr) return false;
  size_t i = 0;
  size_t j = 0;
  bool any = false;
  for (;;) {
    while (i < a_len && IsLookupLineWhitespace(a[i])) ++i;
    while (j < b_len && IsLookupLineWhitespace(b[j])) ++j;
    const bool a_done = i >= a_len;
    const bool b_done = j >= b_len;
    if (a_done || b_done) return a_done && b_done && any;
    if (a[i] != b[j]) return false;
    any = true;
    ++i;
    ++j;
  }
}

}  // namespace fushi_voice_hook
