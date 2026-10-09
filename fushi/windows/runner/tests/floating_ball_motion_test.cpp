// Real native state transitions and offscreen rendering, with no real HWND,
// timer, input, or monitor dependency. The Flutter host payload has separate
// widget coverage; this test starts at FloatingBallWindow::Config.
#include <windows.h>
#include <commctrl.h>
#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <functional>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#define private public
#include "../floating_ball_window.h"
#undef private

namespace motion_test {
int timer_requests = 0;
int timer_cancellations = 0;
int menu_destroys = 0;
int presentations = 0;
int unexpected_creations = 0;

HWND BallHandle() { return reinterpret_cast<HWND>(static_cast<uintptr_t>(1)); }
HWND MenuHandle() { return reinterpret_cast<HWND>(static_cast<uintptr_t>(2)); }

UINT_PTR WINAPI Timer(HWND, UINT_PTR id, UINT, TIMERPROC) {
  ++timer_requests;
  return id;
}
BOOL WINAPI Kill(HWND, UINT_PTR) {
  ++timer_cancellations;
  return TRUE;
}
BOOL WINAPI IsTestWindow(HWND hwnd) {
  return hwnd == BallHandle() || hwnd == MenuHandle();
}
BOOL WINAPI Destroy(HWND hwnd) {
  if (hwnd == MenuHandle()) ++menu_destroys;
  return TRUE;
}
HWND WINAPI UnexpectedCreate(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int, int,
                             int, HWND, HMENU, HINSTANCE, LPVOID) {
  ++unexpected_creations;
  return nullptr;
}
BOOL WINAPI Present(HWND, HDC, const POINT*, const SIZE*, HDC, const POINT*,
                    COLORREF, const BLENDFUNCTION*, DWORD) {
  ++presentations;
  return TRUE;
}
UINT MonitorDpi(HMONITOR) { return 96; }
HMONITOR WINAPI Monitor(POINT, DWORD flags) {
  return flags == MONITOR_DEFAULTTONULL
             ? nullptr
             : reinterpret_cast<HMONITOR>(static_cast<uintptr_t>(1));
}
BOOL WINAPI MonitorInfo(HMONITOR, LPMONITORINFO info) {
  info->rcWork = {0, 0, 1920, 1080};
  info->rcMonitor = info->rcWork;
  info->dwFlags = MONITORINFOF_PRIMARY;
  return TRUE;
}

struct ScopedCom {
  const HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  ~ScopedCom() {
    if (SUCCEEDED(result)) CoUninitialize();
  }
};
}  // namespace motion_test

#define SetTimer motion_test::Timer
#define KillTimer motion_test::Kill
#define IsWindow motion_test::IsTestWindow
#define DestroyWindow motion_test::Destroy
#define CreateWindowExW motion_test::UnexpectedCreate
#define UpdateLayeredWindow motion_test::Present
#define MonitorFromPoint motion_test::Monitor
#define GetMonitorInfoW motion_test::MonitorInfo
#define FlutterDesktopGetDpiForMonitor motion_test::MonitorDpi
#include "../floating_ball_window.cpp"
#undef FlutterDesktopGetDpiForMonitor
#undef GetMonitorInfoW
#undef MonitorFromPoint
#undef UpdateLayeredWindow
#undef CreateWindowExW
#undef DestroyWindow
#undef IsWindow
#undef KillTimer
#undef SetTimer

namespace motion_test {
struct Fixture {
  FloatingBallWindow window;

  Fixture() {
    timer_requests = timer_cancellations = menu_destroys = presentations = 0;
    // Start's existing-window update path requires no class registration.
    window.classes_registered_ = true;
    window.ball_hwnd_ = BallHandle();
    PrepareMenu();
  }
  ~Fixture() {
    window.CancelAnimations();
    window.ball_hwnd_ = nullptr;
    window.menu_hwnd_ = nullptr;
    window.classes_registered_ = false;
  }
  void PrepareMenu() {
    window.menu_hwnd_ = MenuHandle();
    window.menu_ids_ = {"lookup"};
    window.menu_centers_ = {{40, 40}};
    window.menu_ball_cx_ = 40;
    window.menu_ball_cy_ = 70;
    window.menu_size_ = {80, 100};
  }
};

int checks = 0;
int failures = 0;
void Check(bool value, const char* name) {
  ++checks;
  if (!value) ++failures;
  std::cout << (value ? "PASS " : "FAIL ") << name << '\n';
}
}  // namespace motion_test

int main() {
  using namespace motion_test;
  const ScopedCom com;
  if (FAILED(com.result)) {
    std::cerr << "setup failed: CoInitializeEx=" << com.result << '\n';
    return 2;
  }
  {
    Fixture fixture;
    auto& window = fixture.window;
    Check(window.config_.animate, "legacy config defaults to animated");
    window.SetExpanded(true);
    Check(window.progress_anim_.active && window.progress_ == 0 &&
              window.progress_anim_.to == 1 &&
              window.progress_anim_.duration_ms == 280 && timer_requests == 1,
          "normal expand still schedules 280ms");
    window.CancelAnimations();
    window.progress_ = 1;
    window.SetExpanded(false);
    Check(window.progress_anim_.active &&
              window.progress_anim_.duration_ms == 190 && timer_requests == 2,
          "normal collapse still schedules 190ms");
    window.CancelAnimations();
    window.ball_left_ = 500;
    window.ball_top_ = 200;
    window.EndDrag();
    Check(window.snap_anim_.active && timer_requests == 3 &&
              window.ball_left_ != window.snap_anim_.to_left,
          "normal drag release still schedules snap");
  }
  // Reduced motion and e-ink produce the same policy, but use different colors.
  for (const bool eink : {false, true}) {
    Fixture fixture;
    auto& window = fixture.window;
    window.config_.animate = false;
    window.config_.outline = eink ? 0xFF000000 : 0;
    std::cout << "reduced policy eink=" << eink << '\n';
    window.SetExpanded(true);
    Check(window.progress_ == 1 && window.expand_target_ &&
              !window.progress_anim_.active && !window.snap_anim_.active &&
              !window.timer_running_ && timer_requests == 0 &&
              window.menu_hwnd_ == MenuHandle() && presentations > 0,
          "reduced expand reaches final geometry and renders without timer");
    int actions = 0;
    RECT action_anchor{};
    window.SetActionCallback([&](const std::string& id, const RECT& anchor) {
      if (id == "lookup") ++actions;
      action_anchor = anchor;
      Check(window.progress_ == 0 && window.menu_hwnd_ == nullptr,
            "action observes already collapsed menu");
    });
    const RECT expanded_anchor = window.BallScreenRect();
    window.RunButton(0);
    Check(actions == 1 && EqualRect(&action_anchor, &expanded_anchor) &&
              menu_destroys == 1 && !window.expand_target_ &&
              !window.progress_anim_.active && timer_requests == 0,
          "reduced action keeps expanded anchor and destroys menu once");
    int positions = 0;
    bool reported_left = false;
    double reported_fraction = -1;
    window.SetPositionCallback([&](bool left, double fraction) {
      ++positions;
      reported_left = left;
      reported_fraction = fraction;
    });
    window.ball_left_ = 500;
    window.ball_top_ = 200;
    window.EndDrag();
    const auto settled = window.CurrentGeometry();
    Check(!window.snap_anim_.active && !window.progress_anim_.active &&
              !window.timer_running_ && timer_requests == 0 &&
              window.ball_left_ == settled.CollapsedBallLeft() &&
              window.ball_top_ == settled.BallTop() && positions == 1 &&
              reported_left == window.dock_left_ &&
              reported_fraction == window.fraction_,
          "reduced snap reaches final coordinates and reports position once");
  }
  {
    Fixture fixture;
    auto& window = fixture.window;
    window.SetExpanded(true);
    window.progress_ = 0.3;
    FloatingBallWindow::Config reduced_config;
    reduced_config.animate = false;
    const bool updated = window.Start(reduced_config, false, 0.5, nullptr);
    Check(updated && window.progress_ == 0 && !window.expand_target_ &&
              !window.progress_anim_.active && !window.snap_anim_.active &&
              !window.timer_running_ && timer_cancellations == 1 &&
              window.menu_hwnd_ == nullptr,
          "live config update cancels in-flight animation and timer");
    fixture.PrepareMenu();
    const int before_reduced = timer_requests;
    window.SetExpanded(true);
    Check(window.progress_ == 1 && timer_requests == before_reduced,
          "updated running window immediately uses reduced policy");
    const bool restored = window.Start(FloatingBallWindow::Config{}, false,
                                       0.5, nullptr);
    fixture.PrepareMenu();
    window.SetExpanded(true);
    Check(restored && window.progress_anim_.active &&
              timer_requests == before_reduced + 1,
          "restoring policy re-enables animation on the same window");
  }
  Check(unexpected_creations == 0, "test never attempts to create a real window");
  std::cout << "checks=" << checks << " failed=" << failures
            << " nativeWindowsCreated=0 inputEventsSent=0 realTimersCreated=0\n";
  return failures == 0 ? 0 : 1;
}
