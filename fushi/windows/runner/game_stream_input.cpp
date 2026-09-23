#include "game_stream_input.h"

#include "voice_hook_reader.h"
#include "../../../native/galgame_hook/include/voice_hook_ipc.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>

namespace fushi {
namespace {

std::string ReadString(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return std::string();
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

double ReadDouble(const flutter::EncodableMap& map, const char* key,
                  double fallback) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<double>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*value);
  }
  return fallback;
}

bool IsDown(const std::string& action) {
  return action == "down" || action == "button";
}

struct PointerButton {
  WPARAM mask;
  UINT down;
  UINT up;
};

constexpr PointerButton kPointerButtons[] = {
    {MK_LBUTTON, WM_LBUTTONDOWN, WM_LBUTTONUP},
    {MK_RBUTTON, WM_RBUTTONDOWN, WM_RBUTTONUP},
    {MK_MBUTTON, WM_MBUTTONDOWN, WM_MBUTTONUP},
};

// Returns false for an unknown button name. Absent/empty means left.
bool ResolvePointerButton(const std::string& name, PointerButton* out) {
  if (name.empty() || _stricmp(name.c_str(), "left") == 0) {
    *out = kPointerButtons[0];
    return true;
  }
  if (_stricmp(name.c_str(), "right") == 0) {
    *out = kPointerButtons[1];
    return true;
  }
  if (_stricmp(name.c_str(), "middle") == 0) {
    *out = kPointerButtons[2];
    return true;
  }
  return false;
}

constexpr double kMaxWheelNotches = 20.0;

class ScopedWindowDpiContext {
 public:
  explicit ScopedWindowDpiContext(HWND hwnd) {
    static const HMODULE user32 = GetModuleHandleW(L"user32.dll");
    static const auto get_window_context = reinterpret_cast<GetWindowContext>(
        GetProcAddress(user32, "GetWindowDpiAwarenessContext"));
    static const auto set_thread_context = reinterpret_cast<SetThreadContext>(
        GetProcAddress(user32, "SetThreadDpiAwarenessContext"));
    set_thread_context_ = set_thread_context;
    if (get_window_context == nullptr || set_thread_context_ == nullptr) return;
    const DPI_AWARENESS_CONTEXT target = get_window_context(hwnd);
    if (target != nullptr) previous_ = set_thread_context_(target);
  }
  ~ScopedWindowDpiContext() {
    if (previous_ != nullptr) set_thread_context_(previous_);
  }
  ScopedWindowDpiContext(const ScopedWindowDpiContext&) = delete;
  ScopedWindowDpiContext& operator=(const ScopedWindowDpiContext&) = delete;
  bool valid() const { return previous_ != nullptr; }

 private:
  using GetWindowContext = DPI_AWARENESS_CONTEXT(WINAPI*)(HWND);
  using SetThreadContext = DPI_AWARENESS_CONTEXT(WINAPI*)(DPI_AWARENESS_CONTEXT);
  SetThreadContext set_thread_context_ = nullptr;
  DPI_AWARENESS_CONTEXT previous_ = nullptr;
};

}  // namespace

GameStreamInput::~GameStreamInput() {
  Unbind();
}

void GameStreamInput::SetReason(std::string* reason, const char* value) const {
  if (reason != nullptr) *reason = value;
}

bool GameStreamInput::CaptureProcessIdentity(DWORD pid) {
  process_ = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process_ == nullptr) return false;
  FILETIME exit_time{};
  FILETIME kernel_time{};
  FILETIME user_time{};
  if (!GetProcessTimes(process_, &process_creation_time_, &exit_time,
                       &kernel_time, &user_time)) {
    CloseHandle(process_);
    process_ = nullptr;
    return false;
  }
  pid_ = static_cast<uint32_t>(pid);
  return true;
}

bool GameStreamInput::ProcessIdentityStillValid() const {
  if (process_ == nullptr || GetProcessId(process_) != pid_) return false;
  FILETIME created{};
  FILETIME exit_time{};
  FILETIME kernel_time{};
  FILETIME user_time{};
  return GetProcessTimes(process_, &created, &exit_time, &kernel_time,
                         &user_time) &&
         std::memcmp(&created, &process_creation_time_, sizeof(created)) == 0;
}

GameStreamWindowInfo GameStreamInput::Inspect(uintptr_t value) const {
  GameStreamWindowInfo info;
  const HWND hwnd = reinterpret_cast<HWND>(value);
  if (hwnd == nullptr || !IsWindow(hwnd)) return info;
  info.alive = true;
  info.minimized = IsIconic(hwnd) != FALSE;
  info.visible = IsWindowVisible(hwnd) != FALSE;
  info.foreground = GetForegroundWindow() == hwnd;
  RECT rect{};
  if (GetClientRect(hwnd, &rect)) {
    info.width = std::max(0L, rect.right - rect.left);
    info.height = std::max(0L, rect.bottom - rect.top);
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  info.pid = static_cast<uint32_t>(pid);
  info.process_matches = hwnd == hwnd_ && pid_ != 0 && pid == pid_ &&
                         ProcessIdentityStillValid();
  return info;
}

GameStreamWindowInfo GameStreamInput::InspectBound() const {
  return Inspect(reinterpret_cast<uintptr_t>(hwnd_));
}

bool GameStreamInput::ValidateTarget(bool require_foreground,
                                      std::string* reason) {
  if (hwnd_ == nullptr || !IsWindow(hwnd_)) {
    SetReason(reason, "window_destroyed");
    return false;
  }
  if (IsIconic(hwnd_)) {
    SetReason(reason, "window_minimized");
    return false;
  }
  if (!IsWindowVisible(hwnd_)) {
    SetReason(reason, "window_hidden");
    return false;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd_, &pid);
  if (pid == 0 || pid != pid_ || !ProcessIdentityStillValid()) {
    SetReason(reason, "process_changed");
    return false;
  }
  if (require_foreground && GetForegroundWindow() != hwnd_) {
    SetReason(reason, "window_not_foreground");
    return false;
  }
  return true;
}

bool GameStreamInput::Bind(uintptr_t value, std::string* reason) {
  Unbind();
  const HWND hwnd = reinterpret_cast<HWND>(value);
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    SetReason(reason, "window_destroyed");
    return false;
  }
  const GameStreamWindowInfo info = Inspect(value);
  if (info.minimized) {
    SetReason(reason, "window_minimized");
    return false;
  }
  if (!CaptureProcessIdentity(info.pid)) {
    SetReason(reason, "process_unavailable");
    return false;
  }
  hwnd_ = hwnd;
  if (!ValidateTarget(false, reason)) {
    Unbind();
    return false;
  }
  return true;
}

bool GameStreamInput::Activate(std::string* reason) {
  if (!ValidateTarget(false, reason)) return false;
  if (GetForegroundWindow() != hwnd_) {
    if (!SetForegroundWindow(hwnd_)) {
      SetReason(reason, "window_not_foreground");
      return false;
    }
    // Across input queues SetForegroundWindow schedules activation; a success
    // return does not mean the target has processed it yet. WM_NULL synchronizes
    // with that queue without input injection, focus retries, or queue attachment.
    // https://devblogs.microsoft.com/oldnewthing/20161118-00/?p=94745
    DWORD_PTR ignored = 0;
    if (!SendMessageTimeoutW(hwnd_, WM_NULL, 0, 0,
                             SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, 5000,
                             &ignored)) {
      SetReason(reason, "window_activation_timeout");
      return false;
    }
  }
  return ValidateTarget(true, reason);
}

void GameStreamInput::Release() {
  if (hwnd_ == nullptr) return;
  // Releasing held input is required after hiding/minimizing the target too.
  // Keep the HWND/PID/process-creation identity check, but do not reuse the
  // visibility restrictions that apply when accepting new remote input.
  const GameStreamWindowInfo target = InspectBound();
  if (!target.alive || !target.process_matches) {
    pressed_keys_.clear();
    pointer_buttons_ = 0;
    native_left_down_ = false;
    native_left_transaction_id_ = 0;
    return;
  }
  if (native_left_down_) {
    std::string ignored;
    SendNativeLeftButton(false, false, false, &ignored);
    native_left_down_ = false;
    native_left_transaction_id_ = 0;
  }
  for (const UINT key : pressed_keys_) {
    PostKey(key, false);
  }
  pressed_keys_.clear();
  // Release every held pointer button; each up carries the buttons that are
  // still held after it, matching what a real mouse would report.
  for (const PointerButton& button : kPointerButtons) {
    if ((pointer_buttons_ & button.mask) == 0) continue;
    pointer_buttons_ &= ~button.mask;
    PostMessageW(hwnd_, button.up, pointer_buttons_, 0);
  }
  pointer_buttons_ = 0;
}

void GameStreamInput::Unbind() {
  Release();
  hwnd_ = nullptr;
  pid_ = 0;
  if (process_ != nullptr) {
    CloseHandle(process_);
    process_ = nullptr;
  }
  std::memset(&process_creation_time_, 0, sizeof(process_creation_time_));
}

int GameStreamInput::NormalizedCoordinate(double value, int extent) {
  if (extent <= 1 || !std::isfinite(value)) return 0;
  const double clamped = std::clamp(value, 0.0, 1.0);
  return static_cast<int>(std::lround(clamped * static_cast<double>(extent - 1)));
}

LPARAM GameStreamInput::PointerLParam(double x, double y, int width,
                                      int height) {
  const int px = NormalizedCoordinate(x, width);
  const int py = NormalizedCoordinate(y, height);
  return MAKELPARAM(static_cast<short>(px), static_cast<short>(py));
}

int GameStreamInput::WheelDelta(double notches, bool vertical) {
  if (!std::isfinite(notches)) return 0;
  const double clamped =
      std::clamp(notches, -kMaxWheelNotches, kMaxWheelNotches);
  const long magnitude = std::lround(clamped * WHEEL_DELTA);
  return static_cast<int>(vertical ? -magnitude : magnitude);
}

UINT GameStreamInput::ResolveVirtualKey(const std::string& key) {
  if (key.size() == 1) {
    const unsigned char c = static_cast<unsigned char>(key[0]);
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9')) {
      return static_cast<UINT>(std::toupper(c));
    }
  }
  static const struct {
    const char* name;
    UINT value;
  } keys[] = {
      {"enter", VK_RETURN}, {"return", VK_RETURN}, {"escape", VK_ESCAPE},
      {"esc", VK_ESCAPE},   {"space", VK_SPACE},   {"tab", VK_TAB},
      {"backspace", VK_BACK}, {"up", VK_UP}, {"down", VK_DOWN},
      {"left", VK_LEFT}, {"right", VK_RIGHT}, {"shift", VK_SHIFT},
      {"control", VK_CONTROL}, {"ctrl", VK_CONTROL}, {"alt", VK_MENU},
      {"f1", VK_F1}, {"f2", VK_F2}, {"f3", VK_F3}, {"f4", VK_F4},
      {"f5", VK_F5}, {"f6", VK_F6}, {"f7", VK_F7}, {"f8", VK_F8},
      {"f9", VK_F9}, {"f10", VK_F10}, {"f11", VK_F11}, {"f12", VK_F12},
  };
  for (const auto& candidate : keys) {
    if (_stricmp(key.c_str(), candidate.name) == 0) return candidate.value;
  }
  return 0;
}

bool GameStreamInput::HasSgreNativeConfirmCapability() const {
  if (hwnd_ == nullptr || !IsWindow(hwnd_)) return false;
  return reinterpret_cast<uintptr_t>(GetPropW(
             hwnd_, fushi_voice_hook::kSgreDirectInputShieldReadyProperty)) ==
         fushi_voice_hook::kSgreDirectInputShieldReadyValue;
}

bool GameStreamInput::PublishNativeLeftButton(bool down, bool wait_for_ack,
                                              std::string* reason) {
  VoiceHookOpenResult opened = VoiceHookReader::Instance().Open(pid_);
  if (!opened.ok()) {
    SetReason(reason, "native_input_unavailable");
    return false;
  }
  if (down) {
    if (!native_left_down_) {
      native_left_transaction_id_ = next_native_transaction_id_++;
      if (next_native_transaction_id_ == 0) next_native_transaction_id_ = 1;
    }
  } else if (native_left_transaction_id_ == 0) {
    native_left_transaction_id_ = next_native_transaction_id_++;
    if (next_native_transaction_id_ == 0) next_native_transaction_id_ = 1;
  }
  const uint64_t deadline =
      GetTickCount64() + fushi_voice_hook::kGameStreamInputDefaultLeaseMs;
  const uint32_t active =
      down ? fushi_voice_hook::kGameStreamInputButtonLeft : 0u;
  const uint32_t seq = VoiceHookReader::Instance().PublishGameStreamInput(
      hwnd_, native_left_transaction_id_, active, deadline);
  if (seq == 0) {
    SetReason(reason, "native_input_unavailable");
    return false;
  }
  if (!wait_for_ack) {
    native_left_down_ = down;
    if (!down) native_left_transaction_id_ = 0;
    return true;
  }

  const uint64_t wait_deadline = GetTickCount64() + 250;
  while (GetTickCount64() <= wait_deadline) {
    const VoiceHookGameStreamInputStatus status =
        VoiceHookReader::Instance().GameStreamInputStatus();
    if (status.ok() && status.request_seq == seq &&
        status.transaction_id == native_left_transaction_id_ &&
        status.applied_seq == seq) {
      if (status.status == fushi_voice_hook::kGameStreamInputStatusApplied) {
        if (down && (status.observed_buttons &
                     fushi_voice_hook::kGameStreamInputButtonLeft) == 0) {
          SetReason(reason, "native_input_not_observed");
          PublishNativeLeftButton(false, false, nullptr);
          native_left_down_ = false;
          native_left_transaction_id_ = 0;
          return false;
        }
        native_left_down_ = down;
        if (!down) native_left_transaction_id_ = 0;
        return true;
      }
      SetReason(reason, status.status ==
                                fushi_voice_hook::kGameStreamInputStatusExpired
                            ? "native_input_timeout"
                            : "native_input_rejected");
      if (down) {
        PublishNativeLeftButton(false, false, nullptr);
      }
      native_left_down_ = false;
      native_left_transaction_id_ = 0;
      return false;
    }
    Sleep(4);
  }
  SetReason(reason, "native_input_timeout");
  if (down) {
    PublishNativeLeftButton(false, false, nullptr);
  }
  native_left_down_ = false;
  native_left_transaction_id_ = 0;
  return false;
}

bool GameStreamInput::SendNativeLeftButton(bool down, bool require_foreground,
                                           bool wait_for_ack,
                                           std::string* reason) {
  if (require_foreground) {
    if (!ValidateTarget(true, reason)) return false;
  } else {
    const GameStreamWindowInfo target = InspectBound();
    if (!target.alive || !target.process_matches) {
      SetReason(reason, "process_changed");
      native_left_down_ = false;
      native_left_transaction_id_ = 0;
      return false;
    }
  }
  return PublishNativeLeftButton(down, wait_for_ack, reason);
}

bool GameStreamInput::PostKey(UINT vk, bool down) {
  if (hwnd_ == nullptr) return false;
  // Games that handle window messages may inspect the documented keyboard
  // lParam, including scan code, repeat count and key-up transition bits.
  const UINT scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC_EX);
  uint32_t bits = 1u | ((scan & 0xffu) << 16);
  // Some IME layouts map arrow VKs to the shared keypad scan code without E0.
  // Our allowlist names the navigation cluster, not the numeric keypad keys.
  const bool navigation = vk >= VK_LEFT && vk <= VK_DOWN;
  if (navigation || (scan & 0xff00u) == 0xe000u) bits |= 1u << 24;
  if (!down || pressed_keys_.count(vk) != 0) bits |= 1u << 30;
  if (!down) bits |= 1u << 31;
  const UINT message = down ? WM_KEYDOWN : WM_KEYUP;
  return PostMessageW(hwnd_, message, vk, static_cast<LPARAM>(bits)) != FALSE;
}

bool GameStreamInput::PostPointer(UINT message, WPARAM flags, double x,
                                  double y) {
  if (hwnd_ == nullptr) return false;
  // PostMessage scales mouse coordinates between DPI contexts. Keep both the
  // client extent and the post in the target's context: rounding physical
  // coordinates can otherwise map the final pixel one past the logical edge.
  // Restoring before PostMessage would instead scale logical coordinates twice.
  const ScopedWindowDpiContext dpi(hwnd_);
  if (!dpi.valid()) return false;
  RECT rect{};
  if (!GetClientRect(hwnd_, &rect)) return false;
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return false;
  return PostMessageW(hwnd_, message, flags,
                      PointerLParam(x, y, width, height)) != FALSE;
}

bool GameStreamInput::PostWheel(UINT message, int delta, double x, double y) {
  if (hwnd_ == nullptr) return false;
  // Wheel messages carry screen coordinates. Map in the target's DPI context
  // for the same reason as PostPointer: client extent, ClientToScreen and the
  // post must agree on one coordinate space.
  const ScopedWindowDpiContext dpi(hwnd_);
  if (!dpi.valid()) return false;
  RECT rect{};
  if (!GetClientRect(hwnd_, &rect)) return false;
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return false;
  POINT point{NormalizedCoordinate(x, width), NormalizedCoordinate(y, height)};
  if (!ClientToScreen(hwnd_, &point)) return false;
  const WPARAM wparam =
      MAKEWPARAM(static_cast<WORD>(pointer_buttons_ & 0xffffu),
                 static_cast<WORD>(static_cast<short>(delta)));
  const LPARAM lparam =
      MAKELPARAM(static_cast<short>(point.x), static_cast<short>(point.y));
  return PostMessageW(hwnd_, message, wparam, lparam) != FALSE;
}

bool GameStreamInput::PreparePress(bool foreground_mode, bool press,
                                   std::string* reason) {
  if (!press || !foreground_mode || GetForegroundWindow() == hwnd_) {
    return true;
  }
  if (activate_for_test_ != nullptr) return activate_for_test_(this, reason);
  return Activate(reason);
}

bool GameStreamInput::SendPointer(const flutter::EncodableMap& event,
                                  const std::string& action,
                                  bool foreground_mode, std::string* reason) {
  if (HasSgreNativeConfirmCapability()) {
    SetReason(reason, "unsupported_native_pointer");
    return false;
  }
  if (action == "wheel") {
    const double dx = ReadDouble(event, "dx", 0.0);
    const double dy = ReadDouble(event, "dy", 0.0);
    if (!std::isfinite(dx) || !std::isfinite(dy) ||
        std::fabs(dx) > kMaxWheelNotches || std::fabs(dy) > kMaxWheelNotches) {
      SetReason(reason, "invalid_wheel_delta");
      return false;
    }
    const double x = ReadDouble(event, "x", 0.5);
    const double y = ReadDouble(event, "y", 0.5);
    const int vertical = WheelDelta(dy, true);
    const int horizontal = WheelDelta(dx, false);
    if (vertical != 0 && !PostWheel(WM_MOUSEWHEEL, vertical, x, y)) {
      SetReason(reason, "post_failed");
      return false;
    }
    if (horizontal != 0 && !PostWheel(WM_MOUSEHWHEEL, horizontal, x, y)) {
      SetReason(reason, "post_failed");
      return false;
    }
    return true;
  }
  const double x = ReadDouble(event, "x", 0.0);
  const double y = ReadDouble(event, "y", 0.0);
  if (action == "move") {
    if (!PostPointer(WM_MOUSEMOVE, pointer_buttons_, x, y)) {
      SetReason(reason, "post_failed");
      return false;
    }
    return true;
  }
  if (action != "down" && action != "up") {
    SetReason(reason, "invalid_pointer_action");
    return false;
  }
  PointerButton button{};
  if (!ResolvePointerButton(ReadString(event, "button"), &button)) {
    SetReason(reason, "invalid_pointer_button");
    return false;
  }
  if (action == "down") {
    if (!PreparePress(foreground_mode, true, reason)) return false;
    // Hover-dependent UI (menus, buttons that highlight first) needs the
    // cursor at the press point before the button message arrives.
    if (!PostPointer(WM_MOUSEMOVE, pointer_buttons_, x, y) ||
        !PostPointer(button.down, pointer_buttons_ | button.mask, x, y)) {
      SetReason(reason, "post_failed");
      return false;
    }
    // Track the press only once the target queue accepted it.
    pointer_buttons_ |= button.mask;
    return true;
  }
  const WPARAM remaining = pointer_buttons_ & ~button.mask;
  if (!PostPointer(button.up, remaining, x, y)) {
    // Keep the bit so Release() still sends the matching up later.
    SetReason(reason, "post_failed");
    return false;
  }
  pointer_buttons_ = remaining;
  return true;
}

bool GameStreamInput::Send(const flutter::EncodableMap& event,
                           std::string* reason) {
  // A release removes already-authorised state. Do not require foreground
  // ownership: a brief focus change must not leave a synthetic button held
  // when the game resumes polling. Identity is still checked before publishing.
  if (native_left_down_ && ReadString(event, "kind") == "gamepad" &&
      ReadString(event, "action") == "up" &&
      _stricmp(ReadString(event, "button").c_str(), "confirm") == 0) {
    return SendNativeLeftButton(false, false, false, reason);
  }
  const std::string kind_value = ReadString(event, "kind");
  const std::string action_value = ReadString(event, "action");
  if (kind_value.empty() || action_value.empty()) {
    SetReason(reason, "invalid_event");
    return false;
  }
  const std::string focus_value = ReadString(event, "inputFocus");
  if (!focus_value.empty() && focus_value != "background" &&
      focus_value != "foreground") {
    SetReason(reason, "invalid_input_focus");
    return false;
  }
  const bool foreground_mode = focus_value == "foreground";
  // Every accepted event is a PostMessage to the bound HWND (or the SGRE
  // process-local adapter), so it cannot be misdirected to whatever window
  // happens to be foreground. Requiring foreground here only blocked the
  // legitimate "game behind other windows" use and left releases stuck after
  // an alt-tab. Identity (HWND + PID + process creation time), liveness,
  // minimised and hidden checks still apply to every event; foreground mode
  // activates the window before a press instead (PreparePress).
  if (!ValidateTarget(false, reason)) return false;
  if (kind_value == "key" || kind_value == "gamepad") {
    std::string key =
        kind_value == "key" ? ReadString(event, "key")
                            : ReadString(event, "button");
    static const struct {
      const char* name;
      const char* key;
    } buttons[] = {{"dpad_up", "up"}, {"dpad_down", "down"},
                   {"dpad_left", "left"}, {"dpad_right", "right"},
                   {"confirm", "enter"}, {"cancel", "escape"},
                   {"menu", "escape"}, {"shoulder_left", "q"},
                   {"shoulder_right", "e"}};
    if (kind_value == "gamepad") {
      for (const auto& button : buttons) {
        if (_stricmp(key.c_str(), button.name) == 0) {
          key = button.key;
          break;
        }
      }
    }
    const UINT vk = ResolveVirtualKey(key);
    if (vk == 0 || (!IsDown(action_value) && action_value != "up")) {
      SetReason(reason, "invalid_key");
      return false;
    }
    const bool down = IsDown(action_value);
    const bool sgre_native_ready = HasSgreNativeConfirmCapability();
    const bool gamepad_confirm =
        kind_value == "gamepad" &&
        _stricmp(ReadString(event, "button").c_str(), "confirm") == 0;
    if (sgre_native_ready && gamepad_confirm) {
      // The SGRE adapter samples the foreground window, so its confirm keeps
      // the foreground requirement (SendNativeLeftButton validates it).
      // Foreground mode activates the window before a DOWN; background mode
      // rejects with window_not_foreground as before.
      if (!PreparePress(foreground_mode, down, reason)) return false;
      return SendNativeLeftButton(down, true, true, reason);
    }
    if (sgre_native_ready) {
      SetReason(reason, kind_value == "gamepad"
                            ? "unsupported_native_gamepad_button"
                            : "unsupported_native_key");
      return false;
    }
    if (!PreparePress(foreground_mode, down, reason)) return false;
    if (!PostKey(vk, down)) {
      SetReason(reason, "post_failed");
      return false;
    }
    if (down) {
      pressed_keys_.insert(vk);
    } else {
      pressed_keys_.erase(vk);
    }
    return true;
  }
  if (kind_value == "pointer") {
    return SendPointer(event, action_value, foreground_mode, reason);
  }
  SetReason(reason, "unsupported_input_kind");
  return false;
}

}  // namespace fushi
