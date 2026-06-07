
#include <wtypes.h>

#include <windows.h>
#include <atomic>
#include <functional>
#include <iostream>
#include <list>
#include <map>
#include <mutex>
#include <optional>
#include <thread>
#include <GameInput.h>

// One connected controller's bookkeeping.
//
// BUG-116: the upstream version used plain `bool` flags shared between the
// platform/callback threads and the detached polling thread (a data race) and
// let the polling thread `delete` itself, so teardown could never join it. Here
// the flags are atomic, the std::thread handle is OWNED (so the owner joins
// before freeing), and the GameInput device is AddRef'd for the polling
// thread's lifetime so it cannot be released out from under GetCurrentReading.
struct GamepadData {
  std::string id;
  std::string name;
  int num_buttons = 0;
  std::atomic<bool> stop_thread{false};
  int vendor_id = 0;
  int product_id = 0;
  // AddRef'd in on_gamepad_connected, Release'd by the owner after the thread
  // is joined. Keeps the device alive while read_gamepad polls it.
  IGameInputDevice* device = nullptr;
  // Owned polling thread; joined (never detached) before this struct is freed.
  std::thread thread;
};

struct Event {
  int time;
  std::string type;
  std::string key;
  double value;
};

class Gamepads {
 private:
  // Guards `gamepads` against concurrent access from the GameInput device
  // callback thread (connect/disconnect), the platform thread (listGamepads),
  // and teardown.
  std::mutex gamepads_mutex;
  std::list<GamepadData*> gamepads;

  // Value, not a wild pointer (the upstream bug): RegisterDeviceCallback writes
  // the token here and UnregisterCallback reads it back.
  GameInputCallbackToken deviceCallbackToken = 0;
  void read_gamepad(GamepadData* gamepad, IGameInputDevice* device);

  void on_gamepad_connected(IGameInputDevice* device);
  void on_gamepad_disconnected(IGameInputDevice* device);

  // Joins the polling thread (if any), releases the held device, and frees the
  // struct. The caller must have already removed it from `gamepads`.
  void join_and_destroy(GamepadData* gamepad);

 public:
  std::optional<std::function<void(GamepadData* gamepad, const Event& event)>>
      event_emitter;
  void init();
  void stop();
  std::list<GamepadData*> get_gamepads();
};

extern Gamepads gamepads;
