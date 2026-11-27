// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"。与 window_activation_policy_test.cpp 同一写法。
#undef NDEBUG

#include "../fullscreen_geometry.h"

#include <iostream>
#include <string>

namespace {

using fushi::FrameInsets;
using fushi::FullscreenClientRect;
using fushi::FullscreenExitStep;
using fushi::FullscreenUnzoomPlacement;
using fushi::FullscreenWindowRect;
using fushi::PlanFullscreenExit;
using fushi::ScreenToWorkspaceRect;

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

bool SameRect(const RECT& r, LONG left, LONG top, LONG right, LONG bottom) {
  return r.left == left && r.top == top && r.right == right &&
         r.bottom == bottom;
}

}  // namespace

int main() {
  bool ok = true;
  const RECT monitor{0, 0, 3840, 2160};

  // BUG-1933 geometry: the frame hangs off-screen by exactly the measured
  // insets (hidden-title-bar normal window: 8/1/8/8; zoomed: 8 all round).
  const FrameInsets normal{8, 1, 8, 8};
  ok &= Expect(SameRect(FullscreenWindowRect(monitor, normal), -8, -1, 3848,
                        2168),
               "normal window: frame hangs off every monitor edge");
  const FrameInsets zoomed{8, 8, 8, 8};
  ok &= Expect(SameRect(FullscreenWindowRect(monitor, zoomed), -8, -8, 3848,
                        2168),
               "zoomed window: same rule with its own insets");
  const RECT second{3840, -200, 5760, 880};
  ok &= Expect(SameRect(FullscreenWindowRect(second, normal), 3832, -201,
                        5768, 888),
               "secondary monitor with a negative origin");

  // BUG-5591: the client is the monitor even when the insets were measured
  // in another show state (zoomed before entering, normal while fullscreen).
  ok &= Expect(SameRect(FullscreenClientRect(FullscreenWindowRect(monitor,
                                                                  zoomed),
                                             monitor),
                        0, 0, 3840, 2160),
               "fullscreen client covers the monitor exactly");
  ok &= Expect(SameRect(FullscreenClientRect(RECT{100, 100, 900, 700}, monitor),
                        100, 100, 900, 700),
               "a proposed rect inside the monitor is left as is");
  ok &= Expect(
      SameRect(FullscreenClientRect(RECT{-32000, -32000, -31840, -31972},
                                    monitor),
               -32000, -32000, -32000, -32000),
      "a parked (minimized) rect collapses instead of inverting");

  // rcNormalPosition is in workspace coordinates.
  const RECT target = FullscreenWindowRect(monitor, normal);
  ok &= Expect(SameRect(ScreenToWorkspaceRect(target, monitor,
                                              RECT{0, 0, 3840, 2064}),
                        -8, -1, 3848, 2168),
               "taskbar at the bottom: workspace equals screen");
  ok &= Expect(SameRect(ScreenToWorkspaceRect(target, monitor,
                                              RECT{96, 0, 3840, 2160}),
                        -104, -1, 3752, 2168),
               "taskbar on the left shifts workspace x by its width");
  ok &= Expect(SameRect(ScreenToWorkspaceRect(target, monitor,
                                              RECT{0, 72, 3840, 2160}),
                        -8, -73, 3848, 2096),
               "taskbar at the top shifts workspace y by its height");

  // BUG-5591: one step in. Un-zooming lands on the fullscreen rectangle,
  // never on the saved pre-maximize normal rectangle (the small-window
  // detour), and is a plain restore (no restore-to-maximized flag).
  WINDOWPLACEMENT saved{};
  saved.length = sizeof(WINDOWPLACEMENT);
  saved.flags = WPF_RESTORETOMAXIMIZED;
  saved.showCmd = SW_SHOWMAXIMIZED;
  saved.rcNormalPosition = RECT{1200, 400, 2400, 1700};
  const WINDOWPLACEMENT unzoom = FullscreenUnzoomPlacement(
      saved, target, monitor, RECT{0, 0, 3840, 2064});
  ok &= Expect(unzoom.showCmd == SW_SHOWNORMAL && unzoom.flags == 0 &&
                   unzoom.length == sizeof(WINDOWPLACEMENT),
               "un-zoom is a plain SW_SHOWNORMAL placement");
  ok &= Expect(SameRect(unzoom.rcNormalPosition, -8, -1, 3848, 2168),
               "un-zoom goes straight to the fullscreen rectangle");
  ok &= Expect(saved.showCmd == SW_SHOWMAXIMIZED &&
                   SameRect(saved.rcNormalPosition, 1200, 400, 2400, 1700),
               "the saved placement is left intact for the exit");
  const WINDOWPLACEMENT unzoom_left = FullscreenUnzoomPlacement(
      saved, target, monitor, RECT{96, 0, 3840, 2160});
  ok &= Expect(SameRect(unzoom_left.rcNormalPosition, -104, -1, 3752, 2168),
               "un-zoom target converted to workspace coordinates");

  // BUG-5591: one step out. A window that was normal goes back with one
  // SetWindowPos; one that was maximized with one SetWindowPlacement (never
  // restore-to-normal followed by a separate maximize).
  ok &= Expect(PlanFullscreenExit(false, false, false) ==
                   FullscreenExitStep::kRestoreRect,
               "normal before and still normal: single rect restore");
  ok &= Expect(PlanFullscreenExit(true, false, false) ==
                   FullscreenExitStep::kRestorePlacement,
               "maximized before: single placement restore");
  ok &= Expect(PlanFullscreenExit(false, false, true) ==
                   FullscreenExitStep::kRestorePlacement,
               "minimized while fullscreen: placement restore");
  ok &= Expect(PlanFullscreenExit(false, true, false) ==
                   FullscreenExitStep::kRestorePlacement,
               "maximized while fullscreen: placement restore");

  if (!ok) {
    return 1;
  }
  std::cout << "fullscreen_geometry_test: all passed\n";
  return 0;
}
