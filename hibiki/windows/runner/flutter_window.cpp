#include "flutter_window.h"

#include <dwmapi.h>
#include <wincodec.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <functional>
#include <limits>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include <flutter/method_result_functions.h>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "windowscodecs.lib")

namespace {

std::wstring Utf8ToWideString(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                 static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::string HResultMessage(HRESULT hr) {
  char buffer[128];
  snprintf(buffer, sizeof(buffer), "HRESULT 0x%08X", static_cast<unsigned>(hr));
  return std::string(buffer);
}

std::optional<std::string> CopyImageFileToClipboard(HWND hwnd,
                                                    const std::wstring& path) {
  if (hwnd == nullptr) {
    return std::string("Window handle is unavailable");
  }
  if (path.empty()) {
    return std::string("Image path is empty");
  }

  using Microsoft::WRL::ComPtr;
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    return std::string("WIC factory creation failed: ") + HResultMessage(hr);
  }

  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromFilename(
      path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
      &decoder);
  if (FAILED(hr)) {
    return std::string("Image decode failed: ") + HResultMessage(hr);
  }

  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) {
    return std::string("Image frame read failed: ") + HResultMessage(hr);
  }

  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) {
    return std::string("Image converter creation failed: ") +
           HResultMessage(hr);
  }
  hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return std::string("Image conversion failed: ") + HResultMessage(hr);
  }

  UINT width = 0;
  UINT height = 0;
  hr = converter->GetSize(&width, &height);
  if (FAILED(hr) || width == 0 || height == 0) {
    return std::string("Image size is invalid");
  }

  const size_t stride = static_cast<size_t>(width) * 4;
  const size_t pixel_bytes = stride * static_cast<size_t>(height);
  if (pixel_bytes == 0 ||
      pixel_bytes > static_cast<size_t>(std::numeric_limits<DWORD>::max())) {
    return std::string("Image is too large for the clipboard");
  }

  std::vector<BYTE> pixels(pixel_bytes);
  hr = converter->CopyPixels(nullptr, static_cast<UINT>(stride),
                             static_cast<UINT>(pixel_bytes), pixels.data());
  if (FAILED(hr)) {
    return std::string("Image pixel copy failed: ") + HResultMessage(hr);
  }

  const size_t dib_bytes = sizeof(BITMAPINFOHEADER) + pixel_bytes;
  HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE, dib_bytes);
  if (dib == nullptr) {
    return std::string("Clipboard memory allocation failed");
  }

  void* locked = GlobalLock(dib);
  if (locked == nullptr) {
    GlobalFree(dib);
    return std::string("Clipboard memory lock failed");
  }

  auto* header = static_cast<BITMAPINFOHEADER*>(locked);
  ZeroMemory(header, sizeof(BITMAPINFOHEADER));
  header->biSize = sizeof(BITMAPINFOHEADER);
  header->biWidth = static_cast<LONG>(width);
  header->biHeight = static_cast<LONG>(height);
  header->biPlanes = 1;
  header->biBitCount = 32;
  header->biCompression = BI_RGB;
  header->biSizeImage = static_cast<DWORD>(pixel_bytes);

  BYTE* dest = static_cast<BYTE*>(locked) + sizeof(BITMAPINFOHEADER);
  for (UINT row = 0; row < height; ++row) {
    const BYTE* source_row =
        pixels.data() + (static_cast<size_t>(height - 1 - row) * stride);
    memcpy(dest + (static_cast<size_t>(row) * stride), source_row, stride);
  }
  GlobalUnlock(dib);

  if (!OpenClipboard(hwnd)) {
    GlobalFree(dib);
    return std::string("OpenClipboard failed");
  }
  if (!EmptyClipboard()) {
    CloseClipboard();
    GlobalFree(dib);
    return std::string("EmptyClipboard failed");
  }
  if (SetClipboardData(CF_DIB, dib) == nullptr) {
    CloseClipboard();
    GlobalFree(dib);
    return std::string("SetClipboardData(CF_DIB) failed");
  }
  CloseClipboard();
  return std::nullopt;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Title-bar theming channel: Dart pushes surface/onSurface colors so the
  // native caption follows the in-app theme (see window_caption_channel.dart).
  caption_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.hibiki/window",
          &flutter::StandardMethodCodec::GetInstance());
  caption_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setCaptionColors") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            const auto caption_it =
                args->find(flutter::EncodableValue("caption"));
            const auto text_it = args->find(flutter::EncodableValue("text"));
            // Dart sends ARGB ints; opaque colors (alpha 0xFF) exceed int32
            // range and arrive as int64. TryGetLongValue() accepts either
            // int32 or int64 without throwing (unlike std::get<int>).
            const int64_t caption_argb =
                caption_it != args->end()
                    ? caption_it->second.TryGetLongValue().value_or(0)
                    : 0;
            const int64_t text_argb =
                text_it != args->end()
                    ? text_it->second.TryGetLongValue().value_or(0)
                    : 0;
            ApplyCaptionColors(static_cast<uint32_t>(caption_argb),
                               static_cast<uint32_t>(text_argb));
          }
          result->Success();
        } else if (call.method_name() == "clearTaskbarFlash") {
          // TODO-615: actively stop any taskbar "flash / request attention"
          // state on the main window. SetForegroundWindow (window_manager's
          // show()/focus()/setAlwaysOnTop() degrade into it under the foreground
          // lock) flashes our taskbar button until the user clicks it. Dart's
          // foreground guard can still miss-judge during focus jitter, so the
          // foreground path asks us to clear unconditionally. FLASHW_STOP on a
          // window that is not flashing is a no-op, so this is idempotent.
          HWND hwnd = GetHandle();
          if (hwnd != nullptr) {
            FLASHWINFO flash_info;
            flash_info.cbSize = sizeof(FLASHWINFO);
            flash_info.hwnd = hwnd;
            flash_info.dwFlags = FLASHW_STOP;
            flash_info.uCount = 0;
            flash_info.dwTimeout = 0;
            FlashWindowEx(&flash_info);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  clipboard_image_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/clipboard_image",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_image_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "copyImageFile") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("bad_args", "Expected a map with an image path");
          return;
        }
        const auto path_it = args->find(flutter::EncodableValue("path"));
        if (path_it == args->end()) {
          result->Error("bad_args", "Missing image path");
          return;
        }
        const auto* path = std::get_if<std::string>(&path_it->second);
        if (path == nullptr) {
          result->Error("bad_args", "Image path must be a string");
          return;
        }
        const std::wstring wide_path = Utf8ToWideString(*path);
        const std::optional<std::string> error =
            CopyImageFileToClipboard(GetHandle(), wide_path);
        if (error.has_value()) {
          result->Error("copy_failed", error.value());
          return;
        }
        result->Success();
      });

  RegisterFloatingLyricChannel();
  RegisterGlobalLookupChannel();

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

namespace {

// ARGB int arriving from Dart may exceed int32 (opaque colors); accept either.
uint32_t ArgbFromValue(const flutter::EncodableMap* args, const char* key,
                        uint32_t fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  return static_cast<uint32_t>(it->second.TryGetLongValue().value_or(fallback));
}

double DoubleFromValue(const flutter::EncodableMap* args, const char* key,
                       double fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  if (const auto* d = std::get_if<double>(&it->second)) {
    return *d;
  }
  if (const auto* i = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*i);
  }
  if (const auto* l = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*l);
  }
  return fallback;
}

int IntFromValue(const flutter::EncodableMap* args, const char* key,
                 int fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  return static_cast<int>(it->second.TryGetLongValue().value_or(fallback));
}

bool BoolFromValue(const flutter::EncodableMap* args, const char* key,
                   bool fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  if (const auto* b = std::get_if<bool>(&it->second)) {
    return *b;
  }
  return fallback;
}

std::wstring WideFromValue(const flutter::EncodableMap* args, const char* key,
                           const std::wstring& fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  const auto* s = std::get_if<std::string>(&it->second);
  if (s == nullptr) {
    return fallback;
  }
  if (s->empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, s->data(),
                                 static_cast<int>(s->size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s->data(), static_cast<int>(s->size()),
                      result.data(), size);
  return result;
}

std::string StringFromValue(const flutter::EncodableMap* args, const char* key,
                            const std::string& fallback) {
  if (args == nullptr) {
    return fallback;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return fallback;
  }
  const auto* s = std::get_if<std::string>(&it->second);
  return s != nullptr ? *s : fallback;
}

FloatingLyricWindow::Style StyleFromArgs(const flutter::EncodableMap* args) {
  FloatingLyricWindow::Style style;
  style.font_size = DoubleFromValue(args, "fontSize", style.font_size);
  style.text_color = ArgbFromValue(args, "textColor", style.text_color);
  style.bg_color = ArgbFromValue(args, "bgColor", style.bg_color);
  style.button_text_color =
      ArgbFromValue(args, "buttonTextColor", style.button_text_color);
  style.button_bg_color =
      ArgbFromValue(args, "buttonBgColor", style.button_bg_color);
  style.highlight_color =
      ArgbFromValue(args, "highlightColor", style.highlight_color);
  style.active_color = ArgbFromValue(args, "activeColor", style.active_color);
  return style;
}

}  // namespace

void FlutterWindow::RegisterFloatingLyricChannel() {
  floating_lyric_window_ = std::make_unique<FloatingLyricWindow>();

  floating_lyric_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/floating_lyric",
          &flutter::StandardMethodCodec::GetInstance());

  // Native taps -> Dart events (handled by FloatingLyricChannel.setEventHandlers
  // in the reader page). The window's WndProc runs on this (platform) thread, so
  // InvokeMethod is safe to call directly from the callbacks.
  floating_lyric_window_->SetControlCallback(
      [this](const std::string& action) {
        floating_lyric_channel_->InvokeMethod(
            action, std::make_unique<flutter::EncodableValue>());
      });
  floating_lyric_window_->SetLookupCallback(
      [this](const std::string& text, int char_index) {
        flutter::EncodableMap map{
            {flutter::EncodableValue("text"), flutter::EncodableValue(text)},
            {flutter::EncodableValue("index"),
             flutter::EncodableValue(char_index)},
        };
        floating_lyric_channel_->InvokeMethod(
            "lookupText",
            std::make_unique<flutter::EncodableValue>(std::move(map)));
      });
  // The user toggling the lock button on the strip reports the new state back
  // so the Dart side can persist it / refresh any in-app mirror.
  floating_lyric_window_->SetLockCallback([this](bool locked) {
    flutter::EncodableMap map{
        {flutter::EncodableValue("locked"), flutter::EncodableValue(locked)},
    };
    floating_lyric_channel_->InvokeMethod(
        "lockChanged", std::make_unique<flutter::EncodableValue>(std::move(map)));
  });

  floating_lyric_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string& method = call.method_name();

        if (method == "canDrawOverlays") {
          // The desktop strip is a runner-owned window — no OS overlay
          // permission exists, so it is always permitted.
          result->Success(flutter::EncodableValue(true));
        } else if (method == "show") {
          floating_lyric_window_->UpdateStyle(StyleFromArgs(args));
          floating_lyric_window_->SetClickLookupEnabled(
              BoolFromValue(args, "clickLookupEnabled", true));
          if (args != nullptr &&
              args->find(flutter::EncodableValue("locked")) != args->end()) {
            floating_lyric_window_->SetLocked(
                BoolFromValue(args, "locked", false));
          }
          const bool shown = floating_lyric_window_->Show(GetHandle());
          result->Success(flutter::EncodableValue(shown));
        } else if (method == "hide") {
          floating_lyric_window_->Hide();
          result->Success();
        } else if (method == "isShowing") {
          result->Success(
              flutter::EncodableValue(floating_lyric_window_->IsShowing()));
        } else if (method == "updateText") {
          floating_lyric_window_->UpdateText(WideFromValue(args, "text", L""));
          result->Success();
        } else if (method == "highlight") {
          floating_lyric_window_->Highlight(IntFromValue(args, "start", -1),
                                            IntFromValue(args, "length", 0));
          result->Success();
        } else if (method == "updateStyle") {
          floating_lyric_window_->UpdateStyle(StyleFromArgs(args));
          result->Success();
        } else if (method == "updateLabels") {
          FloatingLyricWindow::Labels labels;
          labels.previous = WideFromValue(args, "previous", labels.previous);
          labels.play_pause =
              WideFromValue(args, "playPause", labels.play_pause);
          labels.next = WideFromValue(args, "next", labels.next);
          labels.lock = WideFromValue(args, "lock", labels.lock);
          labels.unlock = WideFromValue(args, "unlock", labels.unlock);
          labels.close = WideFromValue(args, "close", labels.close);
          floating_lyric_window_->UpdateLabels(labels);
          result->Success();
        } else if (method == "setPlaybackState") {
          floating_lyric_window_->SetPlaybackState(
              BoolFromValue(args, "playing", false));
          result->Success();
        } else if (method == "setClickLookupEnabled") {
          floating_lyric_window_->SetClickLookupEnabled(
              BoolFromValue(args, "enabled", true));
          result->Success();
        } else if (method == "setLocked") {
          // Position lock: drag disabled, lookup + playback controls still work
          // (mirrors the Android FloatingLyricService lock). The strip reports
          // any user-driven toggle back over "lockChanged".
          floating_lyric_window_->SetLocked(
              BoolFromValue(args, "locked", false));
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::RegisterGlobalLookupChannel() {
  global_lookup_window_ = std::make_unique<GlobalLookupWindow>();

  global_lookup_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/global_lookup",
          &flutter::StandardMethodCodec::GetInstance());

  // image:// -> ask the main Dart engine for the bytes. Asynchronous: the reply
  // is delivered on this (platform) thread, so the WebView2 deferral is
  // completed inside the InvokeMethod result without blocking the message loop.
  global_lookup_window_->SetMediaResolver(
      [this](const std::string& url,
             std::function<void(std::vector<uint8_t>)> respond) {
        auto args = std::make_unique<flutter::EncodableValue>(
            flutter::EncodableMap{{flutter::EncodableValue("url"),
                                   flutter::EncodableValue(url)}});
        auto result = std::make_unique<
            flutter::MethodResultFunctions<flutter::EncodableValue>>(
            [respond](const flutter::EncodableValue* ok) {
              std::vector<uint8_t> bytes;
              if (ok != nullptr) {
                if (const auto* b =
                        std::get_if<std::vector<uint8_t>>(ok)) {
                  bytes = *b;
                }
              }
              respond(std::move(bytes));
            },
            [respond](const std::string&, const std::string&,
                      const flutter::EncodableValue*) { respond({}); },
            [respond]() { respond({}); });
        global_lookup_channel_->InvokeMethod("getMedia", std::move(args),
                                             std::move(result));
      });

  // JS postMessage (dismiss / audio handlers) -> Dart.
  global_lookup_window_->SetMessageCallback([this](const std::string& json) {
    global_lookup_channel_->InvokeMethod(
        "jsMessage", std::make_unique<flutter::EncodableValue>(json));
  });

  global_lookup_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string& method = call.method_name();

        if (method == "prepare") {
          global_lookup_window_->SetPopupAssetsDir(
              WideFromValue(args, "assetsDir", L""));
          result->Success();
        } else if (method == "showAt") {
          int x = IntFromValue(args, "x", 0);
          int y = IntFromValue(args, "y", 0);
          if (BoolFromValue(args, "atCursor", false)) {
            // GetCursorPos returns physical screen pixels, matching
            // CreateWindowEx — no logical/physical DPI mismatch.
            POINT pt;
            if (GetCursorPos(&pt)) {
              x = pt.x + 8;
              y = pt.y + 8;
            }
          }
          const bool ok = global_lookup_window_->ShowAt(
              x, y, IntFromValue(args, "width", 420),
              IntFromValue(args, "height", 600), GetHandle());
          result->Success(flutter::EncodableValue(ok));
        } else if (method == "render") {
          global_lookup_window_->RenderJson(StringFromValue(args, "json", ""));
          result->Success();
        } else if (method == "resize") {
          global_lookup_window_->ResizeTo(IntFromValue(args, "width", 0),
                                          IntFromValue(args, "height", 0));
          result->Success();
        } else if (method == "reveal") {
          global_lookup_window_->Reveal(IntFromValue(args, "width", 0),
                                        IntFromValue(args, "height", 0));
          result->Success();
        } else if (method == "resolveBridge") {
          // Dart's real reply for a deferred audio handler. "value" is a JSON
          // literal string (jsonEncode'd in Dart): pass it straight through.
          global_lookup_window_->ResolveBridge(
              IntFromValue(args, "id", 0),
              StringFromValue(args, "value", "null"));
          result->Success();
        } else if (method == "hide") {
          global_lookup_window_->Hide();
          result->Success();
        } else if (method == "isShowing") {
          result->Success(
              flutter::EncodableValue(global_lookup_window_->IsShowing()));
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::ApplyCaptionColors(uint32_t caption_argb,
                                       uint32_t text_argb) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  // ARGB (0xAARRGGBB) -> Win32 COLORREF (0x00BBGGRR). Alpha is dropped;
  // DWM caption colors are opaque.
  auto to_colorref = [](uint32_t argb) -> COLORREF {
    return RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  };
  COLORREF caption = to_colorref(caption_argb);
  COLORREF text = to_colorref(text_argb);
  // DWMWA_CAPTION_COLOR (35) / DWMWA_TEXT_COLOR (36): Windows 11 build 22000+.
  // On older Windows these return a failure HRESULT that we intentionally
  // ignore, leaving the system-drawn title bar untouched.
  DwmSetWindowAttribute(hwnd, 35, &caption, sizeof(caption));
  DwmSetWindowAttribute(hwnd, 36, &text, sizeof(text));
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnDisplayRecovered() {
  // The display came back (monitor power-on / WM_DISPLAYCHANGE). The engine does
  // not produce a new frame on its own, so the window can stay blank until some
  // other event wakes it. Force one fresh frame (TODO-689). Only the first-tier
  // ForceRedraw is done here; the second-tier resize jiggle is intentionally
  // omitted because it can flicker — add it only if a real device still shows a
  // black screen after this.
  if (!flutter_controller_) {
    return;
  }
  flutter_controller_->ForceRedraw();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
