// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "utils.h"

typedef LONG NTSTATUS, *PNTSTATUS;
#define STATUS_SUCCESS (0x00000000)

typedef NTSTATUS(WINAPI* RtlGetVersionPtr)(PRTL_OSVERSIONINFOW);

void Utils::EnterNativeFullscreen(HWND window) {
  if (fullscreen_) {
    return;
  }
  fullscreen_ = true;

  // The primary idea here is to revolve around |WS_OVERLAPPEDWINDOW| &
  // detect/set fullscreen based on it. In the window procedure, this is
  // separately handled. If there is no |WS_OVERLAPPEDWINDOW| style on the
  // window i.e. in fullscreen, then no area is left for |WM_NCHITTEST|,
  // accordingly client area is also expanded to fill whole monitor using
  // |WM_NCCALCSIZE|.

  auto style = ::GetWindowLongPtr(window, GWL_STYLE);
  if (style & WS_OVERLAPPEDWINDOW) {
    auto monitor = MONITORINFO{};
    auto placement = WINDOWPLACEMENT{};
    monitor.cbSize = sizeof(MONITORINFO);
    placement.length = sizeof(WINDOWPLACEMENT);
    ::GetWindowPlacement(window, &placement);
    rect_before_fullscreen_ = RECT{
        placement.rcNormalPosition.left,
        placement.rcNormalPosition.top,
        placement.rcNormalPosition.right,
        placement.rcNormalPosition.bottom,
    };
    ::GetMonitorInfo(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                     &monitor);
    ::SetWindowLongPtr(window, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
    // Hibiki BUG(桌面视频全屏锁死桌面)：媒体窗口全屏必须保持“可切走的窗口化
    // 全屏”，绝不能变成 DWM 独占式全屏（Fullscreen Optimization / 独占 MPO
    // flip）。上游默认把无边框窗口精确铺满整块显示器（rcMonitor）并落 HWND_TOP，
    // 这会被 DWM 提升为独占全屏：z-order 被霸占，用户无法 Alt+Tab / 点任务栏切到
    // 其他软件、双屏另一屏被牵连，只能靠 Win+D 或退出视频才能解锁。两处根因修复：
    //  1) 用 HWND_NOTOPMOST 显式落在非置顶层，清除任何遗留的 always-on-top，
    //     保证被激活的其他窗口能覆盖到本窗口之上。
    //  2) 窗口高度比显示器多 1px（底边落在显示器外），使窗口客户区不再精确等于
    //     显示器矩形——DWM 据此不再判定为独占全屏，恢复普通合成，窗口可被正常
    //     覆盖/切走。多出的 1px 在屏幕外不可见，视觉仍铺满整屏。
    const int monitor_width = monitor.rcMonitor.right - monitor.rcMonitor.left;
    const int monitor_height = monitor.rcMonitor.bottom - monitor.rcMonitor.top;
    ::SetWindowPos(window, HWND_NOTOPMOST, monitor.rcMonitor.left,
                   monitor.rcMonitor.top, monitor_width, monitor_height + 1,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
}

void Utils::ExitNativeFullscreen(HWND window) {
  if (!fullscreen_) {
    return;
  }
  fullscreen_ = false;

  auto style = ::GetWindowLongPtr(window, GWL_STYLE);
  if (!(style & WS_OVERLAPPEDWINDOW)) {
    ::SetWindowLongPtr(window, GWL_STYLE, style | WS_OVERLAPPEDWINDOW);
    if (::IsZoomed(window)) {
      // Refresh the parent window.
      ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                     SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                         SWP_FRAMECHANGED);
      auto rect = RECT{};
      ::GetClientRect(window, &rect);
      auto flutter_view =
          ::FindWindowEx(window, nullptr, kFlutterViewWindowClassName, nullptr);
      ::SetWindowPos(flutter_view, nullptr, rect.left, rect.top,
                     rect.right - rect.left, rect.bottom - rect.top,
                     SWP_NOACTIVATE | SWP_NOZORDER);
    } else {
      ::SetWindowPos(
          window, nullptr, rect_before_fullscreen_.left,
          rect_before_fullscreen_.top,
          rect_before_fullscreen_.right - rect_before_fullscreen_.left,
          rect_before_fullscreen_.bottom - rect_before_fullscreen_.top,
          SWP_NOACTIVATE | SWP_NOZORDER);
    }
  }
}

RTL_OSVERSIONINFOW Utils::GetWindowsVersion() {
  HMODULE handle = ::LoadLibraryW(L"ntdll.dll");
  RTL_OSVERSIONINFOW rtl_os_version_info = {0};
  rtl_os_version_info.dwBuildNumber = 0;
  rtl_os_version_info.dwOSVersionInfoSize = sizeof(rtl_os_version_info);
  if (handle) {
    RtlGetVersionPtr rtl_get_version_ptr = reinterpret_cast<RtlGetVersionPtr>(
        ::GetProcAddress(handle, "RtlGetVersion"));
    if (rtl_get_version_ptr != nullptr) {
      rtl_get_version_ptr(&rtl_os_version_info);
    }
    ::FreeLibrary(handle);
  }
  return rtl_os_version_info;
}

bool Utils::IsWindows10RTMOrGreater() {
  return GetWindowsVersion().dwBuildNumber >= 10240;
}

bool Utils::fullscreen_ = false;

RECT Utils::rect_before_fullscreen_ = RECT{};
