#pragma once

#include <cstddef>
#include <cstdint>

namespace hibiki_voice_hook {

constexpr uint64_t kKirikiriFollowingTextWindowMs = 1500;

struct VoiceTextCandidate {
  uint64_t seq = 0;
  uint64_t timestamp_ms = 0;
  uint64_t thread_id = 0;
  uint32_t byte_len = 0;
  bool is_line = false;
};

enum class VoiceResourcePairState {
  kWait,
  kMatched,
  kUnselected,
  kExpired,
};

struct VoiceResourcePairDecision {
  VoiceResourcePairState state = VoiceResourcePairState::kWait;
  uint64_t text_event_id = 0;
};

// KiriKiri may open a voice resource shortly before Luna publishes the
// corresponding selected-thread line. Only a committed, non-empty line after
// the resource observation may create a stable marker. Missing selection and
// expiry deliberately fall back to the legacy unmarked resource filename.
inline VoiceResourcePairDecision ResolveFollowingSelectedText(
    uint64_t resource_tick_ms, uint64_t deadline_ms, uint64_t now_ms,
    uint64_t selected_thread_id, uint64_t baseline_text_seq,
    const VoiceTextCandidate* candidates, size_t candidate_count) {
  if (selected_thread_id == 0) {
    return {VoiceResourcePairState::kUnselected, 0};
  }

  uint64_t first_matching_seq = 0;
  for (size_t i = 0; i < candidate_count; ++i) {
    const VoiceTextCandidate& candidate = candidates[i];
    if (!candidate.is_line || candidate.byte_len == 0 ||
        candidate.thread_id != selected_thread_id ||
        candidate.seq <= baseline_text_seq ||
        candidate.timestamp_ms < resource_tick_ms ||
        candidate.timestamp_ms > deadline_ms) {
      continue;
    }
    if (first_matching_seq == 0 || candidate.seq < first_matching_seq) {
      first_matching_seq = candidate.seq;
    }
  }
  if (first_matching_seq != 0) {
    return {VoiceResourcePairState::kMatched, first_matching_seq};
  }
  if (now_ms >= deadline_ms) {
    return {VoiceResourcePairState::kExpired, 0};
  }
  return {VoiceResourcePairState::kWait, 0};
}

}  // namespace hibiki_voice_hook
