#pragma once
#include "voice_hook_ipc.h"
#include <array>
#include <string>

namespace fushi_voice_hook {
inline bool SelectedLookupLaneUnchanged(const SharedHeader *header,
                                        const TextLane *lane,
                                        const TextSlot *slot, uint64_t thread,
                                        uint64_t sequence) {
  return header && lane && slot && thread && sequence &&
         AtomicLoadPreview64(&header->selected_text_thread_id) == thread &&
         AtomicLoadPreview64(&lane->thread_id) == thread &&
         AtomicLoadPreview64(&lane->write_count) == sequence &&
         AtomicLoadPreview64(&slot->lane_seq) == sequence;
}
// Read the current selected lane with its sequence fence. Engine adapters own
// their text-to-glyph matching; lane decoding and identity checks are shared.
inline bool ReadSelectedLookupText(SharedHeader *header, std::wstring *line,
                                   uint64_t *event, uint64_t *selected_thread,
                                   size_t max_units) {
  if (!line || !event || !selected_thread || !header ||
      header->text_lane_count != kTextLaneCount ||
      header->text_lane_slot_count != kTextLaneSlotCount)
    return false;
  *selected_thread = AtomicLoadPreview64(&header->selected_text_thread_id);
  if (!*selected_thread)
    return false;
  const auto *lanes = TextLanesOf(header);
  if (!lanes)
    return false;
  for (uint32_t i = 0; i < header->text_lane_count; ++i) {
    if (AtomicLoadPreview64(&lanes[i].thread_id) != *selected_thread)
      continue;
    const uint64_t sequence = AtomicLoadPreview64(&lanes[i].write_count);
    const auto *bytes = TextLaneSlotAt(header, i, sequence);
    if (!bytes)
      return false;
    const auto *slot = reinterpret_cast<const TextSlot *>(bytes);
    if (AtomicLoadPreview64(&slot->lane_seq) != sequence)
      return false;
    alignas(8) std::array<uint8_t, kTextSlotBytes> copy = {};
    memcpy(copy.data(), bytes, copy.size());
    MemoryBarrier();
    const auto *saved = reinterpret_cast<const TextSlot *>(copy.data());
    if (AtomicLoadPreview64(&slot->lane_seq) != sequence ||
        saved->lane_seq != sequence || saved->thread_id != *selected_thread ||
        saved->event_kind != kTextEventLine || !saved->byte_len ||
        saved->byte_len > copy.size() - sizeof(*saved))
      return false;
    const char *payload =
        reinterpret_cast<const char *>(copy.data() + sizeof(*saved));
    if (saved->is_utf8) {
      const int count = MultiByteToWideChar(
          CP_UTF8, MB_ERR_INVALID_CHARS, payload, saved->byte_len, nullptr, 0);
      if (count <= 0 || static_cast<size_t>(count) > max_units)
        return false;
      line->resize(count);
      if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, payload,
                              saved->byte_len, line->data(), count) != count)
        return false;
    } else {
      if (saved->byte_len % 2 || saved->byte_len / 2 > max_units)
        return false;
      line->resize(saved->byte_len / 2);
      memcpy(line->data(), payload, saved->byte_len);
    }
    if (!SelectedLookupLaneUnchanged(header, &lanes[i], slot, *selected_thread,
                                     sequence))
      return false;
    *event = saved->seq;
    return *event != 0;
  }
  return false;
}
} // namespace fushi_voice_hook
