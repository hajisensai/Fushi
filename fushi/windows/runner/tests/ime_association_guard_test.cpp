#include "../ime_association_guard.h"

#include <iostream>
#include <string>
#include <vector>

namespace {

struct Recorder {
  std::vector<bool> requests;
  bool fail_next = false;
};

bool Record(HWND hwnd, bool enable, void* context) {
  (void)hwnd;
  auto* rec = static_cast<Recorder*>(context);
  if (rec->fail_next) {
    rec->fail_next = false;
    return false;
  }
  rec->requests.push_back(enable);
  return true;
}

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

HWND FakeHwnd() {
  return reinterpret_cast<HWND>(static_cast<UINT_PTR>(0x1234));
}

HWND SecondFakeHwnd() {
  return reinterpret_cast<HWND>(static_cast<UINT_PTR>(0x5678));
}

}  // namespace

int main() {
  bool passed = true;

  // The engine leaves the window associated, but the first request must still
  // reach the platform: a shortcut-only surface has to be dissociated once.
  {
    Recorder rec;
    ImeAssociationGuard guard(Record, &rec);
    passed &= Expect(guard.SetEnabled(FakeHwnd(), false) ==
                         ImeAssociationUpdate::kApplied,
                     "first disable must reach the platform");
    passed &= Expect(rec.requests.size() == 1 && rec.requests[0] == false,
                     "first disable records exactly one disable");
    passed &= Expect(!guard.enabled(), "guard reports disabled");
  }

  // Focus churn emits many identical notifications per frame; only transitions
  // may hit Win32.
  {
    Recorder rec;
    ImeAssociationGuard guard(Record, &rec);
    guard.SetEnabled(FakeHwnd(), false);
    passed &= Expect(guard.SetEnabled(FakeHwnd(), false) ==
                         ImeAssociationUpdate::kUnchanged,
                     "repeated disable is coalesced");
    passed &= Expect(rec.requests.size() == 1,
                     "repeated disable makes no second platform call");
  }

  // Re-enabling on text-field focus is the path that must never be swallowed --
  // if it is, the user cannot type Chinese/Japanese at all.
  {
    Recorder rec;
    ImeAssociationGuard guard(Record, &rec);
    guard.SetEnabled(FakeHwnd(), false);
    passed &= Expect(guard.SetEnabled(FakeHwnd(), true) ==
                         ImeAssociationUpdate::kApplied,
                     "re-enable on editable focus must reach the platform");
    passed &= Expect(rec.requests.size() == 2 && rec.requests[1] == true,
                     "re-enable records an enable request");
    passed &= Expect(guard.enabled(), "guard reports enabled");
  }

  // Even the very first request being "enable" must be forwarded: after a hot
  // restart the guard object is fresh but the window may be dissociated.
  {
    Recorder rec;
    ImeAssociationGuard guard(Record, &rec);
    passed &= Expect(guard.SetEnabled(FakeHwnd(), true) ==
                         ImeAssociationUpdate::kApplied,
                     "first enable must reach the platform too");
    passed &= Expect(rec.requests.size() == 1 && rec.requests[0] == true,
                     "first enable records one enable");
  }

  // A failed platform call must not be remembered as applied, otherwise the
  // coalescing above would strand the window in the wrong state forever.
  {
    Recorder rec;
    ImeAssociationGuard guard(Record, &rec);
    rec.fail_next = true;
    passed &= Expect(guard.SetEnabled(FakeHwnd(), false) ==
                         ImeAssociationUpdate::kFailed,
                     "failed platform call reports failure");
    passed &= Expect(!guard.initialised(),
                     "failed platform call does not latch state");
    passed &= Expect(guard.SetEnabled(FakeHwnd(), false) ==
                         ImeAssociationUpdate::kApplied,
                     "retry after failure reaches the platform again");
    passed &= Expect(rec.requests.size() == 1 && rec.requests[0] == false,
                     "retry records the disable");
  }

  // A Flutter view HWND can be recreated while the Dart-side desired state is
  // unchanged. Coalescing by bool alone would skip the new window and leave it
  // with the engine's default associated IME context.
  {
    Recorder rec;
    ImeAssociationGuard guard(Record, &rec);
    guard.SetEnabled(FakeHwnd(), false);
    passed &= Expect(guard.SetEnabled(SecondFakeHwnd(), false) ==
                         ImeAssociationUpdate::kApplied,
                     "same state on a new HWND must be applied");
    passed &= Expect(rec.requests.size() == 2 && !rec.requests[1],
                     "new HWND receives the current disabled state");
  }

  // A guard without a platform hook must be inert rather than claim success.
  {
    ImeAssociationGuard guard;
    passed &= Expect(guard.SetEnabled(FakeHwnd(), false) ==
                         ImeAssociationUpdate::kFailed,
                     "guard without an associate fn does nothing");
  }

  if (!passed) {
    std::cerr << "ime_association_guard_test FAILED\n";
    return 1;
  }
  std::cout << "ime_association_guard_test passed\n";
  return 0;
}
