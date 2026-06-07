#ifndef FLUTTER_PLUGIN_GAMEPADS_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_GAMEPADS_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <windows.h>
#include <deque>
#include <memory>
#include <mutex>

#include "gamepad.h"

namespace gamepads_windows {

class GamepadsWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  GamepadsWindowsPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~GamepadsWindowsPlugin();

  // Disallow copy and assign.
  GamepadsWindowsPlugin(const GamepadsWindowsPlugin&) = delete;
  GamepadsWindowsPlugin& operator=(const GamepadsWindowsPlugin&) = delete;

 private:
  flutter::PluginRegistrarWindows* registrar;
  static inline std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel{};

  // A controller event copied off the polling thread, ready to ship to Dart on
  // the platform thread. BUG-116: the platform method channel must only be
  // invoked from the platform thread, and the source GamepadData may be freed
  // before the platform thread drains, so we copy the values (never the
  // pointer) here.
  struct PendingEvent {
    std::string gamepad_id;
    int vendor_id;
    int product_id;
    int time;
    std::string type;
    std::string key;
    double value;
  };

  // Message-only window owned on the platform thread; the polling thread posts
  // to it so the queue is drained (and the channel invoked) on the platform
  // thread.
  HWND message_window_ = nullptr;
  std::mutex queue_mutex_;
  std::deque<PendingEvent> event_queue_;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Called on the POLLING thread: enqueues a copy and posts to the window.
  void emit_gamepad_event(GamepadData* gamepad, const Event& event);
  // Called on the PLATFORM thread (from the window proc): ships queued events.
  void drain_event_queue();

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);
};

}  // namespace gamepads_windows

#endif  // FLUTTER_PLUGIN_GAMEPADS_WINDOWS_PLUGIN_H_
