// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_overlayability_test.cpp 同一写法；无 assert 的文件也照写，免得
// 日后新增断言时又要重走一遍这个坑。
#undef NDEBUG

#include "../ime_association_guard.h"

#include <imm.h>

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

  // BUG-430 / BUG-853 / BUG-936: the production Win32 call against a real
  // HWND. 2026-11-05 on-device capture: while the Flutter view keeps an input
  // context (ImmGetContext != null) MS-IME turns Space into VK_PROCESSKEY and
  // any started composition swallows Ctrl+digit / PageDown too; once the view
  // has no context every key reaches Flutter as a normal WM_KEYDOWN. So the
  // observable contract is exactly "disable leaves no input context, enable
  // restores one" -- asserted here on a live window, not through a fake hook.
  {
    passed &= Expect(!ApplyImeAssociation(nullptr, false),
                     "a null HWND must report failure");
    if (GetSystemMetrics(SM_IMMENABLED) == 0) {
      // Only pre-Windows 8 systems without East Asian support report this;
      // there is no input context to detach, so the contract is vacuous.
      std::cout << "ime_association_guard_test: IMM disabled on this system, "
                   "live-HWND contract not exercised\n";
    } else {
      HWND hwnd = CreateWindowExW(0, L"STATIC", L"ime-guard-probe", WS_POPUP,
                                  0, 0, 1, 1, nullptr, nullptr,
                                  GetModuleHandleW(nullptr), nullptr);
      passed &= Expect(hwnd != nullptr, "probe window must be created");
      if (hwnd != nullptr) {
        const auto has_context = [hwnd]() {
          HIMC himc = ImmGetContext(hwnd);
          if (himc != nullptr) {
            ImmReleaseContext(hwnd, himc);
          }
          return himc != nullptr;
        };
        passed &= Expect(has_context(),
                         "a fresh window starts with the default context");
        passed &= Expect(ApplyImeAssociation(hwnd, false),
                         "disable must succeed on a live window");
        passed &= Expect(!has_context(),
                         "disable must leave the window without an input "
                         "context (otherwise the IME keeps eating shortcuts)");
        passed &= Expect(ApplyImeAssociation(hwnd, true),
                         "enable must succeed on a live window");
        passed &= Expect(has_context(),
                         "enable must restore the input context (otherwise "
                         "text fields cannot take CJK input)");
        DestroyWindow(hwnd);
      }
    }
  }

  if (!passed) {
    std::cerr << "ime_association_guard_test FAILED\n";
    return 1;
  }
  std::cout << "ime_association_guard_test passed\n";
  return 0;
}
