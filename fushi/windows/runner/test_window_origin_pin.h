#ifndef RUNNER_TEST_WINDOW_ORIGIN_PIN_H_
#define RUNNER_TEST_WINDOW_ORIGIN_PIN_H_

#include <windows.h>

#include <optional>

// BUG-3768: integration-test window placement (FUSHI_TEST_HIDDEN).
//
// The runner parks the hidden test window off-screen (or, with
// FUSHI_TEST_TOPMOST, at the requested evidence rect) once, at creation. Dart
// startup then calls DesktopWindowPlacement.applyInitialPlacement(), which
// setBounds()-centres the window in a work area (and maximize()s it when a
// maximized state was saved) — measured on Windows 11 26200: the window moved
// from (-21333,-21333) to an on-monitor (560,240) 1440x960 two seconds after
// launch, visible on the user's desktop for the whole test run. Every later
// Dart / plugin move (window_manager.center, mini window, DPI change) would do
// the same, so the contract "the test window stays where the runner put it" is
// enforced on the one path all of them share: WM_WINDOWPOSCHANGING. Only the
// origin is pinned; sizes still apply, so tests that resize the window (the
// minimum-size surfaces, fullscreen, maximize) keep their client geometry.

// The origin to pin, or nullopt when nothing is pinned. |onscreen| is
// FUSHI_TEST_ONSCREEN (window placed by the normal path, deliberately left
// movable — BUG-1916's maximize/restore capture relies on that); |topmost| is
// the parsed FUSHI_TEST_TOPMOST origin, which wins over both.
inline std::optional<POINT> ResolveTestWindowOriginPin(
    bool hidden,
    bool onscreen,
    std::optional<POINT> topmost,
    POINT offscreen_origin) {
  if (!hidden) {
    return std::nullopt;
  }
  if (topmost.has_value()) {
    return topmost;
  }
  if (onscreen) {
    return std::nullopt;
  }
  return offscreen_origin;
}

// Rewrites a WM_WINDOWPOSCHANGING request so the window keeps |pin| as its
// origin. A request that does not move (SWP_NOMOVE) is left untouched, and so
// is an iconic window: minimize parks it at the system's own icon position.
// Returns true when |pos| was changed.
inline bool PinWindowPosOrigin(WINDOWPOS* pos,
                               std::optional<POINT> pin,
                               bool iconic) {
  if (pos == nullptr || !pin.has_value() || iconic ||
      (pos->flags & SWP_NOMOVE) != 0) {
    return false;
  }
  if (pos->x == pin->x && pos->y == pin->y) {
    return false;
  }
  pos->x = pin->x;
  pos->y = pin->y;
  return true;
}

// BUG-3888: FUSHI_TEST_WINDOW_RECT also pins the outer size, so frame-time
// probes compare runs at the same pixel count (Dart startup placement sizes the
// window from the current work area, which follows the user's displays).
// Nothing is pinned outside test-hidden mode or without the rect.
inline std::optional<SIZE> ResolveTestWindowSizePin(bool hidden,
                                                    std::optional<SIZE> rect) {
  if (!hidden || !rect.has_value() || rect->cx <= 0 || rect->cy <= 0) {
    return std::nullopt;
  }
  return rect;
}

// Rewrites a WM_WINDOWPOSCHANGING request so the window keeps |pin| as its
// outer size. SWP_NOSIZE requests and iconic windows are left untouched.
// Returns true when |pos| was changed.
inline bool PinWindowPosSize(WINDOWPOS* pos,
                             std::optional<SIZE> pin,
                             bool iconic) {
  if (pos == nullptr || !pin.has_value() || iconic ||
      (pos->flags & SWP_NOSIZE) != 0) {
    return false;
  }
  if (pos->cx == pin->cx && pos->cy == pin->cy) {
    return false;
  }
  pos->cx = pin->cx;
  pos->cy = pin->cy;
  return true;
}

#endif  // RUNNER_TEST_WINDOW_ORIGIN_PIN_H_
