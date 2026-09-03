#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace fushi_voice_hook::hunex_capture_bridge {

// The story renderer can submit one callback per visible glyph. This bridge is
// deliberately a fixed-size callback-to-worker hand-off: the callback never
// allocates, waits, parses text, writes IPC, or calls the host.
inline constexpr size_t kGlyphCapacity = 512u;
inline constexpr size_t kTextCapacity = 512u;
// The adapter worker normally polls every 16 ms, while one visible frame can
// seal several body-wrapper traversals (story text plus the top toolbar).
// Retain a bounded history so the worker can select the exact Luna-bound story
// snapshot instead of treating the newest unrelated surface as authoritative.
inline constexpr size_t kSnapshotSlotCount = 16u;
inline constexpr uint32_t kInvalidSlot = (std::numeric_limits<uint32_t>::max)();
inline constexpr uint32_t kInvalidRawUtf16Index = 0xffffu;
inline constexpr uint32_t kInvalidVisibleGlyphOrdinal =
    (std::numeric_limits<uint32_t>::max)();

// Process-local, first-fault diagnostics for the fail-closed capture bridge.
// Values are mirrored by HunexGgeTraceCaptureQuarantineReason; keep the
// adapter-side static assertions next to the trace publication path.
enum class CaptureQuarantineReason : uint32_t {
  kNone = 0u,
  kReentrantCallback = 1u,
  kInvalidRenderThreadId = 2u,
  kRenderThreadConflict = 3u,
  kLineIdentityOrFenceInvalid = 4u,
  kSlotSequenceOverflow = 5u,
};

static_assert(std::atomic<uint32_t>::is_always_lock_free,
              "HUNEX render callbacks require lock-free 32-bit atomics");
static_assert(std::atomic<int32_t>::is_always_lock_free,
              "HUNEX render callbacks require lock-free 32-bit atomics");
static_assert(std::atomic<bool>::is_always_lock_free,
              "HUNEX render callbacks require lock-free boolean atomics");

struct LogicalRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

struct GlyphSnapshot {
  uint16_t raw_utf16_index = 0u;
  uint16_t consumed_utf16_width = 0u;
  uint32_t scalar = 0u;
  LogicalRect logical_rect = {};
};

struct TraversalSnapshot {
  uint32_t epoch = 0u;
  uint32_t render_thread_id = 0u;
  uint64_t story_thread_address = 0u;
  uint64_t text_window_through_seq = 0u;
  uint64_t raw_text_hash = 0u;
  uint16_t raw_text_units = 0u;
  std::array<uint16_t, kTextCapacity> raw_text = {};
  uint16_t glyph_count = 0u;
  std::array<GlyphSnapshot, kGlyphCapacity> glyphs = {};
};

struct SubmitOutcome {
  bool glyph_accepted = false;
  bool snapshot_published = false;
  bool quarantined = false;
};

struct TraversalCaptureBridgeTestPeer;

inline bool IsUnicodeScalar(uint32_t scalar) {
  return scalar != 0u && scalar <= 0x10ffffu &&
         !(scalar >= 0xd800u && scalar <= 0xdfffu) && scalar != 0x0au &&
         scalar != 0x0du;
}

inline uint16_t Utf16WidthForScalar(uint32_t scalar) {
  if (!IsUnicodeScalar(scalar))
    return 0u;
  return scalar >= 0x10000u ? 2u : 1u;
}

inline bool IsSaneLogicalRect(const LogicalRect &rect) {
  if (rect.width <= 0 || rect.height <= 0)
    return false;
  const int64_t right = static_cast<int64_t>(rect.x) + rect.width;
  const int64_t bottom = static_cast<int64_t>(rect.y) + rect.height;
  return right <= (std::numeric_limits<int32_t>::max)() &&
         right >= (std::numeric_limits<int32_t>::min)() &&
         bottom <= (std::numeric_limits<int32_t>::max)() &&
         bottom >= (std::numeric_limits<int32_t>::min)();
}

inline bool IsValidGlyph(uint32_t raw_utf16_index, uint32_t scalar,
                         uint32_t consumed_utf16_width,
                         const LogicalRect &logical_rect) {
  const uint16_t expected_width = Utf16WidthForScalar(scalar);
  return raw_utf16_index < kInvalidRawUtf16Index && expected_width != 0u &&
         consumed_utf16_width == expected_width &&
         IsSaneLogicalRect(logical_rect);
}

class TraversalCaptureBridge {
public:
  TraversalCaptureBridge() = default;
  TraversalCaptureBridge(const TraversalCaptureBridge &) = delete;
  TraversalCaptureBridge &operator=(const TraversalCaptureBridge &) = delete;

  // Reset is an adapter-lifecycle operation. It acquires the same non-blocking
  // owner token as render callbacks, but reset/callback contention is only a
  // retry signal: lifecycle transitions must not manufacture a capture fault.
  // A true callback/callback overlap remains an admitted capture fault and is
  // quarantined by the callback entry paths below.
  bool Reset() {
    uint32_t expected_owner = kOwnerIdle;
    if (!owner_.compare_exchange_strong(
            expected_owner, kOwnerReset, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      return false;
    }

    published_slot_.store(kInvalidSlot, std::memory_order_release);
    for (AtomicSlot &slot : slots_) {
      slot.sequence.store(0u, std::memory_order_relaxed);
      slot.epoch.store(0u, std::memory_order_relaxed);
      slot.render_thread_id.store(0u, std::memory_order_relaxed);
      slot.story_thread_address_low.store(0u, std::memory_order_relaxed);
      slot.story_thread_address_high.store(0u, std::memory_order_relaxed);
      slot.text_window_through_seq_low.store(0u, std::memory_order_relaxed);
      slot.text_window_through_seq_high.store(0u, std::memory_order_relaxed);
      slot.raw_text_hash_low.store(0u, std::memory_order_relaxed);
      slot.raw_text_hash_high.store(0u, std::memory_order_relaxed);
      slot.raw_text_units.store(0u, std::memory_order_relaxed);
      slot.glyph_count.store(0u, std::memory_order_relaxed);
    }
    bound_render_thread_id_.store(0u, std::memory_order_relaxed);
    next_slot_ = 0u;
    active_slot_ = kInvalidSlot;
    active_sequence_ = 0u;
    active_count_ = 0u;
    active_started_ = false;
    active_valid_ = false;
    last_raw_utf16_index_ = 0u;
    active_raw_text_hash_ = 0u;
    active_raw_text_units_ = 0u;
    active_story_thread_address_ = 0u;
    active_text_window_through_seq_ = 0u;
    active_has_line_ = false;
    active_expected_visible_glyph_count_ = 0u;
    active_next_visible_glyph_ordinal_ = 0u;
    next_epoch_ = 1u;
    quarantine_reason_.store(
        static_cast<uint32_t>(CaptureQuarantineReason::kNone),
        std::memory_order_relaxed);
    quarantine_bound_render_thread_id_.store(0u,
                                               std::memory_order_relaxed);
    quarantine_conflicting_thread_id_.store(0u,
                                              std::memory_order_relaxed);
    quarantine_diagnostic_recorded_.clear(std::memory_order_release);
    quarantined_.store(false, std::memory_order_release);
    owner_.store(kOwnerIdle, std::memory_order_release);
    return true;
  }

  // Called from the admitted story-body submit callback. Raw indices must be
  // strictly increasing within one renderer traversal. A wrap or duplicate
  // seals the previous traversal first, then starts a new one with this glyph.
  SubmitOutcome SubmitGlyph(uint32_t render_thread_id, uint32_t raw_utf16_index,
                            uint32_t scalar, uint32_t consumed_utf16_width,
                            const LogicalRect &logical_rect) {
    return SubmitGlyphInternal(render_thread_id, raw_utf16_index, scalar,
                               consumed_utf16_width, logical_rect, nullptr, 0u,
                               0u, 0u, 0u, false);
  }

  // Runtime form used by the admitted story-body path. The hash is only a
  // cheap traversal-boundary fence: the full UTF-16 line is copied into the
  // same published slot and is later matched byte-for-byte on the worker.
  SubmitOutcome SubmitGlyphWithLine(
      uint32_t render_thread_id, uint32_t raw_utf16_index, uint32_t scalar,
      uint32_t consumed_utf16_width, const LogicalRect &logical_rect,
      const uint16_t *raw_text, uint32_t raw_text_units, uint64_t raw_text_hash,
      uint64_t story_thread_address, uint64_t text_window_through_seq,
      uint32_t visible_glyph_ordinal = kInvalidVisibleGlyphOrdinal,
      uint32_t expected_visible_glyph_count = 0u) {
    return SubmitGlyphInternal(
        render_thread_id, raw_utf16_index, scalar, consumed_utf16_width,
        logical_rect, raw_text, raw_text_units, raw_text_hash,
        story_thread_address, text_window_through_seq, true,
        visible_glyph_ordinal, expected_visible_glyph_count);
  }

  // Exact line-aware traversals defer the inclusive Luna text-event upper
  // fence until the renderer has accepted the final grammar glyph. This is a
  // separate callback admission so the adapter can sample the live shared
  // counter after SubmitGlyphWithLine returns, without publishing a first-
  // glyph fence that has no cross-process happens-before relationship.
  SubmitOutcome FinalizeExactLineTraversal(
      uint32_t render_thread_id, uint64_t text_window_through_seq) {
    uint32_t expected_owner = kOwnerIdle;
    if (!owner_.compare_exchange_strong(
            expected_owner, kOwnerCallback, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      SubmitOutcome outcome;
      if (expected_owner != kOwnerReset) {
        QuarantineFromConcurrentEntry(render_thread_id);
        outcome.quarantined = true;
      }
      return outcome;
    }
    CallbackExit callback_exit(&owner_);

    if (quarantined_.load(std::memory_order_acquire)) {
      SubmitOutcome outcome;
      outcome.quarantined = true;
      return outcome;
    }
    // Finalization must stay on the thread that built the active traversal.
    // Another exact traversal can take ownership in the short gap between the
    // final Submit and this call; a stale finalizer is therefore dropped, not
    // treated as a concurrent-writer fault.
    const RenderThreadAdmission thread_admission =
        BindRenderThreadLocked(render_thread_id, false, true);
    if (thread_admission != RenderThreadAdmission::kAccepted) {
      SubmitOutcome outcome;
      outcome.quarantined =
          thread_admission == RenderThreadAdmission::kQuarantined;
      return outcome;
    }

    SubmitOutcome outcome;
    const bool exact_traversal_complete =
        text_window_through_seq != 0u && active_started_ && active_valid_ &&
        active_has_line_ && active_text_window_through_seq_ == 0u &&
        active_expected_visible_glyph_count_ != 0u &&
        active_next_visible_glyph_ordinal_ ==
            active_expected_visible_glyph_count_ &&
        active_count_ == active_expected_visible_glyph_count_;
    if (!exact_traversal_complete) {
      // A missing/unstable fence or premature seal must not leave either an
      // older redraw or a plausible prefix available to the lookup worker.
      AbandonActiveLocked();
      return outcome;
    }

    active_text_window_through_seq_ = text_window_through_seq;
    outcome.snapshot_published = SealActiveLocked();
    if (quarantined_.load(std::memory_order_acquire))
      outcome.quarantined = true;
    return outcome;
  }

  // Worker-side, lock-free read. Payload fields are atomic so a slot reuse can
  // never create a C++ data race; the sequence check rejects torn/obsolete
  // copies. Failure clears the output instead of leaving a stale snapshot.
  bool ReadLatest(TraversalSnapshot *snapshot) const {
    if (snapshot == nullptr)
      return false;
    *snapshot = {};
    if (quarantined_.load(std::memory_order_acquire))
      return false;

    const uint32_t slot_index = published_slot_.load(std::memory_order_acquire);
    if (slot_index >= kSnapshotSlotCount)
      return false;
    if (!ReadSealedSlot(slot_index, snapshot))
      return false;
    return published_slot_.load(std::memory_order_acquire) == slot_index &&
           !quarantined_.load(std::memory_order_acquire);
  }

  // Worker-side stable enumeration. Physical slot order is intentionally not
  // a recency contract; callers compare the copied epoch and choose only an
  // exact semantic match. An active/reused slot is odd and therefore skipped.
  bool ReadSealedSlot(uint32_t slot_index,
                      TraversalSnapshot *snapshot) const {
    if (snapshot == nullptr || slot_index >= kSnapshotSlotCount)
      return false;
    *snapshot = {};
    if (quarantined_.load(std::memory_order_acquire))
      return false;

    const AtomicSlot &slot = slots_[slot_index];
    const uint32_t sequence_before =
        slot.sequence.load(std::memory_order_acquire);
    if (sequence_before == 0u || (sequence_before & 1u) != 0u)
      return false;

    TraversalSnapshot candidate;
    candidate.epoch = slot.epoch.load(std::memory_order_relaxed);
    candidate.render_thread_id =
        slot.render_thread_id.load(std::memory_order_relaxed);
    candidate.story_thread_address =
        static_cast<uint64_t>(
            slot.story_thread_address_low.load(std::memory_order_relaxed)) |
        (static_cast<uint64_t>(
             slot.story_thread_address_high.load(std::memory_order_relaxed))
         << 32u);
    candidate.text_window_through_seq =
        static_cast<uint64_t>(
            slot.text_window_through_seq_low.load(std::memory_order_relaxed)) |
        (static_cast<uint64_t>(
             slot.text_window_through_seq_high.load(std::memory_order_relaxed))
         << 32u);
    candidate.raw_text_hash =
        static_cast<uint64_t>(
            slot.raw_text_hash_low.load(std::memory_order_relaxed)) |
        (static_cast<uint64_t>(
             slot.raw_text_hash_high.load(std::memory_order_relaxed))
         << 32u);
    const uint32_t raw_text_units =
        slot.raw_text_units.load(std::memory_order_relaxed);
    if (raw_text_units > kTextCapacity)
      return false;
    candidate.raw_text_units = static_cast<uint16_t>(raw_text_units);
    for (size_t index = 0u; index < raw_text_units; ++index) {
      const uint32_t unit =
          slot.raw_text[index].load(std::memory_order_relaxed);
      if (unit == 0u || unit > 0xffffu)
        return false;
      candidate.raw_text[index] = static_cast<uint16_t>(unit);
    }
    const uint32_t glyph_count =
        slot.glyph_count.load(std::memory_order_relaxed);
    if (candidate.epoch == 0u || candidate.render_thread_id == 0u ||
        glyph_count == 0u || glyph_count > kGlyphCapacity) {
      return false;
    }
    candidate.glyph_count = static_cast<uint16_t>(glyph_count);

    for (size_t index = 0u; index < glyph_count; ++index) {
      const AtomicGlyph &source = slot.glyphs[index];
      GlyphSnapshot &glyph = candidate.glyphs[index];
      const uint32_t raw_utf16_index =
          source.raw_utf16_index.load(std::memory_order_relaxed);
      const uint32_t consumed_utf16_width =
          source.consumed_utf16_width.load(std::memory_order_relaxed);
      if (raw_utf16_index >= kInvalidRawUtf16Index ||
          consumed_utf16_width > (std::numeric_limits<uint16_t>::max)()) {
        return false;
      }
      glyph.raw_utf16_index = static_cast<uint16_t>(raw_utf16_index);
      glyph.consumed_utf16_width = static_cast<uint16_t>(consumed_utf16_width);
      glyph.scalar = source.scalar.load(std::memory_order_relaxed);
      glyph.logical_rect.x = source.x.load(std::memory_order_relaxed);
      glyph.logical_rect.y = source.y.load(std::memory_order_relaxed);
      glyph.logical_rect.width = source.width.load(std::memory_order_relaxed);
      glyph.logical_rect.height = source.height.load(std::memory_order_relaxed);
    }

    const uint32_t sequence_after =
        slot.sequence.load(std::memory_order_acquire);
    if (sequence_after != sequence_before || (sequence_after & 1u) != 0u ||
        quarantined_.load(std::memory_order_acquire) ||
        !IsStrictSnapshot(candidate)) {
      return false;
    }
    *snapshot = candidate;
    return true;
  }

  bool quarantined() const {
    return quarantined_.load(std::memory_order_acquire);
  }

  uint32_t bound_render_thread_id() const {
    return bound_render_thread_id_.load(std::memory_order_acquire);
  }

  CaptureQuarantineReason quarantine_reason() const {
    return static_cast<CaptureQuarantineReason>(
        quarantine_reason_.load(std::memory_order_acquire));
  }

  uint32_t quarantine_bound_render_thread_id() const {
    return quarantine_bound_render_thread_id_.load(
        std::memory_order_acquire);
  }

  uint32_t quarantine_conflicting_thread_id() const {
    return quarantine_conflicting_thread_id_.load(std::memory_order_acquire);
  }

private:
  friend struct TraversalCaptureBridgeTestPeer;

  enum class RenderThreadAdmission {
    kAccepted,
    kDropped,
    kQuarantined,
  };

  static constexpr uint32_t kOwnerIdle = 0u;
  static constexpr uint32_t kOwnerCallback = 1u;
  static constexpr uint32_t kOwnerReset = 2u;

  struct CallbackExit {
    explicit CallbackExit(std::atomic<uint32_t> *owner) : owner_(owner) {}
    ~CallbackExit() { owner_->store(kOwnerIdle, std::memory_order_release); }
    CallbackExit(const CallbackExit &) = delete;
    CallbackExit &operator=(const CallbackExit &) = delete;

  private:
    std::atomic<uint32_t> *owner_;
  };

  struct AtomicGlyph {
    std::atomic<uint32_t> raw_utf16_index{0u};
    std::atomic<uint32_t> consumed_utf16_width{0u};
    std::atomic<uint32_t> scalar{0u};
    std::atomic<int32_t> x{0};
    std::atomic<int32_t> y{0};
    std::atomic<int32_t> width{0};
    std::atomic<int32_t> height{0};
  };

  struct AtomicSlot {
    // Odd means building/invalid. Even non-zero means a sealed snapshot.
    std::atomic<uint32_t> sequence{0u};
    std::atomic<uint32_t> epoch{0u};
    std::atomic<uint32_t> render_thread_id{0u};
    std::atomic<uint32_t> story_thread_address_low{0u};
    std::atomic<uint32_t> story_thread_address_high{0u};
    std::atomic<uint32_t> text_window_through_seq_low{0u};
    std::atomic<uint32_t> text_window_through_seq_high{0u};
    std::atomic<uint32_t> raw_text_hash_low{0u};
    std::atomic<uint32_t> raw_text_hash_high{0u};
    std::atomic<uint32_t> raw_text_units{0u};
    std::array<std::atomic<uint32_t>, kTextCapacity> raw_text = {};
    std::atomic<uint32_t> glyph_count{0u};
    std::array<AtomicGlyph, kGlyphCapacity> glyphs = {};
  };

  SubmitOutcome
  SubmitGlyphInternal(uint32_t render_thread_id, uint32_t raw_utf16_index,
                      uint32_t scalar, uint32_t consumed_utf16_width,
                      const LogicalRect &logical_rect, const uint16_t *raw_text,
                      uint32_t raw_text_units, uint64_t raw_text_hash,
                      uint64_t story_thread_address,
                      uint64_t text_window_through_seq, bool line_required,
                      uint32_t visible_glyph_ordinal =
                          kInvalidVisibleGlyphOrdinal,
                      uint32_t expected_visible_glyph_count = 0u) {
    uint32_t expected_owner = kOwnerIdle;
    if (!owner_.compare_exchange_strong(
            expected_owner, kOwnerCallback, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
      SubmitOutcome outcome;
      if (expected_owner != kOwnerReset) {
        QuarantineFromConcurrentEntry(render_thread_id);
        outcome.quarantined = true;
      }
      return outcome;
    }
    CallbackExit callback_exit(&owner_);

    if (quarantined_.load(std::memory_order_acquire)) {
      SubmitOutcome outcome;
      outcome.quarantined = true;
      return outcome;
    }
    const bool exact_line_mode = expected_visible_glyph_count != 0u;
    const bool line_fence_shape_valid =
        exact_line_mode ? text_window_through_seq == 0u
                        : text_window_through_seq != 0u;
    const bool has_line =
        line_required && line_fence_shape_valid &&
        IsValidRawLineIdentity(raw_text, raw_text_units, raw_text_hash,
                               story_thread_address);
    if (line_required && !has_line) {
      SubmitOutcome outcome;
      QuarantineLocked(
          CaptureQuarantineReason::kLineIdentityOrFenceInvalid);
      outcome.quarantined = true;
      return outcome;
    }
    const bool allow_serialized_exact_handoff =
        exact_line_mode && has_line &&
        expected_visible_glyph_count <= kGlyphCapacity &&
        visible_glyph_ordinal == 0u &&
        IsValidGlyph(raw_utf16_index, scalar, consumed_utf16_width,
                     logical_rect);
    const RenderThreadAdmission thread_admission = BindRenderThreadLocked(
        render_thread_id, allow_serialized_exact_handoff, exact_line_mode);
    if (thread_admission != RenderThreadAdmission::kAccepted) {
      SubmitOutcome outcome;
      outcome.quarantined =
          thread_admission == RenderThreadAdmission::kQuarantined;
      return outcome;
    }

    SubmitOutcome outcome;
    const bool line_mode_changed =
        active_started_ && active_has_line_ != has_line;
    const bool line_changed =
        active_started_ && has_line && active_has_line_ &&
        (active_raw_text_hash_ != raw_text_hash ||
         active_raw_text_units_ != raw_text_units ||
         active_story_thread_address_ != story_thread_address ||
         active_text_window_through_seq_ != text_window_through_seq ||
         !ActiveLineEqualsLocked(raw_text, raw_text_units));
    if (line_mode_changed || line_changed) {
      // A new visible line must not leave the previous line available as the
      // latest lookup target. Close it without publication and invalidate any
      // older published redraw until the new line completes a traversal.
      AbandonActiveLocked();
    } else if (active_started_ && raw_utf16_index <= last_raw_utf16_index_) {
      // Exact line-aware traversals publish only when every grammar token was
      // observed. A wrap before that point is an incomplete redraw, not a
      // completion signal. Keep the legacy index-only API behavior unchanged.
      if (active_expected_visible_glyph_count_ != 0u)
        AbandonActiveLocked();
      else
        outcome.snapshot_published = SealActiveLocked();
      if (quarantined_.load(std::memory_order_acquire)) {
        outcome.quarantined = true;
        return outcome;
      }
    }
    if (!active_started_ && !BeginActiveLocked()) {
      outcome.quarantined = true;
      return outcome;
    }
    if (has_line && !active_has_line_ &&
        !BindActiveLineLocked(raw_text, raw_text_units, raw_text_hash,
                              story_thread_address, text_window_through_seq)) {
      outcome.quarantined = true;
      return outcome;
    }

    if (expected_visible_glyph_count != 0u) {
      if (expected_visible_glyph_count > kGlyphCapacity) {
        active_valid_ = false;
      } else if (active_expected_visible_glyph_count_ == 0u) {
        active_expected_visible_glyph_count_ =
            expected_visible_glyph_count;
      } else if (active_expected_visible_glyph_count_ !=
                 expected_visible_glyph_count) {
        active_valid_ = false;
      }
      if (visible_glyph_ordinal == kInvalidVisibleGlyphOrdinal ||
          visible_glyph_ordinal != active_next_visible_glyph_ordinal_ ||
          visible_glyph_ordinal >= expected_visible_glyph_count) {
        active_valid_ = false;
      }
    } else if (active_expected_visible_glyph_count_ != 0u) {
      active_valid_ = false;
    }

    last_raw_utf16_index_ = raw_utf16_index;
    if (!active_valid_ && active_expected_visible_glyph_count_ != 0u) {
      // Once the exact renderer grammar is violated, retain the invalid active
      // traversal solely as a boundary fence. Do not let later glyphs restart
      // a count that could accidentally complete and publish a suffix.
      return outcome;
    }
    if (!IsValidGlyph(raw_utf16_index, scalar, consumed_utf16_width,
                      logical_rect) ||
        active_count_ >= kGlyphCapacity) {
      // Keep consuming indices until the next traversal boundary, but never
      // publish a plausible prefix of this malformed/overflowed traversal.
      active_valid_ = false;
      return outcome;
    }

    AtomicGlyph &destination = slots_[active_slot_].glyphs[active_count_];
    destination.raw_utf16_index.store(raw_utf16_index,
                                      std::memory_order_relaxed);
    destination.consumed_utf16_width.store(consumed_utf16_width,
                                           std::memory_order_relaxed);
    destination.scalar.store(scalar, std::memory_order_relaxed);
    destination.x.store(logical_rect.x, std::memory_order_relaxed);
    destination.y.store(logical_rect.y, std::memory_order_relaxed);
    destination.width.store(logical_rect.width, std::memory_order_relaxed);
    destination.height.store(logical_rect.height, std::memory_order_relaxed);
    ++active_count_;
    outcome.glyph_accepted = true;
    if (active_expected_visible_glyph_count_ != 0u) {
      ++active_next_visible_glyph_ordinal_;
    }
    return outcome;
  }

  static bool IsStrictSnapshot(const TraversalSnapshot &snapshot) {
    if (snapshot.epoch == 0u || snapshot.render_thread_id == 0u ||
        snapshot.glyph_count == 0u || snapshot.glyph_count > kGlyphCapacity) {
      return false;
    }
    const bool has_any_line_metadata = snapshot.story_thread_address != 0u ||
                                       snapshot.text_window_through_seq != 0u ||
                                       snapshot.raw_text_hash != 0u ||
                                       snapshot.raw_text_units != 0u;
    if (has_any_line_metadata &&
        (snapshot.story_thread_address == 0u || snapshot.raw_text_hash == 0u ||
         snapshot.text_window_through_seq == 0u ||
         snapshot.raw_text_units == 0u ||
         snapshot.raw_text_units > kTextCapacity)) {
      return false;
    }
    if (has_any_line_metadata) {
      for (size_t index = 0u; index < snapshot.raw_text_units; ++index) {
        if (snapshot.raw_text[index] == 0u)
          return false;
      }
    }

    uint32_t previous_raw_index = 0u;
    for (size_t index = 0u; index < snapshot.glyph_count; ++index) {
      const GlyphSnapshot &glyph = snapshot.glyphs[index];
      if (!IsValidGlyph(glyph.raw_utf16_index, glyph.scalar,
                        glyph.consumed_utf16_width, glyph.logical_rect) ||
          (index != 0u && glyph.raw_utf16_index <= previous_raw_index)) {
        return false;
      }
      previous_raw_index = glyph.raw_utf16_index;
    }
    return true;
  }

  void RecordFirstQuarantine(CaptureQuarantineReason reason,
                             uint32_t conflicting_thread_id) {
    // The first caller owns all diagnostic fields. Later failures retain that
    // original cause rather than replacing it with a secondary consequence.
    if (quarantine_diagnostic_recorded_.test_and_set(
            std::memory_order_acquire)) {
      return;
    }
    quarantine_bound_render_thread_id_.store(
        bound_render_thread_id_.load(std::memory_order_relaxed),
        std::memory_order_relaxed);
    quarantine_conflicting_thread_id_.store(conflicting_thread_id,
                                              std::memory_order_relaxed);
    quarantine_reason_.store(static_cast<uint32_t>(reason),
                             std::memory_order_release);
    quarantined_.store(true, std::memory_order_release);
  }

  void QuarantineFromConcurrentEntry(uint32_t conflicting_thread_id) {
    RecordFirstQuarantine(CaptureQuarantineReason::kReentrantCallback,
                          conflicting_thread_id);
    published_slot_.store(kInvalidSlot, std::memory_order_release);
  }

  void QuarantineLocked(CaptureQuarantineReason reason,
                        uint32_t conflicting_thread_id = 0u) {
    RecordFirstQuarantine(reason, conflicting_thread_id);
    published_slot_.store(kInvalidSlot, std::memory_order_release);
    active_started_ = false;
    active_valid_ = false;
    active_slot_ = kInvalidSlot;
    active_count_ = 0u;
  }

  void AbandonActiveLocked() {
    published_slot_.store(kInvalidSlot, std::memory_order_release);
    active_started_ = false;
    active_valid_ = false;
    active_slot_ = kInvalidSlot;
    active_count_ = 0u;
    active_raw_text_hash_ = 0u;
    active_raw_text_units_ = 0u;
    active_story_thread_address_ = 0u;
    active_text_window_through_seq_ = 0u;
    active_has_line_ = false;
    active_expected_visible_glyph_count_ = 0u;
    active_next_visible_glyph_ordinal_ = 0u;
  }

  RenderThreadAdmission BindRenderThreadLocked(
      uint32_t render_thread_id, bool allow_serialized_exact_handoff,
      bool drop_serialized_conflict) {
    if (render_thread_id == 0u) {
      QuarantineLocked(CaptureQuarantineReason::kInvalidRenderThreadId);
      return RenderThreadAdmission::kQuarantined;
    }
    const uint32_t bound =
        bound_render_thread_id_.load(std::memory_order_relaxed);
    if (bound == 0u) {
      bound_render_thread_id_.store(render_thread_id,
                                    std::memory_order_release);
      return RenderThreadAdmission::kAccepted;
    }
    if (bound == render_thread_id)
      return RenderThreadAdmission::kAccepted;

    // GGE can move an exact line-aware body traversal to its input thread
    // while handling a click. Reaching this point already proves that the
    // callback owns the bridge's non-blocking owner token, so an explicitly
    // admitted hand-off is serialized rather than concurrent mutation. Never
    // splice glyphs from the old and new threads: discard an unfinished exact
    // traversal, then let the new thread build a complete traversal of its
    // own. Only a fully prevalidated first glyph can hand off; a mid-line
    // exact callback or stale finalizer is dropped until the next complete
    // redraw. Legacy/index-only capture has no ordinal/count proof and retains
    // the sticky conflict quarantine. A true overlapping callback still fails
    // the owner CAS above and is quarantined as kReentrantCallback.
    if (allow_serialized_exact_handoff) {
      if (active_started_)
        AbandonActiveLocked();
      bound_render_thread_id_.store(render_thread_id,
                                    std::memory_order_release);
      return RenderThreadAdmission::kAccepted;
    }
    if (drop_serialized_conflict) {
      return RenderThreadAdmission::kDropped;
    }
    QuarantineLocked(CaptureQuarantineReason::kRenderThreadConflict,
                     render_thread_id);
    return RenderThreadAdmission::kQuarantined;
  }

  bool BeginActiveLocked() {
    const uint32_t slot_index = next_slot_;
    next_slot_ = static_cast<uint32_t>((next_slot_ + 1u) % kSnapshotSlotCount);
    AtomicSlot &slot = slots_[slot_index];
    const uint32_t old_sequence = slot.sequence.load(std::memory_order_relaxed);
    const uint64_t next_odd = static_cast<uint64_t>(old_sequence) +
                              ((old_sequence & 1u) != 0u ? 2u : 1u);
    if (next_odd >= (std::numeric_limits<uint32_t>::max)()) {
      QuarantineLocked(CaptureQuarantineReason::kSlotSequenceOverflow);
      return false;
    }
    if (published_slot_.load(std::memory_order_relaxed) == slot_index)
      published_slot_.store(kInvalidSlot, std::memory_order_release);
    active_slot_ = slot_index;
    active_sequence_ = static_cast<uint32_t>(next_odd);
    slot.sequence.store(active_sequence_, std::memory_order_release);
    active_count_ = 0u;
    active_started_ = true;
    active_valid_ = true;
    active_raw_text_hash_ = 0u;
    active_raw_text_units_ = 0u;
    active_story_thread_address_ = 0u;
    active_text_window_through_seq_ = 0u;
    active_has_line_ = false;
    active_expected_visible_glyph_count_ = 0u;
    active_next_visible_glyph_ordinal_ = 0u;
    return true;
  }

  static bool IsValidRawLineIdentity(const uint16_t *raw_text,
                                     uint32_t raw_text_units,
                                     uint64_t raw_text_hash,
                                     uint64_t story_thread_address) {
    if (raw_text == nullptr || raw_text_units == 0u ||
        raw_text_units > kTextCapacity || raw_text_hash == 0u ||
        story_thread_address == 0u) {
      return false;
    }
    for (size_t index = 0u; index < raw_text_units; ++index) {
      if (raw_text[index] == 0u)
        return false;
    }
    return true;
  }

  bool ActiveLineEqualsLocked(const uint16_t *raw_text,
                              uint32_t raw_text_units) const {
    if (!active_started_ || !active_has_line_ ||
        active_slot_ >= kSnapshotSlotCount || raw_text == nullptr ||
        raw_text_units != active_raw_text_units_) {
      return false;
    }
    const AtomicSlot &slot = slots_[active_slot_];
    for (size_t index = 0u; index < raw_text_units; ++index) {
      if (slot.raw_text[index].load(std::memory_order_relaxed) !=
          raw_text[index]) {
        return false;
      }
    }
    return true;
  }

  bool BindActiveLineLocked(const uint16_t *raw_text, uint32_t raw_text_units,
                            uint64_t raw_text_hash,
                            uint64_t story_thread_address,
                            uint64_t text_window_through_seq) {
    if (!active_started_ || active_slot_ >= kSnapshotSlotCount ||
        !IsValidRawLineIdentity(raw_text, raw_text_units, raw_text_hash,
                                story_thread_address)) {
      QuarantineLocked(
          CaptureQuarantineReason::kLineIdentityOrFenceInvalid);
      return false;
    }
    AtomicSlot &slot = slots_[active_slot_];
    for (size_t index = 0u; index < raw_text_units; ++index) {
      const uint16_t unit = raw_text[index];
      if (unit == 0u) {
        QuarantineLocked(
            CaptureQuarantineReason::kLineIdentityOrFenceInvalid);
        return false;
      }
      slot.raw_text[index].store(unit, std::memory_order_relaxed);
    }
    active_raw_text_hash_ = raw_text_hash;
    active_raw_text_units_ = raw_text_units;
    active_story_thread_address_ = story_thread_address;
    active_text_window_through_seq_ = text_window_through_seq;
    active_has_line_ = true;
    return true;
  }

  bool SealActiveLocked() {
    if (!active_started_)
      return false;
    const uint32_t sealed_slot = active_slot_;
    const bool line_contract_valid =
        !active_has_line_ ||
        (active_raw_text_hash_ != 0u && active_raw_text_units_ != 0u &&
         active_story_thread_address_ != 0u &&
         active_text_window_through_seq_ != 0u);
    const bool exact_count_contract_valid =
        active_expected_visible_glyph_count_ == 0u ||
        (active_count_ == active_expected_visible_glyph_count_ &&
         active_next_visible_glyph_ordinal_ ==
             active_expected_visible_glyph_count_);
    const bool can_publish = active_valid_ && active_count_ != 0u &&
                              next_epoch_ != 0u && line_contract_valid &&
                              exact_count_contract_valid &&
                              !quarantined_.load(std::memory_order_acquire);
    active_started_ = false;
    active_valid_ = false;
    active_slot_ = kInvalidSlot;
    if (!can_publish)
      return false;

    AtomicSlot &slot = slots_[sealed_slot];
    slot.epoch.store(next_epoch_, std::memory_order_relaxed);
    slot.render_thread_id.store(
        bound_render_thread_id_.load(std::memory_order_relaxed),
        std::memory_order_relaxed);
    slot.story_thread_address_low.store(
        static_cast<uint32_t>(active_story_thread_address_ & 0xffffffffu),
        std::memory_order_relaxed);
    slot.story_thread_address_high.store(
        static_cast<uint32_t>(active_story_thread_address_ >> 32u),
        std::memory_order_relaxed);
    slot.text_window_through_seq_low.store(
        static_cast<uint32_t>(active_text_window_through_seq_ & 0xffffffffu),
        std::memory_order_relaxed);
    slot.text_window_through_seq_high.store(
        static_cast<uint32_t>(active_text_window_through_seq_ >> 32u),
        std::memory_order_relaxed);
    slot.raw_text_hash_low.store(
        static_cast<uint32_t>(active_raw_text_hash_ & 0xffffffffu),
        std::memory_order_relaxed);
    slot.raw_text_hash_high.store(
        static_cast<uint32_t>(active_raw_text_hash_ >> 32u),
        std::memory_order_relaxed);
    slot.raw_text_units.store(active_raw_text_units_,
                              std::memory_order_relaxed);
    slot.glyph_count.store(static_cast<uint32_t>(active_count_),
                           std::memory_order_relaxed);
    if (quarantined_.load(std::memory_order_acquire))
      return false;
    slot.sequence.store(active_sequence_ + 1u, std::memory_order_release);
    published_slot_.store(sealed_slot, std::memory_order_release);
    ++next_epoch_;
    if (quarantined_.load(std::memory_order_acquire)) {
      published_slot_.store(kInvalidSlot, std::memory_order_release);
      return false;
    }
    return true;
  }

  // Atomics are limited to callback/reset admission, publication metadata, and
  // slot payload. The remaining fields are owned only while owner_ is held by
  // either the bound render callback or a quiescent lifecycle reset.
  std::atomic<uint32_t> owner_{kOwnerIdle};
  std::atomic_flag quarantine_diagnostic_recorded_ = ATOMIC_FLAG_INIT;
  std::atomic<bool> quarantined_{false};
  std::atomic<uint32_t> bound_render_thread_id_{0u};
  std::atomic<uint32_t> quarantine_reason_{
      static_cast<uint32_t>(CaptureQuarantineReason::kNone)};
  std::atomic<uint32_t> quarantine_bound_render_thread_id_{0u};
  std::atomic<uint32_t> quarantine_conflicting_thread_id_{0u};
  std::atomic<uint32_t> published_slot_{kInvalidSlot};
  std::array<AtomicSlot, kSnapshotSlotCount> slots_ = {};
  uint32_t next_slot_ = 0u;
  uint32_t active_slot_ = kInvalidSlot;
  uint32_t active_sequence_ = 0u;
  size_t active_count_ = 0u;
  bool active_started_ = false;
  bool active_valid_ = false;
  uint32_t last_raw_utf16_index_ = 0u;
  uint64_t active_raw_text_hash_ = 0u;
  uint32_t active_raw_text_units_ = 0u;
  uint64_t active_story_thread_address_ = 0u;
  uint64_t active_text_window_through_seq_ = 0u;
  bool active_has_line_ = false;
  uint32_t active_expected_visible_glyph_count_ = 0u;
  uint32_t active_next_visible_glyph_ordinal_ = 0u;
  uint32_t next_epoch_ = 1u;
};

} // namespace fushi_voice_hook::hunex_capture_bridge
