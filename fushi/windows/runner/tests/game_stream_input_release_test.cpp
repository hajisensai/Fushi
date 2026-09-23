// Run with tool/run_game_stream_input_test.ps1. The assertions remain active
// with NDEBUG: this fixture intentionally uses no standard assert() calls.
// Windows-only, isolated non-activating HWNDs; never activates a window or uses
// global SendInput. Production Release() is compiled into this executable.
#include <windows.h>
#include <cstdint>
#include <set>
#include <string>
#include <iostream>
#include <vector>
#include <flutter/encodable_value.h>
// Seed the tracked held-input state without needing foreground ownership.
// Include dependencies first so this access shim only affects the test target.
#define private public
#include "game_stream_input.h"
#include "voice_hook_reader.h"
#include "../../../native/galgame_hook/include/voice_hook_ipc.h"
#undef private

namespace fushi {
namespace {
VoiceHookOpenError g_open_error = VoiceHookOpenError::kMappingNotFound;
uint32_t g_publish_seq = 0;
VoiceHookGameStreamInputStatus g_status;
}
VoiceHookReader& VoiceHookReader::Instance() {
  static VoiceHookReader reader;
  return reader;
}
VoiceHookReader::~VoiceHookReader() = default;
VoiceHookOpenResult VoiceHookReader::Open(uint32_t) {
  VoiceHookOpenResult result;
  result.error = g_open_error;
  return result;
}
uint32_t VoiceHookReader::PublishGameStreamInput(
    HWND target, uint64_t transaction_id, uint32_t active_buttons,
    uint64_t deadline_tick_ms) {
  if (g_open_error != VoiceHookOpenError::kNone || target == nullptr ||
      transaction_id == 0 || deadline_tick_ms == 0) {
    return 0;
  }
  ++g_publish_seq;
  g_status.request_seq = g_publish_seq;
  g_status.applied_seq = g_publish_seq;
  g_status.target_hwnd = reinterpret_cast<uint64_t>(target);
  g_status.transaction_id = transaction_id;
  g_status.deadline_tick_ms = deadline_tick_ms;
  g_status.active_buttons = active_buttons;
  g_status.status = fushi_voice_hook::kGameStreamInputStatusApplied;
  g_status.observed_buttons = active_buttons;
  return g_publish_seq;
}
VoiceHookGameStreamInputStatus VoiceHookReader::GameStreamInputStatus() {
  return g_status;
}
}  // namespace fushi

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
int g_activate_calls = 0;
bool g_activate_result = false;
bool FakeActivate(fushi::GameStreamInput*, std::string* reason) {
  ++g_activate_calls;
  if (!g_activate_result && reason != nullptr) *reason = "window_not_foreground";
  return g_activate_result;
}
HWND NewSizedWindow(int x, int y, int width, int height) {
  return CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      L"STATIC", L"Fushi game-stream input fixture", WS_POPUP,
      x, y, width, height, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
}
struct Posted {
  UINT message;
  WPARAM wparam;
  LPARAM lparam;
};
// Drains queued mouse messages (WM_MOUSEMOVE..WM_MOUSEHWHEEL) in post order.
std::vector<Posted> DrainMouse(HWND hwnd) {
  std::vector<Posted> out;
  MSG message{};
  while (PeekMessageW(&message, hwnd, WM_MOUSEMOVE, 0x020E, PM_REMOVE)) {
    out.push_back({message.message, message.wParam, message.lParam});
  }
  return out;
}
flutter::EncodableMap Event(const char* kind, const char* action) {
  flutter::EncodableMap event;
  event[flutter::EncodableValue("kind")] = flutter::EncodableValue(kind);
  event[flutter::EncodableValue("action")] = flutter::EncodableValue(action);
  return event;
}
void Set(flutter::EncodableMap& event, const char* key, const char* value) {
  event[flutter::EncodableValue(key)] = flutter::EncodableValue(value);
}
void Set(flutter::EncodableMap& event, const char* key, double value) {
  event[flutter::EncodableValue(key)] = flutter::EncodableValue(value);
}
void SeedHeldInput(fushi::GameStreamInput& input, HWND hwnd) {
  // Deliver only window-targeted messages to this isolated fixture. Seed the
  // bookkeeping directly so no foreground activation/global input is needed.
  input.PostKey(VK_RETURN, true);
  input.pressed_keys_.insert(VK_RETURN);
  PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, 0);
  input.pointer_buttons_ = MK_LBUTTON;
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
  Expect(input.pressed_keys_.empty() && input.pointer_buttons_ == 0, "tracked state cleared");
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
  Expect(input.pressed_keys_.empty() && input.pointer_buttons_ == 0, "invalid identity state cleared");
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

void CheckNativeConfirmRequiresMapping() {
  HWND hwnd = NewWindow();
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  std::string reason;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd), &reason),
         "bind native fixture");
  SetPropW(hwnd, fushi_voice_hook::kSgreDirectInputShieldReadyProperty,
           reinterpret_cast<HANDLE>(static_cast<uintptr_t>(
               fushi_voice_hook::kSgreDirectInputShieldReadyValue)));
  Expect(input.HasSgreNativeConfirmCapability(),
         "native fixture advertises SGRE confirm capability");
  flutter::EncodableMap event;
  event[flutter::EncodableValue("kind")] = flutter::EncodableValue("gamepad");
  event[flutter::EncodableValue("button")] = flutter::EncodableValue("confirm");
  event[flutter::EncodableValue("action")] = flutter::EncodableValue("down");
  reason.clear();
  Expect(!input.Send(event, &reason) && reason == "window_not_foreground",
         "native confirm still requires foreground target");
  Expect(Count(hwnd, WM_KEYDOWN) == 0,
         "rejected native confirm posts no key fallback");
  {
    // Foreground mode activates first; a failed activation keeps the reason.
    g_activate_calls = 0;
    g_activate_result = false;
    input.activate_for_test_ = &FakeActivate;
    flutter::EncodableMap fg = event;
    fg[flutter::EncodableValue("inputFocus")] =
        flutter::EncodableValue("foreground");
    const uint32_t published = fushi::g_publish_seq;
    reason.clear();
    Expect(!input.Send(fg, &reason) && reason == "window_not_foreground" &&
               g_activate_calls == 1 && fushi::g_publish_seq == published,
           "foreground-mode native confirm activates before the DOWN");
    input.activate_for_test_ = nullptr;
  }
  input.hwnd_ = hwnd;
  fushi::g_open_error = fushi::VoiceHookOpenError::kMappingNotFound;
  Expect(!input.PublishNativeLeftButton(true, true, &reason) &&
             reason == "native_input_unavailable",
         "native confirm without hook mapping is a NACK");
  fushi::g_open_error = fushi::VoiceHookOpenError::kNone;
  reason.clear();
  Expect(input.PublishNativeLeftButton(true, true, &reason),
         "native confirm ACK requires injected sampled state");
  Expect(input.native_left_down_, "native confirm tracks held state after ACK");
  reason.clear();
  Expect(input.PublishNativeLeftButton(false, true, &reason),
         "native release ACK clears sampled state");
  Expect(!input.native_left_down_, "native release clears held state");
  Expect(input.PublishNativeLeftButton(true, true, &reason),
         "seed native held confirm before focus loss");
  event[flutter::EncodableValue("action")] = flutter::EncodableValue("up");
  Expect(GetForegroundWindow() != hwnd, "native release fixture stays background");
  Expect(input.Send(event, &reason),
         "held native confirm releases through Send while background");
  Expect(!input.native_left_down_ && fushi::g_status.active_buttons == 0,
         "background confirm up publishes zero mask immediately");
  Expect(Count(hwnd, WM_KEYUP) == 0 && Count(hwnd, WM_LBUTTONUP) == 0,
         "native background release never posts desktop or pointer input");
  Expect(input.PublishNativeLeftButton(true, true, &reason),
         "seed native held confirm before identity mismatch");
  const uint32_t published = fushi::g_publish_seq;
  input.pid_ ^= 0x40000000;
  Expect(!input.Send(event, &reason) && reason == "process_changed" &&
             fushi::g_publish_seq == published,
         "background native up still rejects another process identity");
  input.pid_ ^= 0x40000000;
  {
    flutter::EncodableMap pointer;
    pointer[flutter::EncodableValue("kind")] = flutter::EncodableValue("pointer");
    pointer[flutter::EncodableValue("action")] = flutter::EncodableValue("down");
    reason.clear();
    Expect(!input.Send(pointer, &reason) &&
               reason == "unsupported_native_pointer",
           "SGRE target still rejects pointer input with a specific reason");
  }
  fushi::g_open_error = fushi::VoiceHookOpenError::kMappingNotFound;
  RemovePropW(hwnd, fushi_voice_hook::kSgreDirectInputShieldReadyProperty);
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

void CheckBackgroundInputAccepted() {
  HWND hwnd = NewSizedWindow(-32000, -32000, 64, 32);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  std::string reason;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd), &reason),
         "bind background fixture");
  Expect(GetForegroundWindow() != hwnd, "background fixture is not foreground");
  auto key = Event("key", "down");
  Set(key, "key", "enter");
  reason.clear();
  Expect(input.Send(key, &reason) && Count(hwnd, WM_KEYDOWN) == 1,
         "default (background) key down posts while not foreground");
  Expect(input.pressed_keys_.count(VK_RETURN) == 1, "background key tracked");
  Set(key, "action", "up");
  Expect(input.Send(key, &reason) && Count(hwnd, WM_KEYUP) == 1 &&
             input.pressed_keys_.empty(),
         "background key up posts and clears");
  auto pad = Event("gamepad", "button");
  Set(pad, "button", "confirm");
  Set(pad, "inputFocus", "background");
  Expect(input.Send(pad, &reason) && Count(hwnd, WM_KEYDOWN) == 1,
         "explicit background gamepad confirm maps to a posted key");
  Set(pad, "action", "up");
  Expect(input.Send(pad, &reason) && Count(hwnd, WM_KEYUP) == 1,
         "background gamepad up posts");
  auto tap = Event("pointer", "down");
  Set(tap, "x", 0.5);
  Set(tap, "y", 0.5);
  Expect(input.Send(tap, &reason), "background pointer down accepted");
  Set(tap, "action", "up");
  Expect(input.Send(tap, &reason), "background pointer up accepted");
  const auto posted = DrainMouse(hwnd);
  Expect(posted.size() == 3 && posted[0].message == WM_MOUSEMOVE &&
             posted[1].message == WM_LBUTTONDOWN &&
             posted[2].message == WM_LBUTTONUP,
         "background tap posts move, down, up in order");
  auto bad = Event("key", "down");
  Set(bad, "key", "enter");
  Set(bad, "inputFocus", "sideways");
  reason.clear();
  Expect(!input.Send(bad, &reason) && reason == "invalid_input_focus" &&
             Count(hwnd, WM_KEYDOWN) == 0,
         "unknown inputFocus rejected without posting");
  // Identity checks still apply in background mode.
  ShowWindow(hwnd, SW_HIDE);
  Set(key, "action", "down");
  reason.clear();
  Expect(!input.Send(key, &reason) && reason == "window_hidden",
         "background mode still rejects a hidden window");
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  input.pid_ ^= 0x40000000;
  reason.clear();
  Expect(!input.Send(key, &reason) && reason == "process_changed",
         "background mode still rejects another process identity");
  input.pid_ ^= 0x40000000;
  input.Unbind();
  DestroyWindow(hwnd);
}

void CheckForegroundMode() {
  HWND hwnd = NewSizedWindow(-32000, -32000, 64, 32);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  std::string reason;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd), &reason),
         "bind foreground-mode fixture");
  input.activate_for_test_ = &FakeActivate;
  g_activate_calls = 0;
  g_activate_result = false;
  auto key = Event("key", "down");
  Set(key, "key", "enter");
  Set(key, "inputFocus", "foreground");
  reason.clear();
  Expect(!input.Send(key, &reason) && reason == "window_not_foreground" &&
             g_activate_calls == 1,
         "foreground-mode key down activates and reports failure reason");
  Expect(Count(hwnd, WM_KEYDOWN) == 0 && input.pressed_keys_.empty(),
         "failed activation posts nothing and tracks nothing");
  auto tap = Event("pointer", "down");
  Set(tap, "inputFocus", "foreground");
  reason.clear();
  Expect(!input.Send(tap, &reason) && reason == "window_not_foreground" &&
             g_activate_calls == 2 && DrainMouse(hwnd).empty() &&
             input.pointer_buttons_ == 0,
         "foreground-mode pointer down rejected before any post");
  Set(tap, "action", "move");
  Expect(input.Send(tap, &reason) && g_activate_calls == 2 &&
             DrainMouse(hwnd).size() == 1,
         "foreground-mode move never activates");
  Set(key, "action", "up");
  Expect(input.Send(key, &reason) && g_activate_calls == 2 &&
             Count(hwnd, WM_KEYUP) == 1,
         "foreground-mode release never activates");
  g_activate_result = true;
  Set(key, "action", "down");
  Expect(input.Send(key, &reason) && g_activate_calls == 3 &&
             Count(hwnd, WM_KEYDOWN) == 1,
         "foreground-mode key down posts after successful activation");
  input.activate_for_test_ = nullptr;
  input.Release();
  Count(hwnd, WM_KEYUP);
  input.Unbind();
  DestroyWindow(hwnd);
}

void CheckPointerButtons() {
  HWND hwnd = NewSizedWindow(-32000, -32000, 101, 51);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  std::string reason;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd), &reason),
         "bind pointer-button fixture");
  const LPARAM mid = fushi::GameStreamInput::PointerLParam(0.5, 0.5, 101, 51);
  auto right = Event("pointer", "down");
  Set(right, "button", "right");
  Set(right, "x", 0.5);
  Set(right, "y", 0.5);
  Expect(input.Send(right, &reason), "right down accepted");
  auto posted = DrainMouse(hwnd);
  Expect(posted.size() == 2 && posted[0].message == WM_MOUSEMOVE &&
             posted[0].wparam == 0 && posted[0].lparam == mid &&
             posted[1].message == WM_RBUTTONDOWN &&
             posted[1].wparam == MK_RBUTTON && posted[1].lparam == mid,
         "right down posts hover move then WM_RBUTTONDOWN at same point");
  Expect(input.pointer_buttons_ == MK_RBUTTON, "right button tracked");
  auto move = Event("pointer", "move");
  Set(move, "x", 1.0);
  Set(move, "y", 1.0);
  Expect(input.Send(move, &reason), "move while right held");
  posted = DrainMouse(hwnd);
  Expect(posted.size() == 1 && posted[0].message == WM_MOUSEMOVE &&
             posted[0].wparam == MK_RBUTTON,
         "move carries MK_RBUTTON while held");
  auto left = Event("pointer", "down");
  Set(left, "button", "left");
  Expect(input.Send(left, &reason), "left down while right held");
  posted = DrainMouse(hwnd);
  Expect(posted.size() == 2 && posted[1].message == WM_LBUTTONDOWN &&
             posted[1].wparam == (MK_LBUTTON | MK_RBUTTON) &&
             posted[0].wparam == MK_RBUTTON,
         "left down carries both held buttons");
  auto middle = Event("pointer", "down");
  Set(middle, "button", "middle");
  Expect(input.Send(middle, &reason), "middle down accepted");
  posted = DrainMouse(hwnd);
  Expect(posted.size() == 2 && posted[1].message == WM_MBUTTONDOWN &&
             posted[1].wparam == (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON),
         "middle down posts WM_MBUTTONDOWN with all flags");
  auto right_up = Event("pointer", "up");
  Set(right_up, "button", "right");
  Expect(input.Send(right_up, &reason), "right up accepted");
  posted = DrainMouse(hwnd);
  Expect(posted.size() == 1 && posted[0].message == WM_RBUTTONUP &&
             posted[0].wparam == (MK_LBUTTON | MK_MBUTTON) &&
             input.pointer_buttons_ == (MK_LBUTTON | MK_MBUTTON),
         "right up leaves remaining flags");
  Expect(input.Send(right, &reason), "right pressed again before release");
  DrainMouse(hwnd);
  input.Release();
  posted = DrainMouse(hwnd);
  Expect(posted.size() == 3 && posted[0].message == WM_LBUTTONUP &&
             posted[0].wparam == (MK_RBUTTON | MK_MBUTTON) &&
             posted[1].message == WM_RBUTTONUP &&
             posted[1].wparam == MK_MBUTTON &&
             posted[2].message == WM_MBUTTONUP && posted[2].wparam == 0,
         "Release releases every held button");
  Expect(input.pointer_buttons_ == 0, "Release clears pointer state");
  auto bogus = Event("pointer", "down");
  Set(bogus, "button", "x1");
  reason.clear();
  Expect(!input.Send(bogus, &reason) && reason == "invalid_pointer_button" &&
             DrainMouse(hwnd).empty(),
         "unknown pointer button rejected");
  // Down flag only after PostMessage succeeds: an empty client area makes
  // the post fail, so nothing may be tracked as held.
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  reason.clear();
  Expect(!input.Send(right, &reason) && reason == "post_failed" &&
             input.pointer_buttons_ == 0,
         "failed down post does not mark the button held");
  input.Unbind();
  DestroyWindow(hwnd);
}

void CheckWheel() {
  HWND hwnd = NewSizedWindow(-32000, -32000, 201, 101);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  fushi::GameStreamInput input;
  std::string reason;
  Expect(input.Bind(reinterpret_cast<uintptr_t>(hwnd), &reason),
         "bind wheel fixture");
  POINT expected{fushi::GameStreamInput::NormalizedCoordinate(0.25, 201),
                 fushi::GameStreamInput::NormalizedCoordinate(0.75, 101)};
  ClientToScreen(hwnd, &expected);
  auto wheel = Event("pointer", "wheel");
  Set(wheel, "x", 0.25);
  Set(wheel, "y", 0.75);
  Set(wheel, "dy", 1.0);
  Expect(input.Send(wheel, &reason), "wheel down accepted");
  auto posted = DrainMouse(hwnd);
  Expect(posted.size() == 1 && posted[0].message == WM_MOUSEWHEEL &&
             GET_WHEEL_DELTA_WPARAM(posted[0].wparam) == -WHEEL_DELTA &&
             LOWORD(posted[0].wparam) == 0,
         "positive dy scrolls down with negative WHEEL_DELTA");
  Expect(posted.size() == 1 &&
             static_cast<short>(LOWORD(posted[0].lparam)) == expected.x &&
             static_cast<short>(HIWORD(posted[0].lparam)) == expected.y,
         "wheel lParam carries screen coordinates of the mapped point");
  std::cout << "wheel screen point " << expected.x << "," << expected.y << "\n";
  Set(wheel, "dy", -2.0);
  Set(wheel, "dx", 0.5);
  auto right = Event("pointer", "down");
  Set(right, "button", "right");
  Expect(input.Send(right, &reason), "hold right before wheel");
  DrainMouse(hwnd);
  Expect(input.Send(wheel, &reason), "two-axis wheel accepted");
  posted = DrainMouse(hwnd);
  Expect(posted.size() == 2 && posted[0].message == WM_MOUSEWHEEL &&
             GET_WHEEL_DELTA_WPARAM(posted[0].wparam) == 2 * WHEEL_DELTA &&
             LOWORD(posted[0].wparam) == MK_RBUTTON &&
             posted[1].message == WM_MOUSEHWHEEL &&
             GET_WHEEL_DELTA_WPARAM(posted[1].wparam) == WHEEL_DELTA / 2 &&
             LOWORD(posted[1].wparam) == MK_RBUTTON,
         "negative dy scrolls up, positive dx scrolls right, flags carried");
  Expect(fushi::GameStreamInput::WheelDelta(1.0, true) == -120 &&
             fushi::GameStreamInput::WheelDelta(-1.0, false) == -120 &&
             fushi::GameStreamInput::WheelDelta(0.004, true) == 0,
         "WheelDelta sign and rounding");
  Set(wheel, "dy", 21.0);
  reason.clear();
  Expect(!input.Send(wheel, &reason) && reason == "invalid_wheel_delta" &&
             DrainMouse(hwnd).empty(),
         "wheel beyond 20 notches rejected");
  input.Release();
  DrainMouse(hwnd);
  input.Unbind();
  DestroyWindow(hwnd);
}
int main() {
  CheckAllowed("hidden target receives keyup", SW_HIDE);
  CheckAllowed("minimized target receives keyup", SW_SHOWMINNOACTIVE);
  CheckAllowed("background target receives keyup", SW_SHOWNOACTIVATE);
  CheckRejected("changed PID receives no release", 0);
  CheckRejected("changed process creation time receives no release", 1);
  CheckRejected("destroyed HWND receives no release", 2);
  CheckKeyMessageBits();
  CheckNativeConfirmRequiresMapping();
  CheckPointerDpiCoordinates();
  CheckBackgroundInputAccepted();
  CheckForegroundMode();
  CheckPointerButtons();
  CheckWheel();
  std::cout << "CHECKS " << checks << " FAILURES " << failures << "\n";
  return failures == 0 ? 0 : 1;
}
