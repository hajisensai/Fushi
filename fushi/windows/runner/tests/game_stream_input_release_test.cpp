// Run with tool/run_game_stream_input_test.ps1. The assertions remain active
// with NDEBUG: this fixture intentionally uses no standard assert() calls.
// Windows-only, isolated offscreen HWNDs; never activates a window or uses
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
}
int main() {
  CheckAllowed("hidden target receives keyup", SW_HIDE);
  CheckAllowed("minimized target receives keyup", SW_SHOWMINNOACTIVE);
  CheckAllowed("background target receives keyup", SW_SHOWNOACTIVATE);
  CheckRejected("changed PID receives no release", 0);
  CheckRejected("changed process creation time receives no release", 1);
  CheckRejected("destroyed HWND receives no release", 2);
  std::cout << "CHECKS " << checks << " FAILURES " << failures << "\n";
  return failures == 0 ? 0 : 1;
}
