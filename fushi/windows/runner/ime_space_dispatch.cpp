#include "ime_space_dispatch.h"

bool IsInitialUnmodifiedImeSpaceDown(
    UINT message,
    WPARAM wparam,
    LPARAM lparam,
    const ImeSpaceModifierState& modifiers) {
  if (message != WM_KEYDOWN || wparam != VK_PROCESSKEY) {
    return false;
  }

  constexpr UINT kSpaceScanCode = 0x39;
  const UINT scan_code =
      static_cast<UINT>((static_cast<UINT_PTR>(lparam) >> 16) & 0xff);
  const bool was_down =
      ((static_cast<UINT_PTR>(lparam) >> 30) & 0x1) != 0;
  if (scan_code != kSpaceScanCode || was_down) {
    return false;
  }

  return !modifiers.control_down && !modifiers.shift_down &&
         !modifiers.alt_down && !modifiers.left_windows_down &&
         !modifiers.right_windows_down;
}

bool DispatchInitialUnmodifiedImeSpaceDown(
    UINT message,
    WPARAM wparam,
    LPARAM lparam,
    const ImeSpaceModifierState& modifiers,
    ImeSpaceDispatchCallback callback,
    void* context) {
  if (!callback ||
      !IsInitialUnmodifiedImeSpaceDown(message, wparam, lparam, modifiers)) {
    return false;
  }
  callback(context);
  return true;
}
