#pragma once
#include "cmvs_sprite_geometry_reader.h"

namespace fushi_voice_hook::cmvs_layout {

struct ShiftGesture {
  bool was_down = false;
  bool owned = false;
};
struct ShiftDecision { bool suppress = false, enqueue = false; };

inline bool MaskShiftKeys(uint8_t* keys, size_t bytes) {
  if (!keys || bytes < 256) return false;
  keys[0x10] &= 0x7f; keys[0xa0] &= 0x7f; keys[0xa1] &= 0x7f;
  return true;
}

// A press is classified once, at its first native sample. Entering a glyph
// while already held cannot steal the key. Ownership survives loss of target
// or focus and ends only when the physical/cached Shift state is released.
inline ShiftDecision SampleShift(ShiftGesture* gesture, bool down,
                                 bool eligible, bool queue_available) {
  if (!gesture) return {};
  if (!down) {
    const bool suppress_release = gesture->owned;
    *gesture = {};
    return {suppress_release, false};
  }
  if (gesture->was_down) return {gesture->owned, false};
  gesture->was_down = true;
  gesture->owned = eligible && queue_available;
  return {gesture->owned, gesture->owned};
}

struct ShiftTarget {
  uint64_t event = 0, thread = 0, owner = 0, head = 0, node = 0;
  uint64_t sprite = 0, game = 0, input = 0, raw_frame = 0;
  int32_t first_id = -1, glyph_id = -1, owner_x = 0, owner_y = 0;
  int32_t node_x = 0, node_y = 0, origin_x = 0, origin_y = 0;
  int32_t view_width = 0, view_height = 0;
  uint32_t source_index = 0, text_units = 0;
  uint16_t cp932 = 0;
  PixelRect rectangle{};
  std::array<wchar_t, kMaxGlyphs> text{};
};

// raw_frame deliberately is not an identity: the same displayed line is
// redrawn many times before a worker consumes a press. Everything that can
// change the source occurrence, glyph or window projection remains binding.
inline bool SameShiftTarget(const ShiftTarget& a, const ShiftTarget& b) {
  return a.event && a.text_units && a.text_units <= kMaxGlyphs &&
      a.event == b.event && a.thread == b.thread && a.owner == b.owner &&
      a.head == b.head && a.node == b.node && a.sprite == b.sprite &&
      a.game == b.game && a.input == b.input && a.first_id == b.first_id &&
      a.glyph_id == b.glyph_id && a.owner_x == b.owner_x && a.owner_y == b.owner_y &&
      a.node_x == b.node_x && a.node_y == b.node_y && a.cp932 == b.cp932 &&
      a.origin_x == b.origin_x && a.origin_y == b.origin_y &&
      a.view_width == b.view_width && a.view_height == b.view_height &&
      a.source_index == b.source_index && a.text_units == b.text_units &&
      a.rectangle.x == b.rectangle.x && a.rectangle.y == b.rectangle.y &&
      a.rectangle.width == b.rectangle.width && a.rectangle.height == b.rectangle.height &&
      std::memcmp(a.text.data(), b.text.data(), a.text_units * sizeof(wchar_t)) == 0;
}

struct ShiftRequest { uint64_t sequence = 0; ShiftTarget target{}; };
struct ShiftQueue {
  std::array<ShiftRequest, 4> entries{};
  size_t first = 0, count = 0;
  uint64_t sequence = 0;
  bool available() const { return count < entries.size(); }
  bool Push(const ShiftTarget& target) {
    if (!available()) return false;
    entries[(first + count++) % entries.size()] = {++sequence, target};
    return true;
  }
  const ShiftRequest* Peek() const { return count ? &entries[first] : nullptr; }
  void Pop(uint64_t expected_sequence) {
    if (count && entries[first].sequence == expected_sequence) {
      first = (first + 1) % entries.size(); --count;
    }
  }
  void Clear() { first = 0; count = 0; }
};

}  // namespace fushi_voice_hook::cmvs_layout
