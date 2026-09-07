#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <thread>
#include "siglus_text_owner.h"

using namespace fushi_voice_hook;

int main() {
  // DLL Ready and loopback ACK can precede engine admission by any amount.
  // Polling must not turn elapsed time or a successful audio ACK into consent.
  {
    SharedHeader h{};
    InitializeSiglusTextOwner(&h, true);
    h.hooked = 1;
    h.native_loopback_applied_seq = 1;
    SiglusLunaStartupGate gate;
    for (int i = 0; i != 10000; ++i) {
      CompleteSiglusTextOwner(&h, false, true);
      assert(!gate.ShouldAttempt(ReadSiglusTextOwner(&h)));
    }
    // Full Native admission: the hook and original are published first.
    volatile uint32_t original_ready = 0;
    std::thread worker([&] {
      AtomicStoreShared32(&original_ready, 1u);
      CompleteSiglusTextOwner(&h, true, false);
    });
    while (ReadSiglusTextOwner(&h) == SiglusTextOwner::kPending)
      assert(!gate.ShouldAttempt(ReadSiglusTextOwner(&h)));
    assert(AtomicLoadShared32(&original_ready) == 1u);
    assert(!gate.ShouldAttempt(ReadSiglusTextOwner(&h)));
    worker.join();
    assert(ReadSiglusTextOwner(&h) == SiglusTextOwner::kNativeOwned);
  }
  // LunaScenario, unsupported architecture and failed native installation
  // end pending without inventing NativeOwned. Luna gets exactly one attempt,
  // including when that attempt fails (the caller never marks initialized).
  {
    SharedHeader h{};
    CompleteSiglusTextOwner(&h, false, false);
    SiglusLunaStartupGate gate;
    assert(gate.ShouldAttempt(ReadSiglusTextOwner(&h)));
    for (int i = 0; i != 100; ++i)
      assert(!gate.ShouldAttempt(ReadSiglusTextOwner(&h)));
    assert(!PublishSiglusTextOwner(&h, SiglusTextOwner::kNativeOwned));
    assert(ReadSiglusTextOwner(&h) == SiglusTextOwner::kLunaAllowed);
  }
  // An unknown family may still succeed through the historical native text
  // fallback. It owns that hook and must not subsequently invite Luna there.
  {
    SharedHeader h{};
    CompleteSiglusTextOwner(&h, false, true);
    CompleteSiglusTextOwner(&h, true, false);
    SiglusLunaStartupGate gate;
    assert(!gate.ShouldAttempt(ReadSiglusTextOwner(&h)));
  }
  // Reattach preserves the DLL's terminal decision. Initializing another
  // helper/gate cannot reset ownership or manufacture a second native install.
  for (const auto owner : {SiglusTextOwner::kNativeOwned,
                           SiglusTextOwner::kLunaAllowed,
                           SiglusTextOwner::kNotApplicable}) {
    SharedHeader h{};
    assert(PublishSiglusTextOwner(&h, owner));
    InitializeSiglusTextOwner(&h, true);
    InitializeSiglusTextOwner(&h, false);
    CompleteSiglusTextOwner(&h, true, false);
    CompleteSiglusTextOwner(&h, false, false);
    assert(ReadSiglusTextOwner(&h) == owner);
    SiglusLunaStartupGate reattached;
    assert(reattached.ShouldAttempt(ReadSiglusTextOwner(&h)) ==
           (owner != SiglusTextOwner::kNativeOwned));
  }
  {
    SharedHeader other_engine{};
    InitializeSiglusTextOwner(&other_engine, false);
    SiglusLunaStartupGate gate;
    assert(gate.ShouldAttempt(ReadSiglusTextOwner(&other_engine)));
    assert(ReadSiglusTextOwner(&other_engine) == SiglusTextOwner::kNotApplicable);
  }
  {
    SharedHeader h{};
    SiglusLunaStartupGate gate;
    assert(!gate.ShouldAttempt(static_cast<SiglusTextOwner>(99u)));
    assert(!gate.ShouldAttempt(ReadSiglusTextOwner(nullptr)));
    assert(!PublishSiglusTextOwner(&h, SiglusTextOwner::kPending));
    assert(!PublishSiglusTextOwner(&h, static_cast<SiglusTextOwner>(99u)));
    // MH initialization/worker startup failed before text could be installed.
    CompleteSiglusTextOwner(&h, false, false);
    assert(gate.ShouldAttempt(ReadSiglusTextOwner(&h)));
  }
}
