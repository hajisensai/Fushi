#ifndef RUNNER_FULLSCREEN_GEOMETRY_H_
#define RUNNER_FULLSCREEN_GEOMETRY_H_

#include <windows.h>

namespace fushi {

// Geometry of the runner-owned fullscreen (Win32Window::SetFullscreen),
// kept free of window handles so the decisions are unit-testable
// (tests/fullscreen_geometry_test.cpp).
//
// BUG-5591: entering and leaving fullscreen must be ONE geometry step with no
// DWM window animation. The previous implementation took two steps each way
// and changed the show state on both: entering from a maximized window it
// un-maximized onto the monitor rectangle (SetWindowPlacement SW_SHOWNORMAL)
// and then oversized it (SetWindowPos); leaving, it restored the
// pre-maximize normal rectangle (SetWindowPlacement SW_SHOWNORMAL) and then
// re-maximized (ShowWindow SW_MAXIMIZE). A show-state change makes DWM play
// its restore / maximize animation, which animates the window's surface, not
// the Flutter view's composition layer: on a Mica window every animated frame
// is the bare material (RGB 243 in a light theme), and the exit visibly
// detoured through the small normal rectangle in the middle of the screen.
//
// A maximized window cannot simply stay zoomed and be oversized: Windows
// keeps a zoomed window at its maximized rectangle and ignores SetWindowPos
// sizes (measured). So the show state still changes — but in ONE call that
// lands directly on the final rectangle (WINDOWPLACEMENT rcNormalPosition =
// the fullscreen rectangle on entry; the saved maximized placement on exit),
// with DWM transitions force-disabled around it.

// The window's non-client insets, measured from the live window
// (window rect vs. client origin / size).
struct FrameInsets {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;
};

// Window rectangle whose client area — with |insets| of frame around it —
// exactly covers |monitor|. The frame hangs off-screen.
inline RECT FullscreenWindowRect(const RECT& monitor,
                                 const FrameInsets& insets) {
  return RECT{monitor.left - insets.left, monitor.top - insets.top,
              monitor.right + insets.right, monitor.bottom + insets.bottom};
}

// WM_NCCALCSIZE answer while fullscreen: the client area is the monitor,
// clipped to the proposed window rectangle. Decided here rather than left to
// window_manager's hidden-title-bar reshaping: the insets were measured in
// whatever state the window was in before entering (a zoomed window's frame
// differs from a normal one's, and entering un-zooms it), so only pinning the
// client makes it cover the monitor exactly in every case.
inline RECT FullscreenClientRect(const RECT& proposed_window,
                                 const RECT& monitor) {
  RECT client{};
  client.left = proposed_window.left > monitor.left ? proposed_window.left
                                                    : monitor.left;
  client.top =
      proposed_window.top > monitor.top ? proposed_window.top : monitor.top;
  client.right = proposed_window.right < monitor.right ? proposed_window.right
                                                       : monitor.right;
  client.bottom = proposed_window.bottom < monitor.bottom
                      ? proposed_window.bottom
                      : monitor.bottom;
  if (client.right <= client.left || client.bottom <= client.top) {
    // No overlap (e.g. the parked rectangle of a minimized window): an empty
    // client at the window origin, never one outside the window.
    return RECT{proposed_window.left, proposed_window.top,
                proposed_window.left, proposed_window.top};
  }
  return client;
}

// WINDOWPLACEMENT::rcNormalPosition is in workspace coordinates: screen
// coordinates offset by the work-area origin (a taskbar on the left or top
// moves it). Converts a screen rectangle on |monitor| for that field.
// SetFullscreen verifies the landed rectangle and corrects it with a plain
// SetWindowPos, so an unusual appbar layout costs one extra move at worst.
inline RECT ScreenToWorkspaceRect(const RECT& screen,
                                  const RECT& monitor,
                                  const RECT& work) {
  const LONG dx = work.left - monitor.left;
  const LONG dy = work.top - monitor.top;
  return RECT{screen.left - dx, screen.top - dy, screen.right - dx,
              screen.bottom - dy};
}

// The single call that takes a maximized window into fullscreen: un-zoom
// straight onto the fullscreen rectangle. Its rcNormalPosition is the TARGET,
// never the saved pre-maximize normal rectangle — restoring to that first is
// the "small window" detour. |saved| (the pre-fullscreen placement) is only
// the template; the caller keeps it for the exit.
inline WINDOWPLACEMENT FullscreenUnzoomPlacement(const WINDOWPLACEMENT& saved,
                                                 const RECT& target_screen,
                                                 const RECT& monitor,
                                                 const RECT& work) {
  WINDOWPLACEMENT unzoom = saved;
  unzoom.length = sizeof(WINDOWPLACEMENT);
  unzoom.flags = 0;
  unzoom.showCmd = SW_SHOWNORMAL;
  unzoom.rcNormalPosition = ScreenToWorkspaceRect(target_screen, monitor, work);
  return unzoom;
}

enum class FullscreenExitStep {
  // One SetWindowPos back to the rectangle the window had before entering
  // (it was a normal window then and still is).
  kRestoreRect,
  // One SetWindowPlacement of the saved placement: re-maximizes a window
  // that was maximized before entering straight from the fullscreen
  // rectangle, and is the only way back for a show state that changed while
  // fullscreen (minimized, or maximized by the user / shell).
  kRestorePlacement,
};

inline FullscreenExitStep PlanFullscreenExit(bool was_zoomed,
                                             bool zoomed_now,
                                             bool iconic_now) {
  if (was_zoomed || zoomed_now || iconic_now) {
    return FullscreenExitStep::kRestorePlacement;
  }
  return FullscreenExitStep::kRestoreRect;
}

}  // namespace fushi

#endif  // RUNNER_FULLSCREEN_GEOMETRY_H_
