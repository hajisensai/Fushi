#pragma once

#include "voice_hook_ipc.h"

namespace fushi_voice_hook {

inline SiglusTextOwner ReadSiglusTextOwner(const SharedHeader* header) {
  return header == nullptr ? SiglusTextOwner::kPending
      : static_cast<SiglusTextOwner>(AtomicLoadShared32(&header->siglus_text_owner));
}

// Only the injected worker publishes a decision. Reusing an existing mapping
// must preserve its terminal owner, including when another helper attaches.
inline bool PublishSiglusTextOwner(SharedHeader* header, SiglusTextOwner owner) {
  if (header == nullptr || owner == SiglusTextOwner::kPending ||
      static_cast<uint32_t>(owner) >
          static_cast<uint32_t>(SiglusTextOwner::kUnavailable)) return false;
  return InterlockedCompareExchange(
      reinterpret_cast<volatile LONG*>(&header->siglus_text_owner),
      static_cast<LONG>(owner),
      static_cast<LONG>(SiglusTextOwner::kPending)) ==
      static_cast<LONG>(SiglusTextOwner::kPending);
}

inline void InitializeSiglusTextOwner(SharedHeader* header, bool is_siglus) {
  if (!is_siglus)
    PublishSiglusTextOwner(header, SiglusTextOwner::kNotApplicable);
}

// native_installed is true only after HookFn has published the original and
// enabled the hook. A successful text-only fallback owns its entry as well.
inline void CompleteSiglusTextOwner(SharedHeader* header, bool native_installed,
                                    bool identity_pending) {
  if (native_installed)
    PublishSiglusTextOwner(header, SiglusTextOwner::kNativeOwned);
  else if (!identity_pending)
    PublishSiglusTextOwner(header, SiglusTextOwner::kLunaAllowed);
}

// Used after Ready, and polled from the existing hold loop. No elapsed time
// grants ownership. Mark attempted before calling Luna, so a failed call is
// not retried on every poll. A fresh helper may consume an existing decision.
class SiglusLunaStartupGate {
 public:
  bool ShouldAttempt(SiglusTextOwner owner) {
    if (finished_) return false;
    switch (owner) {
      case SiglusTextOwner::kNotApplicable:
      case SiglusTextOwner::kLunaAllowed:
        finished_ = true;
        return true;
      case SiglusTextOwner::kNativeOwned:
      case SiglusTextOwner::kUnavailable:
        finished_ = true;
        return false;
      case SiglusTextOwner::kPending:
      default:
        return false;
    }
  }

 private:
  bool finished_ = false;
};

}  // namespace fushi_voice_hook
