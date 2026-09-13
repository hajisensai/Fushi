#pragma once

#include <windows.h>
#include "cmvs_dialogue_layout_reader.h"
#include "../lookup_line_text_match.h"

namespace fushi_voice_hook::cmvs_layout {

inline constexpr uint16_t kNoSourceIndex = 0xffff;
struct TextIdentity {
  std::array<wchar_t, kMaxGlyphs> rendered{};
  std::array<uint16_t, kMaxGlyphs> source_indices{};
  size_t count = 0;
};

// Decode exactly one CP932 glyph. Invalid/undefined codes never silently
// substitute '?' or U+FFFD and then match a different selected source.
inline bool DecodeGlyph(uint16_t code, wchar_t* decoded) {
  if (decoded == nullptr || !IsCp932Code(code)) return false;
  const char bytes[] = {static_cast<char>(code >> 8), static_cast<char>(code)};
  const int size = code > 0xff ? 2 : 1;
  wchar_t value = 0;
  if (MultiByteToWideChar(932, MB_ERR_INVALID_CHARS,
                         bytes + (size == 1 ? 1 : 0), size, &value, 1) != 1 ||
      value == 0xfffd || (value >= 0xd800 && value <= 0xdfff)) return false;
  *decoded = value;
  return true;
}

// Selected-lane identity and index mapping only. This does not choose a lane,
// use prefix/substring matches, or establish a frame/visibility generation.
// Whitespace normalization follows the existing lookup line contract, while
// each non-whitespace glyph retains its index in the *selected* UTF-16 source.
inline bool ResolveSelectedText(const Snapshot& snapshot,
                                const wchar_t* selected, size_t selected_count,
                                TextIdentity* output) {
  if (output == nullptr) return false;
  *output = {};
  if (selected == nullptr || selected_count == 0 ||
      selected_count > kMaxGlyphs || snapshot.count == 0 ||
      snapshot.count > kMaxGlyphs) return false;
  TextIdentity candidate{};
  candidate.source_indices.fill(kNoSourceIndex);
  size_t source = 0;
  bool any = false;
  for (size_t i = 0; i < snapshot.count; ++i) {
    wchar_t decoded = 0;
    if (!DecodeGlyph(snapshot.glyphs[i].cp932, &decoded)) return false;
    candidate.rendered[i] = decoded;
    if (IsLookupLineWhitespace(decoded)) continue;
    while (source < selected_count && IsLookupLineWhitespace(selected[source]))
      ++source;
    if (source == selected_count || selected[source] != decoded) return false;
    candidate.source_indices[i] = static_cast<uint16_t>(source++);
    any = true;
  }
  while (source < selected_count && IsLookupLineWhitespace(selected[source]))
    ++source;
  if (!any || source != selected_count) return false;
  candidate.count = snapshot.count;
  *output = candidate;
  return true;
}

}  // namespace fushi_voice_hook::cmvs_layout
