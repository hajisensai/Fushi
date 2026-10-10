#pragma once

#include "voice_hook_ipc.h"

namespace fushi_voice_hook {

inline NativeTextOwner ReadNativeTextOwner(const SharedHeader* header) {
  return header == nullptr ? NativeTextOwner::kPending
      : static_cast<NativeTextOwner>(AtomicLoadShared32(&header->native_text_owner));
}

// Only the injected worker publishes a decision. Reusing an existing mapping
// must preserve its terminal owner, including when another helper attaches.
inline bool PublishNativeTextOwner(SharedHeader* header, NativeTextOwner owner) {
  if (header == nullptr || owner == NativeTextOwner::kPending ||
      static_cast<uint32_t>(owner) >
          static_cast<uint32_t>(NativeTextOwner::kUnavailable)) return false;
  return InterlockedCompareExchange(
      reinterpret_cast<volatile LONG*>(&header->native_text_owner),
      static_cast<LONG>(owner),
      static_cast<LONG>(NativeTextOwner::kPending)) ==
      static_cast<LONG>(NativeTextOwner::kPending);
}

// An engine whose adapter can own the text lane natively (SiglusEngine,
// LucaSystem) leaves Pending; every other engine lets Luna start at once.
inline void InitializeNativeTextOwner(SharedHeader* header,
                                      bool native_candidate) {
  if (!native_candidate)
    PublishNativeTextOwner(header, NativeTextOwner::kNotApplicable);
}

// native_installed is true only after HookFn has published the original and
// enabled the hook. A successful text-only fallback owns its entry as well.
inline void CompleteNativeTextOwner(SharedHeader* header, bool native_installed,
                                    bool identity_pending) {
  if (native_installed)
    PublishNativeTextOwner(header, NativeTextOwner::kNativeOwned);
  else if (!identity_pending)
    PublishNativeTextOwner(header, NativeTextOwner::kLunaAllowed);
}

// Used after Ready, and polled from the existing hold loop. No elapsed time
// grants ownership. Mark attempted before calling Luna, so a failed call is
// not retried on every poll. A fresh helper may consume an existing decision.
class NativeTextLunaStartupGate {
 public:
  bool ShouldAttempt(NativeTextOwner owner) {
    if (finished_) return false;
    switch (owner) {
      case NativeTextOwner::kNotApplicable:
      case NativeTextOwner::kLunaAllowed:
        finished_ = true;
        return true;
      case NativeTextOwner::kNativeOwned:
      case NativeTextOwner::kUnavailable:
        finished_ = true;
        return false;
      case NativeTextOwner::kPending:
      default:
        return false;
    }
  }

 private:
  bool finished_ = false;
};

}  // namespace fushi_voice_hook
