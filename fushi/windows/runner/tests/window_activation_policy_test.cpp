// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"（CI 的 C4189「变量没人引用」正是它漏出来的痕迹）。
// 与 attached_overlayability_test.cpp 同一写法；无 assert 的文件也照写，免得
// 日后新增断言时又要重走一遍这个坑。
#undef NDEBUG

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

  passed &= Expect(
      OverlayNoActivateReply(WM_POINTERACTIVATE) == PA_NOACTIVATE,
      "BUG-2782: a touch press must not activate the lookup card");
  passed &= Expect(
      OverlayNoActivateReply(WM_MOUSEACTIVATE) == MA_NOACTIVATE,
      "BUG-2782: the pointer-down WM_MOUSEACTIVATE must not activate it");
  passed &= Expect(OverlayNoActivateReply(WM_ACTIVATE) == 0,
                   "other messages are left to the window procedure");

  const LONG_PTR overlay_style =
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
  passed &= Expect(
      ShouldVetoOverlayActivation(true, overlay_style, false, false),
      "BUG-2782: Chromium's touch SetFocus must not activate the card");
  passed &= Expect(
      !ShouldVetoOverlayActivation(true, overlay_style, false, true),
      "the context menu's explicit foreground grab must still activate");
  passed &= Expect(
      !ShouldVetoOverlayActivation(true, overlay_style, true, false),
      "focus moves inside a card that already is foreground pass");
  passed &= Expect(
      !ShouldVetoOverlayActivation(true, WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                                   false, false),
      "a lookup window without WS_EX_NOACTIVATE keeps normal activation");
  passed &= Expect(
      !ShouldVetoOverlayActivation(false, overlay_style, false, false),
      "other windows on the platform thread (main window) are never vetoed");

  if (!passed) {
    std::cerr << "window_activation_policy_test FAILED\n";
    return 1;
  }
  std::cout << "window_activation_policy_test passed\n";
  return 0;
}
