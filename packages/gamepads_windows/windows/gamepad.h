
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

  // BUG-2167: 唯一职责是「进程退出时不留下 joinable 的 std::thread」。
  //
  // 全局 `gamepads` 是静态存储期对象，进程退出时由 CRT 的 onexit 表析构。而
  // `std::thread` 的析构函数对**仍 joinable** 的线程直接 `std::terminate()` →
  // `abort()`，在 Windows 上表现为 `0xc0000409 FAST_FAIL_FATAL_APP_EXIT`。
  // 这条路径**每次退出都会走到**：Fushi 的两条退出路径（更新交接
  // `platform_updater.dart`、关窗 `desktop_lifecycle_service.dart`）最终都调
  // `exit(0)`，而 `exit(0)` **故意**跳过 Flutter 插件析构，于是
  // `~GamepadsWindowsPlugin()` 里的 `stop()` 永远不会执行，`reaper_thread`
  // 带着 joinable 状态活到 onexit 表 —— 只要机器上有 GameInput.dll（即 init()
  // 起过 reaper）就必然如此。
  //
  // 下游代价远不止一条崩溃记录：崩溃进程被 WER 冻住数分钟不死，
  // `FushiSingleInstanceMutex` 随之一直被持有，应用内更新的整条交接链
  // （launcher 等父进程退出 → 等互斥量释放 → 启动 Inno）全部超时。
  ~Gamepads();
};

extern Gamepads gamepads;
