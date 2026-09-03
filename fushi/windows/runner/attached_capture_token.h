#ifndef RUNNER_ATTACHED_CAPTURE_TOKEN_H_
#define RUNNER_ATTACHED_CAPTURE_TOKEN_H_

#include <cstdint>

namespace fushi::attached_capture_token {

// Exact-token state for the invisible attached surface's screenshot fence.
// The text generation is deliberately recorded only at acquisition time: a
// sentence may advance while the compositor is hidden, but releasing the same
// token must still clear suppression and let the owner synchronize whatever
// generation is current at that point.
struct State {
  bool active = false;
  uint64_t session_epoch = 0;
  uint64_t surface_epoch = 0;
  uint64_t token = 0;
  int64_t acquired_text_generation = 0;
};

enum class BeginResult {
  kStarted,
  kSameToken,
  kBusy,
  kInvalid,
};

inline void Reset(State *state) {
  if (state != nullptr)
    *state = State{};
}

inline BeginResult Begin(State *state, uint64_t session_epoch,
                         uint64_t surface_epoch, uint64_t token,
                         int64_t text_generation) {
  if (state == nullptr || session_epoch == 0 || surface_epoch == 0 ||
      token == 0 || text_generation <= 0) {
    return BeginResult::kInvalid;
  }
  if (state->active) {
    const bool same = state->session_epoch == session_epoch &&
                      state->surface_epoch == surface_epoch &&
                      state->token == token &&
                      state->acquired_text_generation == text_generation;
    return same ? BeginResult::kSameToken : BeginResult::kBusy;
  }
  state->active = true;
  state->session_epoch = session_epoch;
  state->surface_epoch = surface_epoch;
  state->token = token;
  state->acquired_text_generation = text_generation;
  return BeginResult::kStarted;
}

// Releases only the exact active token. There is intentionally no requested
// text-generation parameter: the caller must synchronize its internally
// current generation after this succeeds, never resurrect acquisition-time
// geometry. A spent token and every token from an older epoch are stale.
inline bool Release(State *state, uint64_t session_epoch,
                    uint64_t surface_epoch, uint64_t token) {
  if (state == nullptr || !state->active || token == 0 ||
      state->session_epoch != session_epoch ||
      state->surface_epoch != surface_epoch || state->token != token) {
    return false;
  }
  Reset(state);
  return true;
}

} // namespace fushi::attached_capture_token

#endif // RUNNER_ATTACHED_CAPTURE_TOKEN_H_
