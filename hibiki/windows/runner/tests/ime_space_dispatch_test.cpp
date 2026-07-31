#include "../ime_space_dispatch.h"

#include <iostream>
#include <string>

namespace {

LPARAM MakeKeyLparam(UINT scan_code, bool was_down = false) {
  UINT_PTR value = static_cast<UINT_PTR>(scan_code) << 16;
  if (was_down) {
    value |= static_cast<UINT_PTR>(1) << 30;
  }
  return static_cast<LPARAM>(value);
}

void Increment(void* context) {
  ++*static_cast<int*>(context);
}

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

bool ExpectNoDispatch(UINT message,
                      WPARAM wparam,
                      LPARAM lparam,
                      const ImeSpaceModifierState& modifiers,
                      const std::string& label) {
  int calls = 0;
  const bool dispatched = DispatchInitialUnmodifiedImeSpaceDown(
      message, wparam, lparam, modifiers, Increment, &calls);
  return Expect(!dispatched && calls == 0, label);
}

}  // namespace

int main() {
  bool passed = true;
  const ImeSpaceModifierState unmodified{};
  const LPARAM initial_space = MakeKeyLparam(0x39);

  // A U+3000 produced by an active IME arrives first as VK_PROCESSKEY carrying
  // the physical Space scan code. The later WM_CHAR and key-up must not
  // dispatch again.
  int fullwidth_calls = 0;
  passed &= Expect(
      DispatchInitialUnmodifiedImeSpaceDown(
          WM_KEYDOWN, VK_PROCESSKEY, initial_space, unmodified, Increment,
          &fullwidth_calls),
      "IME-owned initial Space key-down must dispatch");
  passed &= ExpectNoDispatch(WM_CHAR, 0x3000, initial_space, unmodified,
                             "U+3000 WM_CHAR must not double-dispatch");
  passed &= ExpectNoDispatch(WM_KEYUP, VK_PROCESSKEY, initial_space, unmodified,
                             "VK_PROCESSKEY key-up must not dispatch");
  passed &= Expect(fullwidth_calls == 1,
                   "IME U+3000 sequence must dispatch exactly once");

  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_SPACE, initial_space, unmodified,
                             "ordinary Space stays in Flutter's key path");
  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_PROCESSKEY, MakeKeyLparam(0x1e),
                             unmodified, "non-Space IME key must not dispatch");
  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_PROCESSKEY,
                             MakeKeyLparam(0x39, true), unmodified,
                             "auto-repeat must not dispatch");

  ImeSpaceModifierState modified{};
  modified.control_down = true;
  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_PROCESSKEY, initial_space, modified,
                             "Ctrl+IME Space must be released to Flutter/IME");
  modified = {};
  modified.shift_down = true;
  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_PROCESSKEY, initial_space, modified,
                             "Shift+IME Space must be released to Flutter/IME");
  modified = {};
  modified.alt_down = true;
  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_PROCESSKEY, initial_space, modified,
                             "Alt+IME Space must be released to Flutter/IME");
  modified = {};
  modified.left_windows_down = true;
  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_PROCESSKEY, initial_space, modified,
                             "Left Win+IME Space must be released");
  modified = {};
  modified.right_windows_down = true;
  passed &= ExpectNoDispatch(WM_KEYDOWN, VK_PROCESSKEY, initial_space, modified,
                             "Right Win+IME Space must be released");

  if (!passed) {
    return 1;
  }
  std::cout << "PASS: Windows IME Space native predicate/dispatch gate\n";
  return 0;
}
