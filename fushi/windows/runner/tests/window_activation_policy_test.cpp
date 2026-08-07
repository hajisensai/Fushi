#include "../window_activation_policy.h"

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
  bool passed = true;

  passed &= Expect(
      !ShouldRestoreChildFocus(WA_INACTIVE, true, true),
      "deactivation to an auxiliary popup must not reclaim main focus");
  passed &= Expect(ShouldRestoreChildFocus(WA_ACTIVE, true, true),
                   "programmatic main-window activation restores child focus");
  passed &= Expect(
      ShouldRestoreChildFocus(WA_CLICKACTIVE, true, true),
      "normal click activation restores child focus");
  passed &= Expect(
      ShouldRestoreChildFocus(MAKEWPARAM(WA_ACTIVE, 1), true, true),
      "the minimized flag in HIWORD must not corrupt activation decoding");
  passed &= Expect(!ShouldRestoreChildFocus(WA_ACTIVE, false, false),
                   "a destroyed child HWND must never receive focus");
  passed &= Expect(
      !ShouldRestoreChildFocus(WA_ACTIVE, true, false),
      "a recycled HWND owned by another window must never receive focus");

  if (!passed) {
    std::cerr << "window_activation_policy_test FAILED\n";
    return 1;
  }
  std::cout << "window_activation_policy_test passed\n";
  return 0;
}
