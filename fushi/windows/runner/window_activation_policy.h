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

// BUG-2782 — a WS_EX_NOACTIVATE lookup overlay must never become the
// foreground window because of a touch / pen press on its content. The style
// only keeps mouse clicks from activating the card. A touch press on the
// composition card activates it through two independent paths:
//   1. the window receives WM_POINTERACTIVATE and then a WM_MOUSEACTIVATE whose
//      HIWORD(lParam) is WM_POINTERDOWN; DefWindowProc answers MA_ACTIVATE;
//   2. the pointer reaches WebView2 through SendPointerInput (BUG-2770) and
//      Chromium SetFocus()es its child HWND, which activates the card
//      (HCBT_SETFOCUS on the child, then HCBT_ACTIVATE on the card).
// Once the card is the foreground window the galgame behind it is not, so the
// host's "tap outside the card" consumption (it requires the game to be the
// foreground window) stops applying and the next tap advances the game.

// Path 1: the reply for the two pointer activation requests; 0 = not handled.
inline LRESULT OverlayNoActivateReply(UINT message) {
  if (message == WM_POINTERACTIVATE) return PA_NOACTIVATE;
  if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  return 0;
}

// Path 2: whether a WH_CBT focus/activation request aimed at a lookup overlay
// (or a child of it) must be vetoed. Only the explicit self-activation of the
// owner-drawn context menu, and focus moves inside a card that already is the
// foreground window, pass through.
inline bool ShouldVetoOverlayActivation(bool is_lookup_overlay,
                                        LONG_PTR ex_style,
                                        bool overlay_is_foreground,
                                        bool self_activation_allowed) {
  return is_lookup_overlay &&
         (ex_style & static_cast<LONG_PTR>(WS_EX_NOACTIVATE)) != 0 &&
         !overlay_is_foreground && !self_activation_allowed;
}

#endif  // RUNNER_WINDOW_ACTIVATION_POLICY_H_
