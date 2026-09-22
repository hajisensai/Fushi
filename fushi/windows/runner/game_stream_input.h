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

// Delivers only explicitly authorised, foreground-window input to one game
// HWND.  This class intentionally uses PostMessage and never SendInput: a
// remote client must not be able to affect the desktop or another window.
class GameStreamInput {
 public:
  GameStreamInput() = default;
  ~GameStreamInput();
  GameStreamInput(const GameStreamInput&) = delete;
  GameStreamInput& operator=(const GameStreamInput&) = delete;

  bool Bind(uintptr_t hwnd, std::string* reason = nullptr);
  bool Send(const flutter::EncodableMap& event, std::string* reason = nullptr);
  void Release();
  void Unbind();
  GameStreamWindowInfo Inspect(uintptr_t hwnd) const;
  GameStreamWindowInfo InspectBound() const;

  static int NormalizedCoordinate(double value, int extent);
  static UINT ResolveVirtualKey(const std::string& key);
  static LPARAM PointerLParam(double x, double y, int width, int height);

 private:
  bool ValidateTarget(bool require_foreground, std::string* reason);
  bool CaptureProcessIdentity(DWORD pid);
  bool ProcessIdentityStillValid() const;
  void SetReason(std::string* reason, const char* value) const;
  bool PostKey(UINT vk, bool down);

  HWND hwnd_ = nullptr;
  HANDLE process_ = nullptr;
  FILETIME process_creation_time_{};
  uint32_t pid_ = 0;
  std::set<UINT> pressed_keys_;
  bool pointer_down_ = false;
  std::string last_reason_;
};

}  // namespace fushi

#endif  // RUNNER_GAME_STREAM_INPUT_H_
