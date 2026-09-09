#pragma once

#include "child_process_policy.h"

namespace fushi_voice_hook {

enum class ChildWaitAction { kWait, kGame, kRootRuntime, kEnded, kTimedOut, kFailed };

// --wait-ms bounds machine work. A structurally identified interactive
// launcher instead remains pending while its verified process lineage lives.
// This policy never creates/restarts a process or admits a PID without lifetime
// evidence. Candidate stability is also required at the deadline.
class LauncherWaitState {
 public:
  LauncherWaitState(bool interactive, uint64_t started, uint32_t wait_ms)
      : interactive_(interactive), started_(started), wait_ms_(wait_ms) {}

  ChildWaitAction Observe(uint64_t now, bool observation_valid,
                          ProcessIdentity candidate, bool lineage_alive,
                          bool root_runtime) {
    if (!observation_valid || now < started_) return ChildWaitAction::kFailed;
    if (!interactive_ && now - started_ >= wait_ms_) return ChildWaitAction::kTimedOut;
    if (candidate.pid != 0 && candidate.created_at != 0) {
      if (candidate.pid == previous_.pid &&
          candidate.created_at == previous_.created_at) return ChildWaitAction::kGame;
      previous_ = candidate;
    } else {
      previous_ = {};
    }
    if (root_runtime && now - started_ >= 1000) return ChildWaitAction::kRootRuntime;
    if (interactive_) {
      return lineage_alive ? ChildWaitAction::kWait : ChildWaitAction::kEnded;
    }
    return ChildWaitAction::kWait;
  }

 private:
  bool interactive_;
  uint64_t started_;
  uint32_t wait_ms_;
  ProcessIdentity previous_{};
};
}  // namespace fushi_voice_hook
