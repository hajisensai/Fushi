#ifndef RUNNER_ATTACHED_POPUP_REARM_POLICY_H_
#define RUNNER_ATTACHED_POPUP_REARM_POLICY_H_

#include <windows.h>

#include <cstdint>

namespace fushi::attached_popup_rearm_policy {

// A dismissed popup may have temporarily owned the process-wide low-level
// hook. Re-arm the retained attached surface only after every physical/input
// tail is neutral. This is a state predicate so it stays deterministic and
// does not turn the 500 ms health timer into an input-lifecycle dependency.
struct State {
  HWND candidate_surface = nullptr;
  HWND current_target = nullptr;
  uint32_t swallowed_buttons = 0;
  uint32_t direct_shield_buttons = 0;
  uint32_t direct_shield_tail_token = 0;
  bool attached_transaction_active = false;
  bool rearm_pending = false;
};

inline bool CanRequestRearm(const State& state) {
  return state.candidate_surface != nullptr && state.current_target == nullptr &&
         state.swallowed_buttons == 0 && state.direct_shield_buttons == 0 &&
         state.direct_shield_tail_token == 0 &&
         !state.attached_transaction_active && !state.rearm_pending;
}

}  // namespace fushi::attached_popup_rearm_policy

#endif  // RUNNER_ATTACHED_POPUP_REARM_POLICY_H_
