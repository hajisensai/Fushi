#include "game_stream_input.h"

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

void GameStreamInput::Release() {
  if (hwnd_ == nullptr) return;
  // Releasing held input is required after hiding/minimizing the target too.
  // Keep the HWND/PID/process-creation identity check, but do not reuse the
  // visibility restrictions that apply when accepting new remote input.
  const GameStreamWindowInfo target = InspectBound();
  if (!target.alive || !target.process_matches) {
    pressed_keys_.clear();
    pointer_down_ = false;
    return;
  }
  for (const UINT key : pressed_keys_) {
    PostKey(key, false);
  }
  pressed_keys_.clear();
  if (pointer_down_) {
    PostMessageW(hwnd_, WM_LBUTTONUP, 0, 0);
    pointer_down_ = false;
  }
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

bool GameStreamInput::PostKey(UINT vk, bool down) {
  if (hwnd_ == nullptr) return false;
  const UINT message = down ? WM_KEYDOWN : WM_KEYUP;
  return PostMessageW(hwnd_, message, vk, 0) != FALSE;
}

bool GameStreamInput::Send(const flutter::EncodableMap& event,
                           std::string* reason) {
  if (!ValidateTarget(true, reason)) return false;
  const std::string kind_value = ReadString(event, "kind");
  const std::string action_value = ReadString(event, "action");
  if (kind_value.empty() || action_value.empty()) {
    SetReason(reason, "invalid_event");
    return false;
  }
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
    const GameStreamWindowInfo info = Inspect(reinterpret_cast<uintptr_t>(hwnd_));
    const LPARAM point = PointerLParam(ReadDouble(event, "x", 0.0),
                                       ReadDouble(event, "y", 0.0), info.width,
                                       info.height);
    UINT message = WM_MOUSEMOVE;
    WPARAM flags = pointer_down_ ? MK_LBUTTON : 0;
    if (action_value == "down") {
      message = WM_LBUTTONDOWN;
      flags = MK_LBUTTON;
      pointer_down_ = true;
    } else if (action_value == "up") {
      message = WM_LBUTTONUP;
      flags = 0;
      pointer_down_ = false;
    } else if (action_value != "move") {
      SetReason(reason, "invalid_pointer_action");
      return false;
    }
    if (!PostMessageW(hwnd_, message, flags, point)) {
      SetReason(reason, "post_failed");
      return false;
    }
    return true;
  }
  SetReason(reason, "unsupported_input_kind");
  return false;
}

}  // namespace fushi
