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

// Delivers authorised input to one foreground game HWND, with identity-checked
// cleanup also allowed in the background. Uses target-window messages or the
// SGRE process-local confirm adapter, never global SendInput.
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

 private:
  bool ValidateTarget(bool require_foreground, std::string* reason);
  bool CaptureProcessIdentity(DWORD pid);
  bool ProcessIdentityStillValid() const;
  void SetReason(std::string* reason, const char* value) const;
  bool PostKey(UINT vk, bool down);
  bool PostPointer(UINT message, WPARAM flags, double x, double y);
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
  bool pointer_down_ = false;
  bool native_left_down_ = false;
  uint64_t native_left_transaction_id_ = 0;
  uint64_t next_native_transaction_id_ = 1;
  std::string last_reason_;
};

}  // namespace fushi

#endif  // RUNNER_GAME_STREAM_INPUT_H_
