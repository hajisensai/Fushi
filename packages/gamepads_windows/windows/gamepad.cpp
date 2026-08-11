#include <algorithm>
#include <ppl.h>
#include <vector>
#include <concrt.h>
#include <winerror.h>

#include "gamepad.h"
#include "utils.h"
#include <GameInput.h>
#include <iomanip>
#include <sstream>
#pragma comment(lib, "GameInput.lib")

Gamepads gamepads;

static IGameInput* g_gameInput = nullptr;
static IGameInputDevice* g_gamepad = nullptr;

std::string get_button_name(uint32_t button) {
  switch (button) {
    case GameInputGamepadMenu:
      return "menu";
    case GameInputGamepadView:
      return "view";
    case GameInputGamepadA:
      return "a";
    case GameInputGamepadB:
      return "b";
    case GameInputGamepadX:
      return "x";
    case GameInputGamepadY:
      return "y";
    case GameInputGamepadDPadUp:
      return "dpadUp";
    case GameInputGamepadDPadDown:
      return "dpadDown";
    case GameInputGamepadDPadLeft:
      return "dpadLeft";
    case GameInputGamepadDPadRight:
      return "dpadRight";
    case GameInputGamepadLeftShoulder:
      return "leftShoulder";
    case GameInputGamepadRightShoulder:
      return "rightShoulder";
    case GameInputGamepadLeftThumbstick:
      return "leftThumbstick";
    case GameInputGamepadRightThumbstick:
      return "rightThumbstick";
  }
  return "button-" + std::to_string(button);
}

std::string AppLocalDeviceIdToString(const APP_LOCAL_DEVICE_ID& id) {
  std::ostringstream oss;
  oss << std::hex << std::setfill('0');
  for (size_t i = 0; i < APP_LOCAL_DEVICE_ID_SIZE; ++i) {
    oss << std::setw(2) << static_cast<int>(id.value[i]);
  }
  return oss.str();
}

std::list<Event> diff_states(const GameInputGamepadState& old,
                             const GameInputGamepadState& current) {
  std::time_t now = std::time(nullptr);
  int time = static_cast<int>(now);

  std::list<Event> events;
  if (old.leftThumbstickX != current.leftThumbstickX) {
    events.push_back(
        {time, "analog", "leftThumbstickX", current.leftThumbstickX});
  }
  if (old.leftThumbstickY != current.leftThumbstickY) {
    events.push_back(
        {time, "analog", "leftThumbstickY", current.leftThumbstickY});
  }
  if (old.rightThumbstickX != current.rightThumbstickX) {
    events.push_back(
        {time, "analog", "rightThumbstickX", current.rightThumbstickX});
  }
  if (old.rightThumbstickY != current.rightThumbstickY) {
    events.push_back(
        {time, "analog", "rightThumbstickY", current.rightThumbstickY});
  }
  if (old.leftTrigger != current.leftTrigger) {
    events.push_back({time, "analog", "leftTrigger", current.leftTrigger});
  }
  if (old.rightTrigger != current.rightTrigger) {
    events.push_back({time, "analog", "rightTrigger", current.rightTrigger});
  }
  if (old.buttons != current.buttons) {
    // While GameInputDeviceInfo.controllerButtonCount often gives 14,
    // if you install GameInput v3 redistributable, the reported
    // button count drops to zero. Button input is still reported.
    for (uint32_t i = 0; i < 14; ++i) {
      bool was_pressed = old.buttons & (1 << i);
      bool is_pressed = current.buttons & (1 << i);
      if (was_pressed != is_pressed) {
        double value = is_pressed ? 1.0 : 0.0;
        auto key = get_button_name(1 << i);
        events.push_back({time, "button", key, value});
      }
    }
  }
  return events;
}

bool are_states_different(const GameInputGamepadState& a,
                          const GameInputGamepadState& b) {
  return a.leftThumbstickX != b.leftThumbstickX ||
         a.leftThumbstickY != b.leftThumbstickY ||
         a.leftTrigger != b.leftTrigger ||
         a.rightThumbstickX != b.rightThumbstickX ||
         a.rightThumbstickY != b.rightThumbstickY ||
         a.rightTrigger != b.rightTrigger || a.buttons != b.buttons;
}

void Gamepads::init() {
  // GameInput.dll is delay-loaded (see CMakeLists.txt /DELAYLOAD): it is not
  // installed on every Windows machine (no Gaming Services / older Windows 10
  // without the GameInput redistributable), and a static import would kill the
  // whole process at load time before main() runs (TODO-1223). Probe for the
  // DLL before the first GameInput call - calling a delay-loaded import whose
  // DLL is missing raises an SEH exception instead of returning an error. The
  // module handle is intentionally kept for the process lifetime so the
  // delay-load helper's own LoadLibrary always succeeds after this probe.
  if (::LoadLibraryW(L"GameInput.dll") == nullptr) {
    std::cerr << "GameInput.dll not available; gamepad support disabled"
              << std::endl;
    // game_input_available stays false: the plugin reports this over the
    // gameInputAvailable channel method so Dart can hint the user (TODO-1223).
    return;
  }
  // The DLL is present: mark the backend available so a gamepad-related surface
  // (shortcut settings) does NOT nag the user with the "install Gaming
  // Services" hint (TODO-1223).
  game_input_available = true;

  GameInputCreate(&g_gameInput);

  if (g_gameInput != nullptr) {
    // BUG-1541: the reaper must be running BEFORE the device callback is
    // registered - from that moment on, on_gamepad_disconnected can only hand
    // entries over to it (it must never join on GameInput's callback thread).
    {
      std::lock_guard<std::mutex> lock(reaper_mutex);
      reaper_stop = false;
    }
    if (!reaper_thread.joinable()) {
      reaper_thread = std::thread([this]() { reap_loop(); });
    }
    // Register listener for gamepad events. Pass &deviceCallbackToken (a value
    // member) as the out-token — the upstream code passed an uninitialized raw
    // pointer here, so GameInput wrote the token to a wild address (BUG-116).
    g_gameInput->RegisterDeviceCallback(
        nullptr,  // All devices
        GameInputKindGamepad, GameInputDeviceConnected,
        GameInputAsyncEnumeration, static_cast<void*>(this),
        [](_In_ GameInputCallbackToken callbackToken, _In_ void* context,
           _In_ IGameInputDevice* device, _In_ uint64_t timestamp,
           _In_ GameInputDeviceStatus currentStatus,
           _In_ GameInputDeviceStatus previousStatus) {
          auto* self = static_cast<Gamepads*>(context);
          if (currentStatus & GameInputDeviceConnected) {
            self->on_gamepad_connected(device);
          } else {
            self->on_gamepad_disconnected(device);
          }
        },
        &this->deviceCallbackToken);
  }
}

void Gamepads::join_and_destroy(GamepadData* gamepad) {
  // The polling thread observes stop_thread and returns; join it so we never
  // tear down (or free) while it is still inside GetCurrentReading. This is the
  // teardown use-after-free fix (BUG-116): the thread is owned + joined here,
  // never detached + self-deleted.
  gamepad->stop_thread.store(true);
  if (gamepad->thread.joinable()) {
    gamepad->thread.join();
  }
  if (gamepad->device != nullptr) {
    gamepad->device->Release();
    gamepad->device = nullptr;
  }
  delete gamepad;
}

void Gamepads::retire(GamepadData* gamepad) {
  // Runs on the GameInput device-callback thread (disconnect / stale replace)
  // and on the platform thread (stop). Must not block: see the reaper comment
  // in gamepad.h (BUG-1541).
  gamepad->stop_thread.store(true);
  {
    std::lock_guard<std::mutex> lock(reaper_mutex);
    retired.push_back(gamepad);
  }
  reaper_cv.notify_one();
}

void Gamepads::reap_loop() {
  for (;;) {
    std::list<GamepadData*> batch;
    {
      std::unique_lock<std::mutex> lock(reaper_mutex);
      reaper_cv.wait(lock,
                     [this]() { return !retired.empty() || reaper_stop; });
      batch.swap(retired);
    }
    // Woken with nothing left to reap: stop() is asking us to finish. Anything
    // queued before that flag was set has already been drained by an earlier
    // iteration, so exiting here cannot leak a thread.
    if (batch.empty()) {
      return;
    }
    for (auto gp : batch) {
      join_and_destroy(gp);
    }
  }
}

void Gamepads::drain_retired() {
  std::list<GamepadData*> batch;
  {
    std::lock_guard<std::mutex> lock(reaper_mutex);
    batch.swap(retired);
  }
  for (auto gp : batch) {
    join_and_destroy(gp);
  }
}

void Gamepads::stop() {
  // Unregister FIRST so no new connect/disconnect callbacks (and thus no new
  // polling threads) can race with teardown. UnregisterCallback waits for any
  // in-flight callback to finish (5s timeout).
  if (g_gameInput != nullptr && deviceCallbackToken != 0) {
    g_gameInput->UnregisterCallback(deviceCallbackToken, 5000);
    deviceCallbackToken = 0;
  }

  // Drain the registry under the lock, then stop/join the threads outside it
  // (a thread must not be waited on while holding a lock it might need).
  std::list<GamepadData*> pending;
  {
    std::lock_guard<std::mutex> lock(gamepads_mutex);
    pending.swap(this->gamepads);
  }
  for (auto gp : pending) {
    retire(gp);
  }

  // Let the reaper finish the queue it already owns, then wind it down. This
  // runs on the platform thread, so blocking here is fine (unlike the device
  // callback thread - BUG-1541).
  {
    std::lock_guard<std::mutex> lock(reaper_mutex);
    reaper_stop = true;
  }
  reaper_cv.notify_all();
  if (reaper_thread.joinable()) {
    reaper_thread.join();
  }
  // Fallback for the case where the reaper never started (init() found no
  // GameInput): nothing may outlive stop() unjoined.
  drain_retired();

  // Only now, with every polling thread joined, is it safe to release the COM
  // object — and we null it so nothing can ever touch a released pointer.
  if (g_gamepad != nullptr) {
    g_gamepad->Release();
    g_gamepad = nullptr;
  }
  if (g_gameInput != nullptr) {
    g_gameInput->Release();
    g_gameInput = nullptr;
  }
}

std::list<GamepadData*> Gamepads::get_gamepads() {
  std::lock_guard<std::mutex> lock(gamepads_mutex);
  return this->gamepads;
}

void Gamepads::on_gamepad_connected(IGameInputDevice* device) {
  auto info = device->GetDeviceInfo();
  if (info == nullptr) {
    std::cerr << "Gamepad connected but failed to read info" << std::endl;
    return;
  }
  auto gp = new GamepadData();
  gp->id = AppLocalDeviceIdToString(info->deviceId);
  gp->name = info->displayName != nullptr && info->displayName->data != nullptr
                 ? info->displayName->data
                 : "";
  gp->num_buttons = info->controllerButtonCount;
  gp->vendor_id = static_cast<int>(info->vendorId);
  gp->product_id = static_cast<int>(info->productId);
  // Keep the device alive for the polling thread's whole lifetime, so a
  // disconnect/teardown cannot release it while GetCurrentReading runs.
  device->AddRef();
  gp->device = device;

  std::cout << "Gamepad connected: " << gp->id << " : " << gp->name
            << std::endl;

  // BUG-1541: a Bluetooth pad that idles out and wakes up can hand us a
  // "connected" callback without a matching "disconnected" one (dropped, or
  // bailed out because GetDeviceInfo returned null). Without this sweep the old
  // entry - and its thread, still polling a device object the system already
  // tore down - would linger forever next to the new one. Same deviceId or same
  // device object means the same physical controller: retire the old entry.
  std::list<GamepadData*> stale;
  {
    std::lock_guard<std::mutex> lock(gamepads_mutex);
    for (auto it = this->gamepads.begin(); it != this->gamepads.end();) {
      if ((*it)->id == gp->id || (*it)->device == device) {
        stale.push_back(*it);
        it = this->gamepads.erase(it);
      } else {
        ++it;
      }
    }
    // Own the thread handle (no detach) so it can be joined on disconnect/stop.
    // Started under the lock so a disconnect callback can never observe (and
    // free) this entry before its thread handle exists.
    gp->thread = std::thread([this, gp, device]() { read_gamepad(gp, device); });
    this->gamepads.push_back(gp);
  }
  for (auto stale_gp : stale) {
    retire(stale_gp);
  }
}

void Gamepads::on_gamepad_disconnected(IGameInputDevice* device) {
  auto info = device->GetDeviceInfo();
  // BUG-1541: GetDeviceInfo can fail once the system has torn the device down,
  // which is precisely the Bluetooth-idle case. Bailing out here (the old
  // behaviour) left the entry and its polling thread in the registry forever,
  // spinning on a dead device object. Fall back to matching the device pointer
  // we AddRef'd at connect time so a removal can never be dropped.
  std::string removeId;
  if (info != nullptr) {
    removeId = AppLocalDeviceIdToString(info->deviceId);
    std::cout << "Gamepad disconnected: " << removeId << std::endl;
  } else {
    std::cerr << "Gamepad disconnected but failed to read info; matching by "
                 "device pointer"
              << std::endl;
  }

  std::list<GamepadData*> removed;
  {
    std::lock_guard<std::mutex> lock(gamepads_mutex);
    for (auto it = this->gamepads.begin(); it != this->gamepads.end();) {
      const bool matches = (*it)->device == device ||
                           (!removeId.empty() && (*it)->id == removeId);
      if (matches) {
        removed.push_back(*it);
        it = this->gamepads.erase(it);
      } else {
        ++it;
      }
    }
  }
  // We are on GameInput's device-callback thread. Hand the join off to the
  // reaper - joining here parks this thread on a polling thread that is itself
  // inside g_gameInput->GetCurrentReading(), which stalls GameInput's callback
  // dispatch and swallows the "connected" callback the pad fires when it wakes
  // back up (BUG-1541: pad dead until the app restarts).
  for (auto gp : removed) {
    retire(gp);
  }
}

void Gamepads::neutralize_inputs(GamepadData* gamepad,
                                 GameInputGamepadState& state) {
  const GameInputGamepadState neutral = {
      GameInputGamepadNone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
  if (!are_states_different(state, neutral)) {
    return;
  }
  // BUG-1541: a controller that vanishes mid-press never delivers the release
  // frame, so the Dart-side GamepadFrameState would keep the button latched
  // (endless auto-repeat / stick pinned to an edge) even after a clean
  // reconnect. Synthesize the missing releases so every press still has one.
  for (const auto& event : diff_states(state, neutral)) {
    if (event_emitter.has_value()) {
      (*event_emitter)(gamepad, event);
    }
  }
  state = neutral;
}

void Gamepads::read_gamepad(GamepadData* gamepad, IGameInputDevice* device) {
  GameInputGamepadState previous_state = {
      GameInputGamepadNone, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0};
  // g_gameInput stays valid for this thread's whole life: stop()/disconnect set
  // stop_thread then join() before releasing it, so we never poll a released
  // object. The device is AddRef'd by the owner for the same reason.
  while (!gamepad->stop_thread.load()) {
    // BUG-1541: a Bluetooth pad going idle drops the device out of the
    // Connected state. Keeping GetCurrentReading pointed at a device the system
    // is tearing down burns a core for nothing and is the one call that can
    // park this thread inside GameInput's own locks - which used to wedge the
    // callback thread that was joining us. Release whatever was held and idle
    // down instead; if the same device object comes back, polling resumes with
    // no bookkeeping at all.
    if ((device->GetDeviceStatus() & GameInputDeviceConnected) ==
        GameInputDeviceNoStatus) {
      neutralize_inputs(gamepad, previous_state);
      Sleep(64);
      continue;
    }

    IGameInputReading* reading = nullptr;
    GameInputGamepadState state;
    g_gameInput->GetCurrentReading(GameInputKindGamepad, device, &reading);
    if (reading != nullptr) {
      if (reading->GetGamepadState(&state)) {
        if (are_states_different(previous_state, state)) {
          auto events = diff_states(previous_state, state);
          for (auto event : events) {
            if (event_emitter.has_value()) {
              (*event_emitter)(gamepad, event);
            }
          }
        }
        previous_state = state;
      }
      reading->Release();
    }

    Sleep(8);
  }

  // Teardown/disconnect: same missing-release problem as the idle branch above.
  neutralize_inputs(gamepad, previous_state);

  std::cout << "Gamepad thread exit " << gamepad->id << std::endl;
  // NOTE: the thread no longer frees `gamepad` — the owner joins this thread
  // and frees it in join_and_destroy(), so there is exactly one owner.
}
