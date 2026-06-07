#include "gamepads_windows_plugin.h"

#include <dbt.h>
#include <hidclass.h>
#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <deque>
#include <memory>
#include <sstream>

namespace gamepads_windows {

namespace {
// Window message posted by the polling thread to wake the platform thread.
constexpr UINT kGamepadEventMessage = WM_USER + 0x47;  // 'G'
constexpr wchar_t kMessageWindowClass[] = L"GamepadsWindowsMessageWindow";
}  // namespace

void GamepadsWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "xyz.luan/gamepads",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<GamepadsWindowsPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

GamepadsWindowsPlugin::GamepadsWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar(registrar) {
  // RegisterWithRegistrar (and therefore this constructor) runs on the platform
  // thread, which pumps the Win32 message loop. A message-only window created
  // here receives WndProc calls on that same thread, so draining the queue from
  // WndProc invokes the channel on the platform thread as Flutter requires.
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = GamepadsWindowsPlugin::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kMessageWindowClass;
  // Ignore "class already registered" if multiple instances are created.
  RegisterClassExW(&wc);
  message_window_ =
      CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                      nullptr, GetModuleHandle(nullptr), this);
  if (message_window_ != nullptr) {
    SetWindowLongPtr(message_window_, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(this));
  }

  gamepads.event_emitter = [this](GamepadData* gamepad, const Event& event) {
    this->emit_gamepad_event(gamepad, event);
  };
  gamepads.init();
}

GamepadsWindowsPlugin::~GamepadsWindowsPlugin() {
  // Stop + join every polling thread FIRST so nothing posts to the window after
  // it is destroyed, then clear the emitter and tear down the window.
  gamepads.stop();
  gamepads.event_emitter.reset();
  if (message_window_ != nullptr) {
    DestroyWindow(message_window_);
    message_window_ = nullptr;
  }
}

void GamepadsWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("listGamepads") == 0) {
    flutter::EncodableList list;
    for (auto gamepad : gamepads.get_gamepads()) {
      flutter::EncodableMap map;
      map[flutter::EncodableValue("id")] = flutter::EncodableValue(gamepad->id);
      map[flutter::EncodableValue("name")] =
          flutter::EncodableValue(gamepad->name);
      list.push_back(flutter::EncodableValue(map));
    }
    result->Success(flutter::EncodableValue(list));
  } else {
    result->NotImplemented();
  }
}

void GamepadsWindowsPlugin::emit_gamepad_event(GamepadData* gamepad,
                                               const Event& event) {
  // Runs on the polling thread. Copy the values (the GamepadData pointer may be
  // freed before the platform thread drains) and wake the platform thread.
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    event_queue_.push_back(PendingEvent{gamepad->id, gamepad->vendor_id,
                                        gamepad->product_id, event.time,
                                        event.type, event.key, event.value});
  }
  if (message_window_ != nullptr) {
    PostMessage(message_window_, kGamepadEventMessage, 0, 0);
  }
}

void GamepadsWindowsPlugin::drain_event_queue() {
  // Runs on the platform thread (from WndProc). Move the queue out under the
  // lock, then invoke the channel without holding it.
  std::deque<PendingEvent> events;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    events.swap(event_queue_);
  }
  auto* _channel = channel.get();
  if (_channel == nullptr) {
    return;
  }
  for (const auto& event : events) {
    flutter::EncodableMap map;
    map[flutter::EncodableValue("gamepadId")] =
        flutter::EncodableValue(event.gamepad_id);
    map[flutter::EncodableValue("time")] = flutter::EncodableValue(event.time);
    map[flutter::EncodableValue("type")] = flutter::EncodableValue(event.type);
    map[flutter::EncodableValue("key")] = flutter::EncodableValue(event.key);
    map[flutter::EncodableValue("value")] =
        flutter::EncodableValue(event.value);
    map[flutter::EncodableValue("vendorId")] =
        flutter::EncodableValue(event.vendor_id);
    map[flutter::EncodableValue("productId")] =
        flutter::EncodableValue(event.product_id);
    _channel->InvokeMethod("onGamepadEvent",
                           std::make_unique<flutter::EncodableValue>(
                               flutter::EncodableValue(map)));
  }
}

LRESULT CALLBACK GamepadsWindowsPlugin::WndProc(HWND hwnd, UINT message,
                                                WPARAM wparam, LPARAM lparam) {
  if (message == kGamepadEventMessage) {
    auto* self = reinterpret_cast<GamepadsWindowsPlugin*>(
        GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (self != nullptr) {
      self->drain_event_queue();
    }
    return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

}  // namespace gamepads_windows
