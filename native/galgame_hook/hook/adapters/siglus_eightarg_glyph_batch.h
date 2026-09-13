#pragma once

#include <array>
#include <cstdint>
#include "siglus_eightarg_message_capture.h"
#include "siglus_glyph_record.h"

namespace fushi_voice_hook::siglus_eightarg_glyph_batch {

constexpr uint32_t kCapacity = 256;
struct Identity {
  uint64_t occurrence = 0;
  // The caller advances this token on window/session/coordinate-space reset.
  // Zero is allowed: it is a generation token, not an event ID.
  uint64_t capture_epoch = 0;
  siglus_eightarg_message::Owner body{};
  // Caller-proved vector snapshot. Same body/count does not prove the same
  // storage: reallocation must never splice two redraws into one batch.
  uint32_t glyph_begin = 0, glyph_end = 0, glyph_capacity = 0;
};
inline bool Same(const Identity& a, const Identity& b) {
  return a.occurrence == b.occurrence && a.capture_epoch == b.capture_epoch &&
      siglus_eightarg_message::Same(a.body, b.body) &&
      a.glyph_begin == b.glyph_begin && a.glyph_end == b.glyph_end &&
      a.glyph_capacity == b.glyph_capacity;
}
inline bool Same(const SiglusGlyphRecord& a, const SiglusGlyphRecord& b) {
  return a.code_unit == b.code_unit && a.extent == b.extent &&
      a.x == b.x && a.y == b.y;
}
struct PushResult {
  bool accepted = false;
  bool complete = false;
  // A previously complete layout became unproved at this exact observation.
  // Publish a barrier before any later complete batch. Repeated bad input
  // does not repeatedly invalidate the same already-invalid layout.
  bool invalidate_previous = false;
};

// One collector per serialized producer. This class is not a concurrent ring
// or an ownership resolver: callers prove the body and decode each record.
// On a decode failure they must Reset and invalidate their published layout.
// Only complete batches leave this collector; no time/text heuristic is used.
class Collector {
 public:
  void Reset() {
    pending_size_ = pending_count_ = previous_count_ = 0;
    previous_valid_ = complete_ = false;
    pending_identity_ = {};
    previous_identity_ = {};
  }

  PushResult Push(const Identity& identity, uint32_t ordinal, uint32_t count,
                  const SiglusGlyphRecord& glyph) {
    complete_ = false;
    if (identity.occurrence == 0 || identity.body.address == 0 ||
        identity.body.surface == 0 || count == 0 || count > kCapacity ||
        ordinal >= count) return Reject();
    // A mismatched observation cannot itself be salvaged as the start of a
    // new batch. The next accepted batch needs a fresh ordinal zero.
    if (pending_size_ != 0 && (ordinal != pending_size_ ||
        count != pending_count_ || !Same(identity, pending_identity_)))
      return Reject();
    if (pending_size_ == 0 && ordinal != 0) return Reject();

    PushResult result{true, false, false};
    if (pending_size_ == 0) {
      pending_identity_ = identity;
      pending_count_ = count;
      if (previous_valid_ && (previous_count_ != count ||
          !Same(previous_identity_, identity)))
        result.invalidate_previous = InvalidatePrevious();
    }
    if (previous_valid_ && !Same(previous_[ordinal], glyph))
      result.invalidate_previous = InvalidatePrevious();
    pending_[pending_size_++] = glyph;
    if (pending_size_ != pending_count_) return result;

    for (uint32_t i = 0; i < pending_count_; ++i) previous_[i] = pending_[i];
    previous_identity_ = pending_identity_;
    previous_count_ = pending_count_;
    previous_valid_ = complete_ = true;
    pending_size_ = pending_count_ = 0;
    result.complete = true;
    return result;
  }

  // Valid only until the next Push/Reset. The retained comparison baseline
  // is deliberately inaccessible while a redraw is still incomplete.
  const SiglusGlyphRecord* entries() const { return complete_ ? previous_.data() : nullptr; }
  uint32_t size() const { return complete_ ? previous_count_ : 0; }
  const Identity* identity() const { return complete_ ? &previous_identity_ : nullptr; }

 private:
  bool InvalidatePrevious() {
    const bool was_valid = previous_valid_;
    previous_valid_ = false;
    return was_valid;
  }
  PushResult Reject() {
    const bool invalidated = InvalidatePrevious();
    pending_size_ = pending_count_ = 0;
    return {false, false, invalidated};
  }
  Identity pending_identity_{}, previous_identity_{};
  std::array<SiglusGlyphRecord, kCapacity> pending_{}, previous_{};
  uint32_t pending_size_ = 0, pending_count_ = 0, previous_count_ = 0;
  bool previous_valid_ = false, complete_ = false;
};

}  // namespace fushi_voice_hook::siglus_eightarg_glyph_batch
