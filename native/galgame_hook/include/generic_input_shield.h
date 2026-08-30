#pragma once

#include <cstddef>
#include <cstdint>

namespace fushi_voice_hook {

// Generic, engine-independent left-button filtering primitives used by the
// v19 lookup input shield.  They deliberately know nothing about HWNDs, hooks
// or shared memory: every intercepted input surface owns one latch and the
// injected coordinator decides when all latches have drained before advancing
// lookup_shield_applied_seq.
//
// Once a surface has hidden any part of a physical click it owns that click
// until the matching release and one later neutral observation.  This is the
// important invariant: ending a popup/request may never expose the tail of a
// down that the game did not see.
struct LeftButtonShieldLatch {
  bool owned = false;
  bool release_seen = false;
};

struct InputShieldFilterResult {
  bool supported = false;
  bool changed = false;
  bool pending = false;
};

inline bool IsLeftButtonShieldPending(const LeftButtonShieldLatch &latch) {
  return latch.owned;
}

// A host click can complete physically before the injected game thread sees
// the v19 down request. The coordinator must therefore own every required and
// ready input surface before acknowledging that request; waiting for an API's
// first down sample would expose an already-queued fast click after host
// publishes release.
inline void PreArmLeftButtonShieldLatch(LeftButtonShieldLatch *latch) {
  if (latch == nullptr)
    return;
  latch->owned = true;
  latch->release_seen = false;
}

inline uint32_t PreArmEligibleShieldMask(uint32_t required_mask,
                                         uint32_t ready_mask,
                                         uint32_t observed_mask) {
  // Installed does not mean consumed. Pre-arming never-observed alternatives
  // would leave their neutral tails unobservable and deadlock release.
  return required_mask & ready_mask & observed_mask;
}

inline bool IsCompleteGenericKeyStateCoverage(uint32_t coverage,
                                              uint32_t complete_coverage,
                                              bool observation_only) {
  // An observation detour may prove which API the engine calls, but a
  // pass-through return value suppresses nothing. It must never complete the
  // shield-ready surface even when every export is technically hooked.
  return !observation_only &&
         (coverage & complete_coverage) == complete_coverage;
}

enum class GenericShieldCoverageConclusion : uint8_t {
  kUnknown = 0,
  kPartial = 1,
  kKnownUncovered = 2,
  kFaulted = 3,
};

inline GenericShieldCoverageConclusion
ClassifyGenericShieldCoverage(uint32_t fault_mask, uint32_t uncovered_mask,
                              uint32_t ready_mask) {
  if (fault_mask != 0)
    return GenericShieldCoverageConclusion::kFaulted;
  if (uncovered_mask != 0)
    return GenericShieldCoverageConclusion::kKnownUncovered;
  if (ready_mask != 0)
    return GenericShieldCoverageConclusion::kPartial;
  return GenericShieldCoverageConclusion::kUnknown;
}

inline uint32_t TargetScopedGenericShieldFaultMask(uint32_t runtime_fault_mask,
                                                   uint32_t required_mask,
                                                   bool target_valid) {
  // Hook-install/runtime failures survive across requests. HWND validity does
  // not: a destroyed same-PID window faults only its own request so a newly
  // created target can perform a fresh handshake against the same hooks.
  return target_valid ? runtime_fault_mask
                      : (runtime_fault_mask | required_mask);
}

// Observe a sample which contains no left-button transition/state.  A neutral
// sample after the hidden release is the tail barrier.  request_active keeps
// ownership alive even when the physical release has already been observed;
// host publishes the zero-button request as a new transaction boundary first.
inline void ObserveLeftButtonNeutralTail(bool request_active,
                                         LeftButtonShieldLatch *latch) {
  if (latch == nullptr || request_active || !latch->owned ||
      !latch->release_seen) {
    return;
  }
  latch->owned = false;
  latch->release_seen = false;
}

// GetKeyState/GetAsyncKeyState expose the current state in bit 15.  The latter
// additionally exposes a process-wide "pressed since last call" edge in bit 0;
// callers select whether that edge is meaningful with |has_press_edge|.
// Clearing only these two bits preserves unrelated ABI bits and, critically,
// leaves every non-left virtual key untouched at the detour call site.
inline InputShieldFilterResult
FilterSampledLeftButtonState(bool request_active, bool has_press_edge,
                             int16_t *state, LeftButtonShieldLatch *latch) {
  InputShieldFilterResult out;
  if (state == nullptr || latch == nullptr)
    return out;
  out.supported = true;

  const uint16_t raw = static_cast<uint16_t>(*state);
  const bool down = (raw & 0x8000u) != 0;
  const bool pressed = has_press_edge && (raw & 0x0001u) != 0;
  const bool signal = down || pressed;

  if (request_active && signal)
    latch->owned = true;
  const bool suppress = request_active || latch->owned;
  if (suppress) {
    const uint16_t filtered = static_cast<uint16_t>(
        raw & static_cast<uint16_t>(has_press_edge ? ~0x8001u : ~0x8000u));
    *state = static_cast<int16_t>(filtered);
    out.changed = filtered != raw;

    // A high-bit clear after ownership is the sampled API's release.  Do not
    // retire on this same observation: a later neutral sample is the tail.
    if (latch->owned && !down) {
      if (latch->release_seen) {
        ObserveLeftButtonNeutralTail(request_active, latch);
      } else {
        latch->release_seen = true;
      }
    }
  }
  out.pending = latch->owned;
  return out;
}

// GetKeyboardState returns exactly 256 bytes.  VK_LBUTTON is byte 1 and only
// its high state bit is relevant.  Unknown/truncated layouts fail open.
inline InputShieldFilterResult
FilterKeyboardStateLeftButton(bool request_active, uint8_t *keys,
                              size_t key_count, LeftButtonShieldLatch *latch) {
  InputShieldFilterResult out;
  constexpr size_t kVkLButton = 1;
  constexpr size_t kKeyboardStateBytes = 256;
  if (keys == nullptr || latch == nullptr || key_count != kKeyboardStateBytes) {
    return out;
  }
  out.supported = true;
  const uint8_t raw = keys[kVkLButton];
  const bool down = (raw & 0x80u) != 0;
  if (request_active && down)
    latch->owned = true;
  const bool suppress = request_active || latch->owned;
  if (suppress) {
    keys[kVkLButton] = static_cast<uint8_t>(raw & ~0x80u);
    out.changed = keys[kVkLButton] != raw;
    if (latch->owned && !down) {
      if (latch->release_seen) {
        ObserveLeftButtonNeutralTail(request_active, latch);
      } else {
        latch->release_seen = true;
      }
    }
  }
  out.pending = latch->owned;
  return out;
}

enum class DirectInputMouseLayout : uint8_t {
  kUnknown = 0,
  kMouseState = 1,
  kMouseState2 = 2,
};

inline DirectInputMouseLayout
ClassifyDirectInputMouseLayout(size_t state_bytes) {
  // DIMOUSESTATE and DIMOUSESTATE2 both place rgbButtons at byte 12.  Only the
  // standard byte sizes are admitted; custom SetDataFormat layouts fail open
  // and are reported partial/known-uncovered by the coordinator.
  if (state_bytes == 16u)
    return DirectInputMouseLayout::kMouseState;
  if (state_bytes == 20u)
    return DirectInputMouseLayout::kMouseState2;
  return DirectInputMouseLayout::kUnknown;
}

inline InputShieldFilterResult
FilterDirectInputImmediateLeftButton(bool request_active, uint8_t *state,
                                     size_t state_bytes,
                                     LeftButtonShieldLatch *latch) {
  InputShieldFilterResult out;
  if (state == nullptr || latch == nullptr ||
      ClassifyDirectInputMouseLayout(state_bytes) ==
          DirectInputMouseLayout::kUnknown) {
    return out;
  }
  out.supported = true;
  constexpr size_t kButton0Offset = 12;
  const uint8_t raw = state[kButton0Offset];
  const bool down = (raw & 0x80u) != 0;
  if (request_active && down)
    latch->owned = true;
  const bool suppress = request_active || latch->owned;
  if (suppress) {
    // DirectInput button bytes are data, not a bit field shared with another
    // button.  Clear the complete left-button byte; axes and buttons 1..7 stay
    // byte-for-byte unchanged.
    state[kButton0Offset] = 0;
    out.changed = raw != 0;
    if (latch->owned && !down) {
      if (latch->release_seen) {
        ObserveLeftButtonNeutralTail(request_active, latch);
      } else {
        latch->release_seen = true;
      }
    }
  }
  out.pending = latch->owned;
  return out;
}

// Raw Input button flag values are fixed by RAWMOUSE.  Keep local constants so
// this header remains platform-independent and its reducer tests run without a
// Win32 message pump.
inline constexpr uint16_t kRawMouseLeftButtonDown = 0x0001u;
inline constexpr uint16_t kRawMouseLeftButtonUp = 0x0002u;

inline InputShieldFilterResult
FilterRawInputLeftButtonFlags(bool request_active, uint16_t *button_flags,
                              LeftButtonShieldLatch *latch) {
  InputShieldFilterResult out;
  if (button_flags == nullptr || latch == nullptr)
    return out;
  out.supported = true;
  const uint16_t raw = *button_flags;
  const bool down = (raw & kRawMouseLeftButtonDown) != 0;
  const bool up = (raw & kRawMouseLeftButtonUp) != 0;
  const bool signal = down || up;
  if (request_active && signal)
    latch->owned = true;
  const bool suppress = request_active || latch->owned;
  if (suppress && signal) {
    *button_flags = static_cast<uint16_t>(
        raw & ~(kRawMouseLeftButtonDown | kRawMouseLeftButtonUp));
    out.changed = *button_flags != raw;
    if (latch->owned && up)
      latch->release_seen = true;
  } else if (!signal) {
    ObserveLeftButtonNeutralTail(request_active, latch);
  }
  out.pending = latch->owned;
  return out;
}

// DIDEVICEOBJECTDATA-compatible reducer.  The real structure has additional
// timestamp/sequence/application fields; stable compaction copies the whole
// event so those fields and all non-left events remain unchanged.
template <typename Event>
inline InputShieldFilterResult FilterDirectInputBufferedLeftButton(
    bool request_active, Event *events, size_t *event_count,
    uint32_t button0_offset, LeftButtonShieldLatch *latch) {
  InputShieldFilterResult out;
  if (events == nullptr || event_count == nullptr || latch == nullptr) {
    return out;
  }
  out.supported = true;
  const size_t count = *event_count;
  size_t write = 0;
  for (size_t read = 0; read < count; ++read) {
    const bool left = events[read].dwOfs == button0_offset;
    const bool down = left && (events[read].dwData & 0x80u) != 0;
    const bool up = left && !down;
    if (request_active && left)
      latch->owned = true;
    const bool suppress = left && (request_active || latch->owned);
    if (suppress) {
      out.changed = true;
      if (up && latch->owned)
        latch->release_seen = true;
      continue;
    }
    if (write != read)
      events[write] = events[read];
    ++write;
    // A later non-left event proves the buffered tail after the removed up has
    // been drained.  It is safe to retire within the same returned batch.
    if (!left)
      ObserveLeftButtonNeutralTail(request_active, latch);
  }
  *event_count = write;
  if (count == 0)
    ObserveLeftButtonNeutralTail(request_active, latch);
  out.pending = latch->owned;
  return out;
}

} // namespace fushi_voice_hook
