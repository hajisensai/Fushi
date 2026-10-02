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

// 句末/右括号类：页里一句台词结束后紧跟的字符。只用于句段边界判定。
// 读点也算：KAG 在「、」处 [r] 换行把一句拆成两条文本事件（Fate「この身を貫こうと
// する稲妻は、」+「この身を救おうとする月光に弾かれた。」），而渲染行把各行字形直接
// 拼起来、中间没有任何空白。
inline bool IsLookupSentenceCloser(wchar_t c) {
  switch (c) {
    case L'、': case L'，': case L',':
    case L'。': case L'．': case L'.': case L'！': case L'？': case L'!':
    case L'?': case L'」': case L'』': case L'）': case L')': case L'】':
    case L'…': case L'―': case L'〜': case L'~': case L'♪':
      return true;
    default:
      return false;
  }
}

// 左括号类：下一句台词可能以它开头（「台詞」紧跟上一句）。
inline bool IsLookupSentenceOpener(wchar_t c) {
  return c == L'「' || c == L'『' || c == L'（' || c == L'(' || c == L'【';
}

// 渲染面的一「行」是整页（NVL / KAG 消息层逐句累积，一页多句），文本道里是一句一条：
// 在 page 里找 sentence 的一次出现，要求它覆盖 char_index，并落在句界上。命中时
// [*seg_begin, *seg_end) 是 page 中这句的范围（首尾不含空白），返回 true。
//
// 与上面「放宽成包含会绑错行」的告诫方向相反：那里是「文本道行包含渲染行」（译文紧跟
// 原文），这里是「渲染页包含文本道句」，且必须覆盖被点的字、落在句界上——页内别处
// 碰巧出现的短句（「はい」嵌在「はいはい」里）因此不会被当成这一句。整句相等仍应
// 先用 LookupLineTextMatches 判，这里只在它不命中时补位。
inline bool LookupPageSentenceCovering(const wchar_t* page, size_t page_len,
                                       const wchar_t* sentence,
                                       size_t sentence_len, size_t char_index,
                                       size_t* seg_begin, size_t* seg_end) {
  if (page == nullptr || sentence == nullptr || char_index >= page_len) {
    return false;
  }
  size_t first = 0;
  while (first < sentence_len && IsLookupLineWhitespace(sentence[first])) {
    ++first;
  }
  if (first >= sentence_len) return false;
  for (size_t s = 0; s <= char_index; ++s) {
    if (page[s] != sentence[first]) continue;
    if (s > 0 && !IsLookupLineWhitespace(page[s - 1]) &&
        !IsLookupSentenceCloser(page[s - 1])) {
      continue;
    }
    size_t i = s;
    size_t j = first;
    size_t last = s;
    for (;;) {
      while (i < page_len && IsLookupLineWhitespace(page[i])) ++i;
      while (j < sentence_len && IsLookupLineWhitespace(sentence[j])) ++j;
      if (j >= sentence_len || i >= page_len || page[i] != sentence[j]) break;
      last = i;
      ++i;
      ++j;
    }
    if (j < sentence_len) continue;
    const size_t end = last + 1;
    if (char_index >= end) continue;
    if (end < page_len && !IsLookupLineWhitespace(page[end]) &&
        !IsLookupSentenceCloser(page[last]) &&
        !IsLookupSentenceOpener(page[end])) {
      continue;
    }
    if (seg_begin != nullptr) *seg_begin = s;
    if (seg_end != nullptr) *seg_end = end;
    return true;
  }
  return false;
}

}  // namespace fushi_voice_hook
