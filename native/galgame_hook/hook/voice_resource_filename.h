#pragma once

#include <cstdint>
#include <string>

namespace hibiki_voice_hook {

// Resource dumps without a proven engine-level text association keep the
// legacy "<tick>_<basename>" shape.  A profile may opt into a stable text
// event id only when its runtime contract proves that a committed selected
// TextSlot belongs to that resource observation.
inline std::wstring BuildVoiceResourceFileName(uint64_t tick_ms,
                                               const std::wstring& basename,
                                               uint64_t text_event_id = 0) {
  std::wstring name = std::to_wstring(tick_ms) + L"_";
  if (text_event_id != 0) {
    name += L"hibiki_textseq" + std::to_wstring(text_event_id) + L"_";
  }
  name += basename;
  return name;
}

}  // namespace hibiki_voice_hook
