// release 也要真断言（同 window_activation_policy_test.cpp 的写法说明）。
#undef NDEBUG

#include "../startup_reveal_policy.h"

#include <iostream>
#include <string>

namespace {

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

}  // namespace

int main() {
  using fushi::ClassifyExistingInstance;
  using fushi::ExistingInstanceState;
  using fushi::kStartupRevealDeadlineMs;
  using fushi::ShouldForceStartupReveal;
  bool passed = true;

  passed &= Expect(ClassifyExistingInstance(false, false, false, false) ==
                       ExistingInstanceState::kNoWindow,
                   "no main window found");
  passed &= Expect(ClassifyExistingInstance(true, true, true, false) ==
                       ExistingInstanceState::kShown,
                   "a visible main window is a running instance");
  passed &= Expect(ClassifyExistingInstance(true, true, false, false) ==
                       ExistingInstanceState::kShown,
                   "visible wins even before the shown property lands");
  passed &= Expect(
      ClassifyExistingInstance(true, false, false, false) ==
          ExistingInstanceState::kStarting,
      "a hidden window that was never shown is starting up, not exiting");
  passed &= Expect(ClassifyExistingInstance(true, false, true, false) ==
                       ExistingInstanceState::kExiting,
                   "a hidden window that was shown before is exiting");
  passed &= Expect(
      ClassifyExistingInstance(true, false, true, true) ==
          ExistingInstanceState::kInTray,
      "a window closed to the tray is running, not exiting");
  passed &= Expect(ClassifyExistingInstance(true, true, true, true) ==
                       ExistingInstanceState::kShown,
                   "visible wins over a stale tray property");

  passed &= Expect(!ShouldForceStartupReveal(0, false, false),
                   "no reveal right after window creation");
  passed &= Expect(
      !ShouldForceStartupReveal(kStartupRevealDeadlineMs - 1, false, false),
      "no reveal before the deadline");
  passed &= Expect(
      ShouldForceStartupReveal(kStartupRevealDeadlineMs, false, false),
      "a window still hidden at the deadline is force-revealed");
  passed &= Expect(
      !ShouldForceStartupReveal(kStartupRevealDeadlineMs * 10, true, false),
      "a window Dart already revealed is never touched");
  passed &= Expect(
      !ShouldForceStartupReveal(kStartupRevealDeadlineMs * 10, false, true),
      "the forced reveal (and its dump) happens once per process");

  // BUG-5491: the hidden-launch main window is cloaked from creation, so an
  // early show before Dart's reveal (SC_MAXIMIZE when the last session closed
  // maximized) puts nothing on screen.
  using fushi::IsWindowUserVisible;
  using fushi::ShouldCloakAtCreation;
  passed &= Expect(ShouldCloakAtCreation(false),
                   "a normal (hidden) launch is cloaked until the reveal");
  passed &= Expect(!ShouldCloakAtCreation(true),
                   "integration-test windows stay capturable, never cloaked");
  passed &= Expect(IsWindowUserVisible(true, false),
                   "visible and not cloaked is user-visible");
  passed &= Expect(!IsWindowUserVisible(true, true),
                   "a cloaked window is not user-visible even if Win32-visible");
  passed &= Expect(!IsWindowUserVisible(false, false),
                   "a hidden window is not user-visible");
  passed &= Expect(fushi::ForceStartupRevealMessage() != 0 &&
                       fushi::ForceStartupRevealMessage() ==
                           fushi::ForceStartupRevealMessage(),
                   "the force-reveal message is registered once");

  if (!passed) {
    return 1;
  }
  std::cout << "startup_reveal_policy_test: all passed\n";
  return 0;
}
