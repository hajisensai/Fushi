#ifndef RUNNER_GAME_STREAM_INPUT_H_
#define RUNNER_GAME_STREAM_INPUT_H_

#include <windows.h>

#include <cstdint>
#include <set>
#include <string>

#include <flutter/encodable_value.h>

namespace fushi {

struct GameStreamWindowInfo {
  bool alive = false;
  bool minimized = false;
  bool visible = false;
  bool foreground = false;
  bool process_matches = false;
  int width = 0;
  int height = 0;
  uint32_t pid = 0;
};

// Delivers authorised input to one bound game HWND. Uses target-window messages
// (PostMessage) or the SGRE process-local confirm adapter, never global
// SendInput, so a window-targeted post cannot be misdirected to another window.
//
// `send` event contract (flutter::EncodableMap, string keys):
//   kind:       "key" | "gamepad" | "pointer"                     (required)
//   action:     key/gamepad: "down" | "button" | "up"
//               pointer:     "down" | "up" | "move" | "wheel"     (required)
//   key:        key name for kind=key (see ResolveVirtualKey)
//   button:     gamepad: dpad_*/confirm/cancel/menu/shoulder_*;
//               pointer: "left" (default) | "right" | "middle"
//   x, y:       pointer position normalised to the client area, 0..1
//               (default 0; wheel defaults to 0.5 / 0.5)
//   dx, dy:     wheel notches, |v| <= 20; dy > 0 scrolls down, dx > 0 right
//   inputFocus: "background" (default) | "foreground"
//     background: posts without requiring the window to be foreground; the
//                 game may stay behind other windows.
//     foreground: before a press (down/button) on a non-foreground window,
//                 activates it (SetForegroundWindow + bounded WM_NULL sync)
//                 and rejects when activation fails.
// Window identity, liveness, minimised and hidden checks always apply. The
// SGRE native confirm DOWN still requires the foreground window (activated
// first in foreground mode).
class GameStreamInput {
 public:
  GameStreamInput() = default;
  ~GameStreamInput();
  GameStreamInput(const GameStreamInput&) = delete;
  GameStreamInput& operator=(const GameStreamInput&) = delete;

  bool Bind(uintptr_t hwnd, std::string* reason = nullptr);
  // Invoked only by the local start button, never by remote input messages.
  bool Activate(std::string* reason = nullptr);
  bool Send(const flutter::EncodableMap& event, std::string* reason = nullptr);
  void Release();
  void Unbind();
  GameStreamWindowInfo Inspect(uintptr_t hwnd) const;
  GameStreamWindowInfo InspectBound() const;

  static int NormalizedCoordinate(double value, int extent);
  static UINT ResolveVirtualKey(const std::string& key);
  static LPARAM PointerLParam(double x, double y, int width, int height);
  // Wheel delta for [notches]: vertical positive notches scroll down, so they
  // map to negative WHEEL_DELTA multiples; horizontal positive is right.
  static int WheelDelta(double notches, bool vertical);

 private:
  bool ValidateTarget(bool require_foreground, std::string* reason);
  bool CaptureProcessIdentity(DWORD pid);
  bool ProcessIdentityStillValid() const;
  void SetReason(std::string* reason, const char* value) const;
  bool PostKey(UINT vk, bool down);
  bool PostPointer(UINT message, WPARAM flags, double x, double y);
  bool PostWheel(UINT message, int delta, double x, double y);
  bool PreparePress(bool foreground_mode, bool press, std::string* reason);
  bool SendPointer(const flutter::EncodableMap& event,
                   const std::string& action, bool foreground_mode,
                   std::string* reason);
  bool SendNativeLeftButton(bool down, bool require_foreground,
                            bool wait_for_ack, std::string* reason);
  bool PublishNativeLeftButton(bool down, bool wait_for_ack,
                               std::string* reason);
  bool HasSgreNativeConfirmCapability() const;

  HWND hwnd_ = nullptr;
  HANDLE process_ = nullptr;
  FILETIME process_creation_time_{};
  uint32_t pid_ = 0;
  std::set<UINT> pressed_keys_;
  // MK_LBUTTON | MK_RBUTTON | MK_MBUTTON currently held by remote input.
  WPARAM pointer_buttons_ = 0;
  // Test seam: replaces Activate() for foreground-mode presses so the fixture
  // never steals focus from the desktop. Always null in production.
  bool (*activate_for_test_)(GameStreamInput*, std::string*) = nullptr;
  bool native_left_down_ = false;
  uint64_t native_left_transaction_id_ = 0;
  uint64_t next_native_transaction_id_ = 1;
  std::string last_reason_;
};

}  // namespace fushi

#endif  // RUNNER_GAME_STREAM_INPUT_H_
