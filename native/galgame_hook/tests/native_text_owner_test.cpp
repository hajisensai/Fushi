#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <thread>
#include "native_text_owner.h"

using namespace fushi_voice_hook;

int main() {
  // DLL Ready and loopback ACK can precede engine admission by any amount.
  // Polling must not turn elapsed time or a successful audio ACK into consent.
  {
    SharedHeader h{};
    InitializeNativeTextOwner(&h, true);
    h.hooked = 1;
    h.native_loopback_applied_seq = 1;
    NativeTextLunaStartupGate gate;
    for (int i = 0; i != 10000; ++i) {
      CompleteNativeTextOwner(&h, false, true);
      assert(!gate.ShouldAttempt(ReadNativeTextOwner(&h)));
    }
    // Full Native admission: the hook and original are published first.
    volatile uint32_t original_ready = 0;
    std::thread worker([&] {
      AtomicStoreShared32(&original_ready, 1u);
      CompleteNativeTextOwner(&h, true, false);
    });
    while (ReadNativeTextOwner(&h) == NativeTextOwner::kPending)
      assert(!gate.ShouldAttempt(ReadNativeTextOwner(&h)));
    assert(AtomicLoadShared32(&original_ready) == 1u);
    assert(!gate.ShouldAttempt(ReadNativeTextOwner(&h)));
    worker.join();
    assert(ReadNativeTextOwner(&h) == NativeTextOwner::kNativeOwned);
  }
  // LunaScenario, unsupported architecture and failed native installation
  // end pending without inventing NativeOwned. Luna gets exactly one attempt,
  // including when that attempt fails (the caller never marks initialized).
  {
    SharedHeader h{};
    CompleteNativeTextOwner(&h, false, false);
    NativeTextLunaStartupGate gate;
    assert(gate.ShouldAttempt(ReadNativeTextOwner(&h)));
    for (int i = 0; i != 100; ++i)
      assert(!gate.ShouldAttempt(ReadNativeTextOwner(&h)));
    assert(!PublishNativeTextOwner(&h, NativeTextOwner::kNativeOwned));
    assert(ReadNativeTextOwner(&h) == NativeTextOwner::kLunaAllowed);
  }
  // An unknown family may still succeed through the historical native text
  // fallback. It owns that hook and must not subsequently invite Luna there.
  {
    SharedHeader h{};
    CompleteNativeTextOwner(&h, false, true);
    CompleteNativeTextOwner(&h, true, false);
    NativeTextLunaStartupGate gate;
    assert(!gate.ShouldAttempt(ReadNativeTextOwner(&h)));
  }
  // Reattach preserves the DLL's terminal decision. Initializing another
  // helper/gate cannot reset ownership or manufacture a second native install.
  for (const auto owner : {NativeTextOwner::kNativeOwned,
                           NativeTextOwner::kUnavailable,
                           NativeTextOwner::kLunaAllowed,
                           NativeTextOwner::kNotApplicable}) {
    SharedHeader h{};
    assert(PublishNativeTextOwner(&h, owner));
    InitializeNativeTextOwner(&h, true);
    InitializeNativeTextOwner(&h, false);
    CompleteNativeTextOwner(&h, true, false);
    CompleteNativeTextOwner(&h, false, false);
    assert(ReadNativeTextOwner(&h) == owner);
    NativeTextLunaStartupGate reattached;
    assert(reattached.ShouldAttempt(ReadNativeTextOwner(&h)) ==
           (owner == NativeTextOwner::kNotApplicable ||
            owner == NativeTextOwner::kLunaAllowed));
  }
  {
    SharedHeader other_engine{};
    InitializeNativeTextOwner(&other_engine, false);
    NativeTextLunaStartupGate gate;
    assert(gate.ShouldAttempt(ReadNativeTextOwner(&other_engine)));
    assert(ReadNativeTextOwner(&other_engine) == NativeTextOwner::kNotApplicable);
  }
  // Failed rollback must terminate pending without inviting a second patcher
  // or pretending the incomplete native sensor is ready. Reattach cannot retry.
  {
    SharedHeader failed{};
    assert(PublishNativeTextOwner(&failed, NativeTextOwner::kUnavailable));
    CompleteNativeTextOwner(&failed, false, false);
    NativeTextLunaStartupGate gate;
    assert(!gate.ShouldAttempt(ReadNativeTextOwner(&failed)));
    assert(ReadNativeTextOwner(&failed) == NativeTextOwner::kUnavailable);
    assert(!gate.ShouldAttempt(NativeTextOwner::kLunaAllowed));
  }
  {
    SharedHeader h{};
    NativeTextLunaStartupGate gate;
    assert(!gate.ShouldAttempt(static_cast<NativeTextOwner>(99u)));
    assert(!gate.ShouldAttempt(ReadNativeTextOwner(nullptr)));
    assert(!PublishNativeTextOwner(&h, NativeTextOwner::kPending));
    assert(!PublishNativeTextOwner(&h, static_cast<NativeTextOwner>(99u)));
    // MH initialization/worker startup failed before text could be installed.
    CompleteNativeTextOwner(&h, false, false);
    assert(gate.ShouldAttempt(ReadNativeTextOwner(&h)));
  }
}
