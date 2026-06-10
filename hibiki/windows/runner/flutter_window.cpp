#include "flutter_window.h"

#include <dwmapi.h>
#include <wincodec.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <variant>
#include <vector>

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

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
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
