#ifndef RUNNER_IME_SPACE_DISPATCH_H_
#define RUNNER_IME_SPACE_DISPATCH_H_

#include <windows.h>

struct ImeSpaceModifierState {
  bool control_down = false;
  bool shift_down = false;
  bool alt_down = false;
  bool left_windows_down = false;
  bool right_windows_down = false;
};

using ImeSpaceDispatchCallback = void (*)(void* context);

bool IsInitialUnmodifiedImeSpaceDown(
    UINT message,
    WPARAM wparam,
    LPARAM lparam,
    const ImeSpaceModifierState& modifiers);

bool DispatchInitialUnmodifiedImeSpaceDown(
    UINT message,
    WPARAM wparam,
    LPARAM lparam,
    const ImeSpaceModifierState& modifiers,
    ImeSpaceDispatchCallback callback,
    void* context);

#endif  // RUNNER_IME_SPACE_DISPATCH_H_
