// Run with tool/run_game_stream_input_test.ps1. The assertions remain active
// with NDEBUG: this fixture intentionally uses no standard assert() calls.
// Windows-only, isolated non-activating HWNDs; never activates a window or uses
// global SendInput. Production Release() is compiled into this executable.
#include <windows.h>
#include <cstdint>
#include <set>
#include <string>
#include <iostream>
#include <flutter/encodable_value.h>
// Seed the tracked held-input state without needing foreground ownership.
// Include dependencies first so this access shim only affects the test target.
#define private public
#include "game_stream_input.h"
#undef private

namespace {
int checks = 0;
int failures = 0;
void Expect(bool ok, const char* label) {
  ++checks;
  std::cout << (ok ? "PASS " : "FAIL ") << label << "\n";
  if (!ok) ++failures;
}
HWND NewWindow() {
  return CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      L"STATIC", L"Fushi release-only regression fixture", WS_POPUP,
      -32000, -32000, 8, 8, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
}
int Count(HWND hwnd, UINT msg) {
  MSG message{};
  int count = 0;
  while (PeekMessageW(&message, hwnd, msg, msg, PM_REMOVE)) ++count;
  return count;
}
void SeedHeldInput(fushi::GameStreamInput& input, HWND hwnd) {
  // Deliver only window-targeted messages to this isolated fixture. Seed the
  // bookkeeping directly so no foreground activation/global input is needed.
  input.PostKey(VK_RETURN, true);
  input.pressed_keys_.insert(VK_RETURN);
  PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, 0);
  input.pointer_down_ = true;
  Count(hwnd, WM_KEYDOWN);
  Count(hwnd, WM_LBUTTONDOWN);
}
void CheckAllowed(const char* label, int show) {
  HWND hwnd = NewWindow();
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  std::string reason;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd), &reason), "bind fixture");
  SeedHeldInput(input, hwnd);
  ShowWindow(hwnd, show);
  input.Release();
  Expect(Count(hwnd, WM_KEYUP) == 1, label);
  Expect(Count(hwnd, WM_LBUTTONUP) == 1, "pointer released");
  Expect(input.pressed_keys_.empty() && !input.pointer_down_, "tracked state cleared");
  input.Unbind();
  DestroyWindow(hwnd);
}
void CheckRejected(const char* label, int mismatch) {
  HWND hwnd = NewWindow();
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd)), "bind identity fixture");
  SeedHeldInput(input, hwnd);
  if (mismatch == 0) input.pid_ ^= 0x40000000;
  if (mismatch == 1) input.process_creation_time_.dwLowDateTime ^= 1;
  if (mismatch == 2) DestroyWindow(hwnd);
  input.Release();
  Expect(Count(hwnd, WM_KEYUP) == 0 && Count(hwnd, WM_LBUTTONUP) == 0, label);
  Expect(input.pressed_keys_.empty() && !input.pointer_down_, "invalid identity state cleared");
  input.Unbind();
  if (mismatch != 2) DestroyWindow(hwnd);
}
void CheckKeyMessageBits() {
  HWND hwnd = NewWindow();
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd)), "bind keyboard fixture");
  MSG message{};
  input.PostKey(VK_RETURN, true);
  const bool down = PeekMessageW(&message, hwnd, WM_KEYDOWN, WM_KEYDOWN, PM_REMOVE);
  const auto down_bits = static_cast<uint32_t>(message.lParam);
  Expect(down && (down_bits & 0xffff) == 1 && ((down_bits >> 16) & 0xff) != 0,
         "keydown carries repeat count and scan code");
  Expect((down_bits & 0xc0000000u) == 0, "first keydown has no prior or release bit");
  input.pressed_keys_.insert(VK_RETURN);
  input.PostKey(VK_RETURN, true);
  PeekMessageW(&message, hwnd, WM_KEYDOWN, WM_KEYDOWN, PM_REMOVE);
  Expect((static_cast<uint32_t>(message.lParam) & 0xc0000000u) == 0x40000000u,
         "held keydown marks previous state");
  input.PostKey(VK_RETURN, false);
  const bool up = PeekMessageW(&message, hwnd, WM_KEYUP, WM_KEYUP, PM_REMOVE);
  const auto up_bits = static_cast<uint32_t>(message.lParam);
  Expect(up && (up_bits & 0xc0000000u) == 0xc0000000u,
         "keyup carries prior and release bits");
  Expect((up_bits & 0x00ffffffu) == (down_bits & 0x00ffffffu),
         "keyup preserves scan code and repeat count");
  input.PostKey(VK_RIGHT, true);
  const bool arrow = PeekMessageW(&message, hwnd, WM_KEYDOWN, WM_KEYDOWN, PM_REMOVE);
  Expect(arrow && (static_cast<uint32_t>(message.lParam) & 0x01000000u) != 0,
         "direction key carries extended scan-code bit");
  input.Unbind();
  DestroyWindow(hwnd);
}

void CheckPointerDpiCoordinates() {
  const HMODULE user32 = GetModuleHandleW(L"user32.dll");
  const auto set_context = reinterpret_cast<DPI_AWARENESS_CONTEXT(WINAPI*)(DPI_AWARENESS_CONTEXT)>(
      GetProcAddress(user32, "SetThreadDpiAwarenessContext"));
  const auto get_context = reinterpret_cast<DPI_AWARENESS_CONTEXT(WINAPI*)()>(
      GetProcAddress(user32, "GetThreadDpiAwarenessContext"));
  const auto get_window_context = reinterpret_cast<DPI_AWARENESS_CONTEXT(WINAPI*)(HWND)>(
      GetProcAddress(user32, "GetWindowDpiAwarenessContext"));
  const auto contexts_equal = reinterpret_cast<BOOL(WINAPI*)(DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT)>(
      GetProcAddress(user32, "AreDpiAwarenessContextsEqual"));
  Expect(set_context && get_context && get_window_context && contexts_equal,
         "DPI thread APIs available");
  if (!set_context || !get_context || !get_window_context || !contexts_equal) return;
  const DPI_AWARENESS_CONTEXT original =
      set_context(DPI_AWARENESS_CONTEXT_UNAWARE);
  Expect(original != nullptr, "enter target unaware DPI context");
  if (original == nullptr) return;
  HWND hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      L"STATIC", L"Fushi DPI pointer regression fixture", WS_POPUP,
      // A tiny on-monitor window exercises that monitor's scaling. Parking at
      // -32000 can use a 96-DPI virtual area and hide the rounding regression.
      80, 80, 17, 11, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  Expect(hwnd != nullptr, "create unaware target HWND");
  if (hwnd == nullptr) {
    set_context(original);
    return;
  }
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  RECT logical{};
  Expect(GetClientRect(hwnd, &logical), "read target logical client extent");
  const DPI_AWARENESS_CONTEXT target = get_window_context(hwnd);
  Expect(set_context(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
             != nullptr, "enter sender PMv2 DPI context");
  const DPI_AWARENESS_CONTEXT sender = get_context();
  fushi::GameStreamInput input;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd)), "bind unaware pointer target");
  const auto sender_extent = input.InspectBound();
  std::cout << "DPI logical " << logical.right << "x" << logical.bottom
            << " sender " << sender_extent.width << "x" << sender_extent.height << "\n";
  const double points[][2] = {{0.0, 0.0}, {0.5, 0.5}, {1.0, 1.0}, {-1.0, 2.0}};
  for (const auto& point : points) {
    Expect(input.PostPointer(WM_LBUTTONDOWN, MK_LBUTTON, point[0], point[1]),
           "post pointer in target DPI context");
    Expect(contexts_equal(get_context(), sender),
           "pointer post restores sender DPI context");
    set_context(target);
    MSG message{};
    const bool received = PeekMessageW(&message, hwnd, WM_LBUTTONDOWN,
                                       WM_LBUTTONDOWN, PM_REMOVE) != FALSE;
    const int x = static_cast<short>(LOWORD(message.lParam));
    const int y = static_cast<short>(HIWORD(message.lParam));
    Expect(received && x >= 0 && y >= 0 && x < logical.right && y < logical.bottom,
           "received pointer stays inside logical client bounds");
    Expect(received &&
               x == fushi::GameStreamInput::NormalizedCoordinate(point[0], logical.right) &&
               y == fushi::GameStreamInput::NormalizedCoordinate(point[1], logical.bottom),
           "received pointer matches target logical coordinates");
    set_context(sender);
  }
  set_context(target);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  set_context(sender);
  Expect(!input.PostPointer(WM_LBUTTONDOWN, MK_LBUTTON, 1.0, 1.0),
         "empty client pointer post rejected");
  Expect(contexts_equal(get_context(), sender),
         "early return restores sender DPI context");
  input.Unbind();
  Expect(!input.PostPointer(WM_LBUTTONDOWN, MK_LBUTTON, 1.0, 1.0),
         "unbound pointer post rejected");
  Expect(contexts_equal(get_context(), sender),
         "failed pointer post preserves sender DPI context");
  DestroyWindow(hwnd);
  set_context(original);
  Expect(contexts_equal(get_context(), original),
         "DPI fixture restores original thread context");
}
}
int main() {
  CheckAllowed("hidden target receives keyup", SW_HIDE);
  CheckAllowed("minimized target receives keyup", SW_SHOWMINNOACTIVE);
  CheckAllowed("background target receives keyup", SW_SHOWNOACTIVATE);
  CheckRejected("changed PID receives no release", 0);
  CheckRejected("changed process creation time receives no release", 1);
  CheckRejected("destroyed HWND receives no release", 2);
  CheckKeyMessageBits();
  CheckPointerDpiCoordinates();
  std::cout << "CHECKS " << checks << " FAILURES " << failures << "\n";
  return failures == 0 ? 0 : 1;
}
