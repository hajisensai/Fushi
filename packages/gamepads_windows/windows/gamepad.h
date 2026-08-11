
#include <wtypes.h>

#include <windows.h>
#include <atomic>
#include <condition_variable>
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

  // BUG-1541: retirement queue drained by a dedicated reaper thread.
  //
  // A polling thread must be JOINED before its GamepadData is freed (BUG-116),
  // but the join must NEVER happen on GameInput's device-callback thread: the
  // thread being joined is normally parked inside
  // `g_gameInput->GetCurrentReading()`, so joining from the callback holds
  // GameInput's own dispatch hostage. That is exactly what killed a Bluetooth
  // controller after it idled out — the "disconnected" callback blocked, so the
  // "connected" callback that follows when the pad wakes up was never
  // delivered, no new polling thread was ever created, and the pad stayed dead
  // until the app restarted. Disconnect/replace now only hands the entry over
  // here; `reap_loop` does the blocking work on our own thread.
  std::mutex reaper_mutex;
  std::condition_variable reaper_cv;
  std::list<GamepadData*> retired;
  bool reaper_stop = false;
  std::thread reaper_thread;

  void read_gamepad(GamepadData* gamepad, IGameInputDevice* device);

  void on_gamepad_connected(IGameInputDevice* device);
  void on_gamepad_disconnected(IGameInputDevice* device);

  // Joins the polling thread (if any), releases the held device, and frees the
  // struct. The caller must have already removed it from `gamepads`.
  void join_and_destroy(GamepadData* gamepad);

  // Non-blocking hand-off: flags the polling thread to stop and queues the
  // entry for the reaper. Safe to call from the GameInput callback thread.
  void retire(GamepadData* gamepad);
  // Reaper thread body: joins + frees whatever `retire` queues.
  void reap_loop();
  // Joins + frees the queue on the CALLING thread. Only for teardown, after the
  // reaper has exited (or if it never started).
  void drain_retired();
  // Emits synthetic release/centre events for anything still held in [state],
  // then resets [state] to neutral. A disconnect never delivers the real
  // release frame, so without this the Dart-side frame state latches the button
  // forever (stuck auto-repeat / stuck stick) even after a clean reconnect.
  void neutralize_inputs(GamepadData* gamepad, GameInputGamepadState& state);

 public:
  std::optional<std::function<void(GamepadData* gamepad, const Event& event)>>
      event_emitter;
  // TODO-1223: whether init()'s delay-load probe found GameInput.dll. Set once
  // in init() and read back over the plugin's `gameInputAvailable` channel
  // method so Dart can surface an in-app hint when the controller backend is
  // unavailable (missing DLL -> silent degrade to no gamepad support, +488)
  // instead of leaving the user to wonder why the controller is dead. Written
  // and read only on the platform thread (init() runs in the plugin ctor;
  // HandleMethodCall runs on the same thread), so a plain bool is race-free.
  bool game_input_available = false;
  void init();
  void stop();
  std::list<GamepadData*> get_gamepads();
};

extern Gamepads gamepads;
