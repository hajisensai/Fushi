#ifndef RUNNER_WINDOW_ACTIVATION_POLICY_H_
#define RUNNER_WINDOW_ACTIVATION_POLICY_H_

#include <windows.h>

// WM_ACTIVATE packs the activation state in LOWORD(wparam) and the minimized
// bit in HIWORD(wparam). Restore the Flutter view's keyboard focus only while
// this top-level window is actually becoming active, and only when the cached
// child HWND is still live and still belongs to this exact parent window.
//
// The ownership argument matters because HWND values are recycled: a non-null,
// live handle can name an unrelated window after a child/view teardown.
inline bool ShouldRestoreChildFocus(WPARAM activation_wparam,
                                    bool child_is_live,
                                    bool child_belongs_to_window) {
  const WORD activation_state = LOWORD(activation_wparam);
  const bool becoming_active = activation_state == WA_ACTIVE ||
                               activation_state == WA_CLICKACTIVE;
  return becoming_active && child_is_live && child_belongs_to_window;
}

#endif  // RUNNER_WINDOW_ACTIVATION_POLICY_H_
