#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <variant>
#include <vector>

#include <flutter/method_result_functions.h>

#include "external_video_handoff.h"
#include "flutter/generated_plugin_registrant.h"
#include "audio_loopback_capture.h"
#include "voice_hook_reader.h"
#include "foreground_selection.h"
#include "window_capture.h"

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

// Decodes |path| via WIC, scales to |size|x|size| 32bpp BGRA, and builds a
// color+mask HICON. Returns nullptr on any failure. Caller owns the result and
// must DestroyIcon it. Mirrors the WIC pipeline used by CopyImageFileToClipboard.
HICON CreateIconFromImageFile(const std::wstring& path, int size) {
  if (path.empty() || size <= 0) {
    return nullptr;
  }
  using Microsoft::WRL::ComPtr;
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
                                          WICDecodeMetadataCacheOnLoad, &decoder);
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICBitmapScaler> scaler;
  hr = factory->CreateBitmapScaler(&scaler);
  if (FAILED(hr)) {
    return nullptr;
  }
  hr = scaler->Initialize(frame.Get(), size, size,
                          WICBitmapInterpolationModeFant);
  if (FAILED(hr)) {
    return nullptr;
  }
  ComPtr<IWICFormatConverter> converter;
  hr = factory->CreateFormatConverter(&converter);
  if (FAILED(hr)) {
    return nullptr;
  }
  hr = converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppBGRA,
                             WICBitmapDitherTypeNone, nullptr, 0.0,
                             WICBitmapPaletteTypeCustom);
  if (FAILED(hr)) {
    return nullptr;
  }
  const UINT stride = static_cast<UINT>(size) * 4;
  std::vector<BYTE> pixels(static_cast<size_t>(stride) * size);
  hr = converter->CopyPixels(nullptr, stride,
                             static_cast<UINT>(pixels.size()), pixels.data());
  if (FAILED(hr)) {
    return nullptr;
  }
  BITMAPINFO bmi;
  ZeroMemory(&bmi, sizeof(bmi));
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = size;
  bmi.bmiHeader.biHeight = -size;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* dib_pixels = nullptr;
  HBITMAP color = CreateDIBSection(nullptr, &bmi, DIB_RGB_COLORS, &dib_pixels,
                                   nullptr, 0);
  if (color == nullptr || dib_pixels == nullptr) {
    if (color != nullptr) {
      DeleteObject(color);
    }
    return nullptr;
  }
  memcpy(dib_pixels, pixels.data(), pixels.size());
  // 32bpp BGRA color bitmap 带 alpha 通道时，CreateIconIndirect 直接用 color 的
  // alpha 做混合、忽略 AND mask 的内容，故 mask 仅需存在（1bpp 占位）即可，内容
  // 无关。若日后把 color 改回 24bpp，必须改用真正的 AND mask，否则透明区域花屏。
  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  if (mask == nullptr) {
    DeleteObject(color);
    return nullptr;
  }
  ICONINFO icon_info;
  ZeroMemory(&icon_info, sizeof(icon_info));
  icon_info.fIcon = TRUE;
  icon_info.hbmColor = color;
  icon_info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&icon_info);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

// Rewrites the IconLocation of a single existing .lnk to |icon_path| (index 0),
// preserving its target/args/workdir, then notifies the shell to re-read it.
// Returns true on success. A missing .lnk (user deleted it, or a portable
// unzip install with no shortcuts) is a soft no-op and returns false without
// being an error.
bool SetShortcutIconLocation(const std::wstring& lnk_path,
                             const std::wstring& icon_path) {
  if (lnk_path.empty() || icon_path.empty()) {
    return false;
  }
  if (GetFileAttributesW(lnk_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;  // No such .lnk: soft skip.
  }
  using Microsoft::WRL::ComPtr;
  ComPtr<IShellLinkW> shell_link;
  HRESULT hr =
      CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                       IID_PPV_ARGS(&shell_link));
  if (FAILED(hr)) {
    return false;
  }
  ComPtr<IPersistFile> persist_file;
  hr = shell_link.As(&persist_file);
  if (FAILED(hr)) {
    return false;
  }
  // Load the existing .lnk so target/args/workdir survive; we only touch icon.
  hr = persist_file->Load(lnk_path.c_str(), STGM_READWRITE);
  if (FAILED(hr)) {
    return false;
  }
  hr = shell_link->SetIconLocation(icon_path.c_str(), 0);
  if (FAILED(hr)) {
    return false;
  }
  hr = persist_file->Save(lnk_path.c_str(), TRUE);
  if (FAILED(hr)) {
    return false;
  }
  // Ask the shell to re-read this .lnk's icon.
  SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, lnk_path.c_str(), nullptr);
  return true;
}

// Joins a known-folder path with |relative| (a path tail relative to the
// folder root, e.g. the desktop .lnk filename or the Start menu group
// subfolder + .lnk). Returns empty on failure.
std::wstring HibikiShortcutInFolder(REFKNOWNFOLDERID folder_id,
                                    const wchar_t* relative) {
  PWSTR folder = nullptr;
  HRESULT hr = SHGetKnownFolderPath(folder_id, 0, nullptr, &folder);
  if (FAILED(hr) || folder == nullptr) {
    if (folder != nullptr) {
      CoTaskMemFree(folder);
    }
    return std::wstring();
  }
  std::wstring path(folder);
  CoTaskMemFree(folder);
  if (!path.empty() && path.back() != L'\\') {
    path.push_back(L'\\');
  }
  path += relative;
  return path;
}

// TODO-901: points the desktop + Start menu Hibiki shortcuts at |icon_path|
// (a freshly generated multi-size .ico). Installer (hibiki.iss) drops the .lnk
// at {userdesktop}\Hibiki (Desktop\Hibiki.lnk) and {group}\Hibiki, where
// {group} = {autoprograms}\{DefaultGroupName=Hibiki} -> Programs\Hibiki\Hibiki.lnk
// (DisableProgramGroupPage only hides the wizard page; the Hibiki subfolder
// still exists). Returns true if at least one shortcut was updated. Taskbar
// pinned items are intentionally NOT touched (fragile, cached in the registry;
// see plan).
bool ApplyShortcutIcon(const std::wstring& icon_path) {
  if (icon_path.empty()) {
    return false;
  }
  bool any = false;
  const std::wstring desktop_lnk =
      HibikiShortcutInFolder(FOLDERID_Desktop, L"Hibiki.lnk");
  if (!desktop_lnk.empty()) {
    any |= SetShortcutIconLocation(desktop_lnk, icon_path);
  }
  // Start menu lives under the Hibiki program group subfolder, not Programs root.
  const std::wstring programs_lnk =
      HibikiShortcutInFolder(FOLDERID_Programs, L"Hibiki\\Hibiki.lnk");
  if (!programs_lnk.empty()) {
    any |= SetShortcutIconLocation(programs_lnk, icon_path);
  }
  // One global associations-changed notify so already-open Explorer views pick
  // the new icon up sooner (best-effort; shell icon cache is not guaranteed to
  // refresh instantly).
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  return any;
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
        } else if (call.method_name() == "setWindowIcon") {
          // Runtime window/taskbar icon (preset or user-picked image). Decodes
          // the file to big+small HICONs and WM_SETICONs them. Cannot change the
          // exe's embedded file icon — Dart re-applies the preference on startup.
          const auto* icon_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          std::wstring icon_path;
          if (icon_args != nullptr) {
            const auto path_it =
                icon_args->find(flutter::EncodableValue("path"));
            if (path_it != icon_args->end()) {
              const auto* s = std::get_if<std::string>(&path_it->second);
              if (s != nullptr) {
                icon_path = Utf8ToWideString(*s);
              }
            }
          }
          if (icon_path.empty()) {
            result->Error("bad_args", "Missing icon path");
          } else {
            const bool ok = ApplyWindowIcon(icon_path);
            result->Success(flutter::EncodableValue(ok));
          }
        } else if (call.method_name() == "setShortcutIcon") {
          // TODO-901: rewrite the desktop + Start menu Hibiki .lnk IconLocation
          // to the freshly generated multi-size .ico Dart wrote to disk. Note
          // the arg key is 'iconPath' (distinct from setWindowIcon's 'path').
          const auto* shortcut_args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          std::wstring ico_path;
          if (shortcut_args != nullptr) {
            const auto path_it =
                shortcut_args->find(flutter::EncodableValue("iconPath"));
            if (path_it != shortcut_args->end()) {
              const auto* s = std::get_if<std::string>(&path_it->second);
              if (s != nullptr) {
                ico_path = Utf8ToWideString(*s);
              }
            }
          }
          if (ico_path.empty()) {
            result->Error("bad_args", "Missing iconPath");
          } else {
            const bool ok = ApplyShortcutIcon(ico_path);
            result->Success(flutter::EncodableValue(ok));
          }
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

  // TODO-904 P0 回归：外部视频路径转交 channel。首实例无需主动调用任何方法，仅作为
  // MessageHandler 收到 WM_COPYDATA 后把路径 InvokeMethod 给 Dart 的出口。
  external_video_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki/external_video",
          &flutter::StandardMethodCodec::GetInstance());

  // TODO-1092: 系统强调色/主题色实时变更通知 channel。runner 侧收到 Windows 的
  // WM_DWMCOLORIZATIONCOLORCHANGED / WM_SETTINGCHANGE("ImmersiveColorSet") /
  // WM_THEMECHANGED 后，经此 channel 把 onSystemColorChanged 推给 Dart，触发
  // ThemeNotifier.refreshSystemPalette()——动态取色不再依赖 app 生命周期 resumed。
  // 首实例无需主动调用任何方法，仅作为 MessageHandler 的出口。
  system_theme_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.hibiki/system_theme",
          &flutter::StandardMethodCodec::GetInstance());

  RegisterFloatingLyricChannel();
  RegisterClipboardTextChannel();
  RegisterGlobalLookupChannel();
  RegisterClipboardPanelChannel();
  RegisterForegroundSelectionChannel();
  RegisterWindowCaptureChannel();
  RegisterAudioLoopbackChannel();
  RegisterVoiceHookChannel();

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
  // TODO-708 P2: 圆角半径 / 窗宽（逻辑 dp）。旧 payload 缺字段回退结构体默认 0=平台默认。
  style.corner_radius = DoubleFromValue(args, "cornerRadius", style.corner_radius);
  style.window_width = DoubleFromValue(args, "windowWidth", style.window_width);
  return style;
}

// TODO-1030 M0 — private window message posting a completed foreground-selection
// UIA capture (run on a worker thread) back to the UI thread, where the pending
// Flutter MethodResult is completed. The LPARAM is a heap-owned
// ForegroundSelectionPending* transferred to MessageHandler (which deletes it).
constexpr UINT WM_FGSEL_CAPTURE_DONE = WM_APP + 3;

// Ownership hand-off across the worker->UI thread boundary: the UIA result plus
// the still-pending Flutter reply. Deleted by MessageHandler after replying.
struct ForegroundSelectionPending {
  ForegroundSelectionResult capture;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  int64_t elapsed_ms = 0;
};

// TODO-1162 M0 — a completed window_capture WGC single-frame grab (run on a
// worker thread) posted back to the UI thread, where the pending Flutter reply
// is completed. LPARAM is a heap-owned WindowCapturePending* (deleted there).
constexpr UINT WM_WINDOWCAP_DONE = WM_APP + 4;

struct WindowCapturePending {
  hibiki::WindowCaptureResult result;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> reply;
};

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
          // TODO-708 P4: 多行上下文块内当前行区间。缺字段回退 -1/0 = 无行标记
          // （N=0 单行/旧 payload），整块满色（never-break userspace）。
          floating_lyric_window_->UpdateText(
              WideFromValue(args, "text", L""),
              IntFromValue(args, "currentLineStart", -1),
              IntFromValue(args, "currentLineLength", 0));
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

void FlutterWindow::RegisterClipboardTextChannel() {
  // Second FloatingLyricWindow instance, text-only: the transparent clipboard
  // text window. No transport / lock / close controls, no resize grip — only
  // draggable, tappable text over a per-pixel transparent background. Tap lookup
  // routes back over "lookupText" into the in-app dictionary overlay (same
  // contract as the audiobook lyric strip). Independent instance so it can be
  // shown alongside the lyric strip without either clobbering the other.
  clipboard_text_window_ = std::make_unique<FloatingLyricWindow>();
  clipboard_text_window_->SetTextOnly(true);

  clipboard_text_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/clipboard_text",
          &flutter::StandardMethodCodec::GetInstance());

  clipboard_text_window_->SetLookupCallback(
      [this](const std::string& text, int char_index) {
        flutter::EncodableMap map{
            {flutter::EncodableValue("text"), flutter::EncodableValue(text)},
            {flutter::EncodableValue("index"),
             flutter::EncodableValue(char_index)},
        };
        clipboard_text_channel_->InvokeMethod(
            "lookupText",
            std::make_unique<flutter::EncodableValue>(std::move(map)));
      });
  // The only control action the text-only toolbar emits is "toggleTransparency"
  // (the lock button toggles the drag lock natively). Forward it to Dart so the
  // controller can flip the background-opacity pref (one-click transparency).
  clipboard_text_window_->SetControlCallback(
      [this](const std::string& action) {
        clipboard_text_channel_->InvokeMethod(
            action, std::make_unique<flutter::EncodableValue>());
      });

  clipboard_text_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string& method = call.method_name();

        if (method == "canDrawOverlays") {
          // Runner-owned window — no OS overlay permission exists.
          result->Success(flutter::EncodableValue(true));
        } else if (method == "show") {
          clipboard_text_window_->UpdateStyle(StyleFromArgs(args));
          clipboard_text_window_->SetClickLookupEnabled(
              BoolFromValue(args, "clickLookupEnabled", true));
          const bool shown = clipboard_text_window_->Show(GetHandle());
          result->Success(flutter::EncodableValue(shown));
        } else if (method == "hide") {
          clipboard_text_window_->Hide();
          result->Success();
        } else if (method == "isShowing") {
          result->Success(
              flutter::EncodableValue(clipboard_text_window_->IsShowing()));
        } else if (method == "updateText") {
          // Clipboard text is a single string with no "current line" concept, so
          // the multi-line dim range stays at the default (-1/0 = whole string
          // full colour).
          clipboard_text_window_->UpdateText(WideFromValue(args, "text", L""));
          result->Success();
        } else if (method == "updateStyle") {
          clipboard_text_window_->UpdateStyle(StyleFromArgs(args));
          result->Success();
        } else if (method == "setClickLookupEnabled") {
          clipboard_text_window_->SetClickLookupEnabled(
              BoolFromValue(args, "enabled", true));
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

  // TODO-1153 -- native overlay bring-up errors (WebView2 environment/controller
  // create failure) -> Dart, so ErrorLogService surfaces "app-external lookup
  // shows no popup" like the TODO-1086 hotkey-registration failure instead of
  // swallowing it. Fires on the platform thread (WebView2 posts its completion
  // callbacks to the creating thread's loop), so InvokeMethod is safe here.
  global_lookup_window_->SetErrorCallback([this](const std::string& message) {
    global_lookup_channel_->InvokeMethod(
        "nativeError", std::make_unique<flutter::EncodableValue>(message));
  });

  // TODO-1233 -- the overlay dismissed (foreground hook / click-outside / JS
  // dismiss) -> Dart, so a resume-on-dismiss (video subtitle lookup BUG-072) or
  // the controller's own reveal-state reset can hang off it. Not fired for the
  // programmatic reset Hide(false) before a fresh lookup (see the "hide" method
  // below + GlobalLookupWindow::Hide). Fires on the platform thread.
  global_lookup_window_->SetHiddenCallback([this]() {
    global_lookup_channel_->InvokeMethod(
        "overlayHidden", std::make_unique<flutter::EncodableValue>());
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
        } else if (method == "prewarmWebView") {
          // TODO-1079 — build the overlay window + WebView2 off-screen at
          // startup so the first hotkey lookup hits a WARM surface (no cold
          // create-chain race that left the popup blank / self-closed).
          // nullptr owner：与 showAt 同源解耦（无 owner，不拉主窗前台）。prewarm
          // 与 showAt 的 owner 必须一致，否则 ForgetDeadWindow 重建时 owner 漂移。
          global_lookup_window_->PrewarmWebView(
              IntFromValue(args, "width", 420),
              IntFromValue(args, "height", 600), nullptr);
          result->Success();
        } else if (method == "isWebViewReady") {
          // TODO-1079 — the ready-driven reveal fallback confirms the WebView2
          // finished its initial navigation before revealing (else it defers).
          result->Success(flutter::EncodableValue(
              global_lookup_window_->IsWebViewReady()));
        } else if (method == "showAt") {
          int x = IntFromValue(args, "x", 0);
          int y = IntFromValue(args, "y", 0);
          POINT cursor = {x, y};
          if (BoolFromValue(args, "atCursor", false)) {
            // GetCursorPos returns physical screen pixels, matching
            // CreateWindowEx — no logical/physical DPI mismatch.
            POINT pt;
            if (GetCursorPos(&pt)) {
              cursor = pt;
              x = pt.x + 8;
              y = pt.y + 8;
            }
          }
          // nullptr owner（不传主窗 HWND）：owned 窗显示/Z 序变更会连带把
          // owner 主窗拉到前台（真机第 4 轮对面板确认的机制，见 1067 注释）。
          // 用户诉求=悬浮字幕点词等 app 外查词绝不该夺前台（覆盖窗 §5 契约）：
          // 瞬态窗也解耦成无 owner，与面板一致。短命窗（点外/前台切换即经
          // arm_dismiss_hooks 自关），主窗最小化时照样收纳，无孤儿窗回归。
          const bool ok = global_lookup_window_->ShowAt(
              x, y, IntFromValue(args, "width", 420),
              IntFromValue(args, "height", 600), nullptr);
          // TODO-893 (symptom 2) — report the CURSOR MONITOR work area
          // (physical px) so Dart's cascade layout uses the real screen, not
          // the off-screen measurement canvas. computeFrameRect's showBelow /
          // clamp must reason about the actual display: feeding the 2x card
          // canvas made every child cascade up (spaceBelow tiny), shoving the
          // parent card off the top. Dart divides workW/workH by the same dpr
          // it uses for window geometry to get CSS px (single dpr source).
          int work_w = 0;
          int work_h = 0;
          // TODO-893 v2 (symptom 3) — the WINDOW-LOCAL origin's position INSIDE
          // the cursor monitor work area (physical px). The overlay's
          // window-local (0,0) sits at the placed top-left (x, y) = cursor+8 on
          // screen; subtracting rcWork.left/top gives its offset from the work
          // area origin. Dart translates the host's window-local child anchor
          // rect into this same work-area-absolute domain before feeding
          // computeFrameRect (whose screenW/H are work-area dimensions), then
          // shifts the result back to window-local for the host shell — fixing
          // the zero-point mismatch that mis-decided showBelow near the screen
          // bottom edge and shoved the parent card off the top.
          int cursor_work_x = 0;
          int cursor_work_y = 0;
          // BUG-859 — the CURSOR MONITOR's effective scale. Dart used to divide
          // the physical-px work/cursor values above by the MAIN window's dpr;
          // on a mixed-scale multi-monitor setup that put the cascade layout's
          // work-area domain in the WRONG CSS scale (the overlay WebView2
          // rasterizes at the overlay monitor's scale), mis-placing nested
          // cards and breaking the reserve-to-edge clamp invariant. Report the
          // authoritative per-monitor dpr alongside the physical values so
          // Dart converts them in the SAME scale the page measures in. 0 =
          // monitor query failed (Dart falls back to the main-window dpr).
          double monitor_dpr = 0.0;
          HMONITOR monitor =
              MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
          MONITORINFO mi = {};
          mi.cbSize = sizeof(mi);
          if (GetMonitorInfo(monitor, &mi)) {
            work_w = mi.rcWork.right - mi.rcWork.left;
            work_h = mi.rcWork.bottom - mi.rcWork.top;
            cursor_work_x = x - mi.rcWork.left;
            cursor_work_y = y - mi.rcWork.top;
            monitor_dpr = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
          }
          flutter::EncodableMap reply = {
              {flutter::EncodableValue("ok"), flutter::EncodableValue(ok)},
              {flutter::EncodableValue("workW"),
               flutter::EncodableValue(work_w)},
              {flutter::EncodableValue("workH"),
               flutter::EncodableValue(work_h)},
              {flutter::EncodableValue("cursorWorkX"),
               flutter::EncodableValue(cursor_work_x)},
              {flutter::EncodableValue("cursorWorkY"),
               flutter::EncodableValue(cursor_work_y)},
              {flutter::EncodableValue("monitorDpr"),
               flutter::EncodableValue(monitor_dpr)},
          };
          result->Success(flutter::EncodableValue(reply));
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
        } else if (method == "revealStack") {
          // TODO-867 P3c E1 — reveal/resize to the nested-stack union bbox.
          global_lookup_window_->RevealStack(
              IntFromValue(args, "dx", 0), IntFromValue(args, "dy", 0),
              IntFromValue(args, "width", 0), IntFromValue(args, "height", 0),
              DoubleFromValue(args, "left", 0.0),
              DoubleFromValue(args, "top", 0.0));
          result->Success();
        } else if (method == "resolveBridge") {
          // Dart's real reply for a deferred audio handler. "value" is a JSON
          // literal string (jsonEncode'd in Dart): pass it straight through.
          global_lookup_window_->ResolveBridge(
              IntFromValue(args, "id", 0),
              StringFromValue(args, "value", "null"));
          result->Success();
        } else if (method == "hide") {
          // TODO-1233 -- notify defaults true (genuine dismiss); the controller
          // passes notify=false for the reset that precedes a fresh lookup so it
          // does not fire overlayHidden between two lookups.
          global_lookup_window_->Hide(BoolFromValue(args, "notify", true));
          result->Success();
        } else if (method == "isShowing") {
          result->Success(
              flutter::EncodableValue(global_lookup_window_->IsShowing()));
        } else {
          result->NotImplemented();
        }
      });
}

// spec 2026-07-10 — the persistent clipboard-lookup panel: a SECOND
// GlobalLookupWindow instance on its own channel. Mirrors
// RegisterGlobalLookupChannel wiring (media/message/error/hidden callbacks +
// the same method set) with the panel differences applied as data:
// - SetArmDismissHooks(false): click-outside / foreground-switch never close it
//   (persistent semantics; it also never touches the hook-owner singleton).
// - SetUserDataLeaf(ClipboardPanelWebView2): its own WebView2 profile folder so
//   its environment options never have to match the lookup overlay's
//   (same-folder different-options fails with 0x8007139F).
// - Extra methods: applyBackdrop (Win11 acrylic semi-transparency gate,
//   spec §6) and setPinned (panel pin toggles HWND_TOPMOST).
// - SetActivatable(true)（真机第 4 轮）: 点击面板时焦点落面板（游戏失焦），
//   滚轮只滚面板不再穿透游戏；瞬态覆盖窗保持 NOACTIVATE 不变。
void FlutterWindow::RegisterClipboardPanelChannel() {
  clipboard_panel_window_ = std::make_unique<GlobalLookupWindow>();
  clipboard_panel_window_->SetArmDismissHooks(false);
  clipboard_panel_window_->SetActivatable(true);
  // 面板任务栏图标 — 常驻面板有独立任务栏按钮（WS_EX_APPWINDOW）：面板未置顶
  // （图钉关）被游戏/浏览器压底时，点任务栏图标即可激活+拉回前台。瞬态查词窗
  // 不设，保持无任务栏项。
  clipboard_panel_window_->SetTaskbarPresence(true);
  // 背景逐像素透明（composition + DirectComposition）真机实测：窗口进了 composition
  // 模式（WS_EX_NOREDIRECTIONBITMAP）但透明像素被合成成**黑**（DComp/WebView2 alpha
  // 合成未生效），且 composition 下整窗 LWA_ALPHA 不透明度被 no-op → 反而把「之前能用
  // 的整窗不透明度」弄坏了、两头空。故暂时**关闭** composition，面板退回 windowed：
  // 整窗不透明度滑杆恢复工作。真·逐像素透明改走别的路线（悬浮歌词窗式 GDI per-pixel，
  // 或先把 DComp 黑底修对）再单独开启。composition 代码保留、休眠（默认 false）。
  clipboard_panel_window_->SetCompositionMode(false);
  clipboard_panel_window_->SetWindowTitle(L"Hibiki");
  clipboard_panel_window_->SetUserDataLeaf(L"ClipboardPanelWebView2");

  clipboard_panel_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/clipboard_panel",
          &flutter::StandardMethodCodec::GetInstance());

  clipboard_panel_window_->SetMediaResolver(
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
        clipboard_panel_channel_->InvokeMethod("getMedia", std::move(args),
                                               std::move(result));
      });

  clipboard_panel_window_->SetMessageCallback([this](const std::string& json) {
    clipboard_panel_channel_->InvokeMethod(
        "jsMessage", std::make_unique<flutter::EncodableValue>(json));
  });

  clipboard_panel_window_->SetErrorCallback([this](const std::string& message) {
    clipboard_panel_channel_->InvokeMethod(
        "nativeError", std::make_unique<flutter::EncodableValue>(message));
  });

  clipboard_panel_window_->SetHiddenCallback([this]() {
    clipboard_panel_channel_->InvokeMethod(
        "overlayHidden", std::make_unique<flutter::EncodableValue>());
  });

  clipboard_panel_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string& method = call.method_name();

        if (method == "prepare") {
          clipboard_panel_window_->SetPopupAssetsDir(
              WideFromValue(args, "assetsDir", L""));
          result->Success();
        } else if (method == "prewarmWebView") {
          // 真机修复：面板窗必须是**无 owner** 的顶层窗（nullptr，不传主窗
          // HWND）。owned window 有两个致命联动：owner 最小化时被系统一并隐藏
          // （真机症状=最小化 app 面板跟着消失），且 Z 序变更会连带 owner
          // （点图钉把主 app 拉到前台）。常驻面板的生命周期必须与主窗解耦。
          // BUG-741：瞬态查词窗（悬浮字幕点词/热键）此前保持 owned，同一 Z 序
          // 连带把主窗拉前台——用户否决「随主窗收纳」取舍，故也改无 owner。
          clipboard_panel_window_->PrewarmWebView(
              IntFromValue(args, "width", 420),
              IntFromValue(args, "height", 600), nullptr);
          result->Success();
        } else if (method == "isWebViewReady") {
          result->Success(flutter::EncodableValue(
              clipboard_panel_window_->IsWebViewReady()));
        } else if (method == "showAt") {
          // The panel is placed at a FIXED remembered rect (Dart passes the
          // final x/y; atCursor stays supported for parity but is unused).
          int x = IntFromValue(args, "x", 0);
          int y = IntFromValue(args, "y", 0);
          POINT anchor = {x, y};
          if (BoolFromValue(args, "atCursor", false)) {
            POINT pt;
            if (GetCursorPos(&pt)) {
              anchor = pt;
              x = pt.x + 8;
              y = pt.y + 8;
            }
          }
          // nullptr owner：同 prewarmWebView 的解耦理由（最小化联动/Z 序连带）。
          const bool ok = clipboard_panel_window_->ShowAt(
              x, y, IntFromValue(args, "width", 420),
              IntFromValue(args, "height", 600), nullptr);
          int work_w = 0;
          int work_h = 0;
          int anchor_work_x = 0;
          int anchor_work_y = 0;
          // BUG-859 — same monitor-dpr report as the transient overlay's
          // showAt (panel parity: the shared Dart channel parses one shape).
          double monitor_dpr = 0.0;
          HMONITOR monitor =
              MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
          MONITORINFO mi = {};
          mi.cbSize = sizeof(mi);
          if (GetMonitorInfo(monitor, &mi)) {
            work_w = mi.rcWork.right - mi.rcWork.left;
            work_h = mi.rcWork.bottom - mi.rcWork.top;
            anchor_work_x = x - mi.rcWork.left;
            anchor_work_y = y - mi.rcWork.top;
            monitor_dpr = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
          }
          flutter::EncodableMap reply = {
              {flutter::EncodableValue("ok"), flutter::EncodableValue(ok)},
              {flutter::EncodableValue("workW"),
               flutter::EncodableValue(work_w)},
              {flutter::EncodableValue("workH"),
               flutter::EncodableValue(work_h)},
              {flutter::EncodableValue("cursorWorkX"),
               flutter::EncodableValue(anchor_work_x)},
              {flutter::EncodableValue("cursorWorkY"),
               flutter::EncodableValue(anchor_work_y)},
              {flutter::EncodableValue("monitorDpr"),
               flutter::EncodableValue(monitor_dpr)},
          };
          result->Success(flutter::EncodableValue(reply));
        } else if (method == "render") {
          clipboard_panel_window_->RenderJson(
              StringFromValue(args, "json", ""));
          result->Success();
        } else if (method == "resize") {
          clipboard_panel_window_->ResizeTo(IntFromValue(args, "width", 0),
                                            IntFromValue(args, "height", 0));
          result->Success();
        } else if (method == "reveal") {
          clipboard_panel_window_->Reveal(IntFromValue(args, "width", 0),
                                          IntFromValue(args, "height", 0));
          result->Success();
        } else if (method == "revealStack") {
          clipboard_panel_window_->RevealStack(
              IntFromValue(args, "dx", 0), IntFromValue(args, "dy", 0),
              IntFromValue(args, "width", 0), IntFromValue(args, "height", 0),
              DoubleFromValue(args, "left", 0.0),
              DoubleFromValue(args, "top", 0.0));
          result->Success();
        } else if (method == "resolveBridge") {
          clipboard_panel_window_->ResolveBridge(
              IntFromValue(args, "id", 0),
              StringFromValue(args, "value", "null"));
          result->Success();
        } else if (method == "hide") {
          clipboard_panel_window_->Hide(BoolFromValue(args, "notify", true));
          result->Success();
        } else if (method == "isShowing") {
          result->Success(
              flutter::EncodableValue(clipboard_panel_window_->IsShowing()));
        } else if (method == "applyBackdrop") {
          // spec §6 — Win11 acrylic backdrop behind the panel's transparent
          // WebView2 pixels; returns whether the OS accepted it so Dart can
          // gate the opacity slider (false -> panel stays opaque).
          result->Success(flutter::EncodableValue(
              clipboard_panel_window_->ApplySystemBackdrop()));
        } else if (method == "setPinned") {
          clipboard_panel_window_->SetTopmost(
              BoolFromValue(args, "pinned", true));
          result->Success();
        } else if (method == "setBlockCapture") {
          // 防截屏 — WDA_EXCLUDEFROMCAPTURE：面板对用户可见但不进截图 / 录屏 /
          // 屏幕共享。默认 true（Dart pref clipboardPanelBlockCapture 默认开）。
          clipboard_panel_window_->SetBlockCapture(
              BoolFromValue(args, "block", true));
          result->Success();
        } else if (method == "raise") {
          // 面板抬前台 — 每次查词把已显示的面板重排到 z 序最上，不抢焦点；
          // topmost（已 pin）直接置顶，否则顶到非置顶带最上（见 RaiseToFront）。
          clipboard_panel_window_->RaiseToFront(
              BoolFromValue(args, "topmost", false));
          result->Success();
        } else if (method == "setWindowTitle") {
          // 面板任务栏图标 — Dart 传本地化标题（任务栏按钮 / Alt-Tab 项）。
          clipboard_panel_window_->SetWindowTitle(
              Utf8ToWideString(StringFromValue(args, "title", "")));
          result->Success();
        } else if (method == "setWindowAlpha") {
          // spec §6 真机修正 — 整窗 LWA_ALPHA 透明（真透视；acrylic 实测经
          // windowed WebView2 呈现为不透明，且毛玻璃本就不是「看见底下」）。
          clipboard_panel_window_->SetWindowAlpha(
              IntFromValue(args, "percent", 100));
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

// TODO-1030 M0 — Windows UIA foreground-selection context capture channel.
// Dart (selection_capture_ffi.dart) calls `captureContext` when the global
// lookup pref opts into context capture. The UIA call can block 50-200ms
// cross-process, so it runs on a DETACHED worker thread; the completed result is
// marshalled back to the UI thread via WM_FGSEL_CAPTURE_DONE, where the pending
// Flutter reply is finished (MethodResult is not thread-safe). A failure returns
// null so Dart falls back to the clipboard capture (never break userspace).
void FlutterWindow::RegisterForegroundSelectionChannel() {
  foreground_selection_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/foreground_selection",
          &flutter::StandardMethodCodec::GetInstance());

  foreground_selection_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "captureContext") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        const int max_expand =
            IntFromValue(args, "maxExpand", kForegroundContextExpand);
        const HWND hwnd = GetHandle();
        // Move the pending reply onto the heap so the worker thread can own it
        // until the UI thread completes it (via WM_FGSEL_CAPTURE_DONE).
        auto* pending = new ForegroundSelectionPending();
        pending->result = std::move(result);
        std::thread([hwnd, max_expand, pending]() {
          const LARGE_INTEGER t0 = [] {
            LARGE_INTEGER v;
            QueryPerformanceCounter(&v);
            return v;
          }();
          pending->capture = CaptureForegroundSelectionContext(max_expand);
          LARGE_INTEGER t1;
          QueryPerformanceCounter(&t1);
          LARGE_INTEGER freq;
          QueryPerformanceFrequency(&freq);
          pending->elapsed_ms = freq.QuadPart > 0
              ? ((t1.QuadPart - t0.QuadPart) * 1000) / freq.QuadPart
              : 0;
          // Hand ownership to the UI thread. If PostMessage fails (window gone),
          // reply null here and delete to avoid a leak / dangling result.
          if (!PostMessage(hwnd, WM_FGSEL_CAPTURE_DONE, 0,
                           reinterpret_cast<LPARAM>(pending))) {
            pending->result->Success(flutter::EncodableValue());
            delete pending;
          }
        }).detach();
      });
}

// TODO-1162 M0 — window_capture channel (Windows-only external-window mining).
// `listWindows` runs synchronously (EnumWindows is instant). `captureWindow`
// runs the blocking WGC single-frame grab on a DETACHED worker thread and
// marshals the PNG/error back to the UI thread via WM_WINDOWCAP_DONE (the
// Flutter MethodResult is not thread-safe), mirroring the foreground-selection
// channel. Both fail-open with an error map (never a silent success).
void FlutterWindow::RegisterWindowCaptureChannel() {
  window_capture_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/window_capture",
          &flutter::StandardMethodCodec::GetInstance());

  window_capture_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "listWindows") {
          const std::vector<hibiki::ExternalWindow> windows =
              hibiki::EnumerateTopLevelWindows(GetHandle());
          flutter::EncodableList list;
          for (const auto& w : windows) {
            list.push_back(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("hwnd"),
                 flutter::EncodableValue(static_cast<int64_t>(
                     reinterpret_cast<intptr_t>(w.hwnd)))},
                {flutter::EncodableValue("title"),
                 flutter::EncodableValue(w.title)},
                {flutter::EncodableValue("pid"),
                 flutter::EncodableValue(static_cast<int64_t>(w.pid))},
            }));
          }
          result->Success(flutter::EncodableValue(std::move(list)));
          return;
        }
        if (method != "captureWindow") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        int64_t hwnd_val = 0;
        if (args != nullptr) {
          const auto it = args->find(flutter::EncodableValue("hwnd"));
          if (it != args->end()) {
            hwnd_val = it->second.TryGetLongValue().value_or(0);
          }
        }
        if (hwnd_val == 0) {
          result->Error("bad_args", "Missing hwnd");
          return;
        }
        const HWND target =
            reinterpret_cast<HWND>(static_cast<intptr_t>(hwnd_val));
        const HWND host = GetHandle();
        auto* pending = new WindowCapturePending();
        pending->reply = std::move(result);
        std::thread([target, host, pending]() {
          pending->result = hibiki::CaptureWindowPng(target);
          if (!PostMessage(host, WM_WINDOWCAP_DONE, 0,
                           reinterpret_cast<LPARAM>(pending))) {
            pending->reply->Success(
                flutter::EncodableValue(flutter::EncodableMap{
                    {flutter::EncodableValue("error"),
                     flutter::EncodableValue(
                         std::string("post message failed"))}}));
            delete pending;
          }
        }).detach();
      });
}

// galgame 一键制卡 A 阶段 — audio_loopback channel（仅 Windows）。start 打开 WASAPI
// loopback 采集进环形缓冲（同步握手拿格式）；grabRecent 拉最近 N 毫秒 PCM；stop 释放。
// 采集/环形缓冲逻辑在 AudioLoopbackCapture 单例（见 audio_loopback_capture.cpp）。native
// 内部全程 HRESULT 校验，失败以 error map fail-open（Dart 侧 LoopbackGalAudioSource 降级）。
void FlutterWindow::RegisterAudioLoopbackChannel() {
  audio_loopback_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/audio_loopback",
          &flutter::StandardMethodCodec::GetInstance());

  audio_loopback_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        auto format_map = [](const hibiki::LoopbackFormat& f) {
          return flutter::EncodableMap{
              {flutter::EncodableValue("sampleRate"),
               flutter::EncodableValue(f.sample_rate)},
              {flutter::EncodableValue("channels"),
               flutter::EncodableValue(f.channels)},
              {flutter::EncodableValue("bitsPerSample"),
               flutter::EncodableValue(f.bits_per_sample)},
              {flutter::EncodableValue("isFloat"),
               flutter::EncodableValue(f.is_float)},
          };
        };
        if (method == "start") {
          const hibiki::LoopbackFormat f =
              hibiki::AudioLoopbackCapture::Instance().Start();
          if (!f.ok) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(
                     std::string("loopback start failed"))}}));
            return;
          }
          result->Success(flutter::EncodableValue(format_map(f)));
          return;
        }
        if (method == "stop") {
          hibiki::AudioLoopbackCapture::Instance().Stop();
          result->Success();
          return;
        }
        if (method == "grabRecent") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          int back_ms = 0;
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("backMs"));
            if (it != args->end()) {
              back_ms = static_cast<int>(
                  it->second.TryGetLongValue().value_or(0));
            }
          }
          std::vector<uint8_t> pcm;
          const hibiki::LoopbackFormat f =
              hibiki::AudioLoopbackCapture::Instance().GrabRecent(back_ms, pcm);
          if (!f.ok || pcm.empty()) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(std::string("no audio buffered"))}}));
            return;
          }
          flutter::EncodableMap out = format_map(f);
          out[flutter::EncodableValue("pcm")] =
              flutter::EncodableValue(std::move(pcm));
          result->Success(flutter::EncodableValue(std::move(out)));
          return;
        }
        result->NotImplemented();
      });
}

// galgame 一键制卡 C 阶段 — voice_hook channel（仅 Windows）。open{pid} 打开隔离组件建好的
// 共享内存；status 轮询 hook 是否就绪（hooked/calibrating/格式）；grabRecent{backMs} 拉最近 N
// 毫秒干净语音 PCM；close 解除映射。注入/挂钩代码全在独立 injector+hook DLL，本体只**读**共享
// 内存（读不是注入、不被杀软标记）。native fail-open：无映射/未就绪返回 error map，Dart 侧
// EngineHookGalAudioSource 据此降级回 loopback。
void FlutterWindow::RegisterVoiceHookChannel() {
  voice_hook_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.hibiki.reader/voice_hook",
          &flutter::StandardMethodCodec::GetInstance());

  voice_hook_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        auto status_map = [](const hibiki::VoiceHookStatus& s) {
          return flutter::EncodableMap{
              {flutter::EncodableValue("sampleRate"),
               flutter::EncodableValue(s.sample_rate)},
              {flutter::EncodableValue("channels"),
               flutter::EncodableValue(s.channels)},
              {flutter::EncodableValue("bitsPerSample"),
               flutter::EncodableValue(s.bits_per_sample)},
              {flutter::EncodableValue("isFloat"),
               flutter::EncodableValue(s.is_float)},
              {flutter::EncodableValue("hooked"),
               flutter::EncodableValue(s.hooked)},
              {flutter::EncodableValue("calibrating"),
               flutter::EncodableValue(s.calibrating)},
              {flutter::EncodableValue("textHooked"),
               flutter::EncodableValue(s.text_hooked)},
              {flutter::EncodableValue("ready"),
               flutter::EncodableValue(s.ok)},
          };
        };
        auto read_long = [&call](const char* key) -> int64_t {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            return 0;
          }
          const auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) {
            return 0;
          }
          return it->second.TryGetLongValue().value_or(0);
        };
        auto read_pid = [&call]() -> uint32_t {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            return 0;
          }
          const auto it = args->find(flutter::EncodableValue("pid"));
          if (it == args->end()) {
            return 0;
          }
          return static_cast<uint32_t>(
              it->second.TryGetLongValue().value_or(0));
        };
        if (method == "open") {
          const uint32_t pid = read_pid();
          const hibiki::VoiceHookStatus s =
              hibiki::VoiceHookReader::Instance().Open(pid);
          // open 成功但 hook 未就绪也不算错误（调用方轮询 status）：只有映射不存在
          // （s 全零且 !hooked）才回 error，让 Dart 侧降级。
          if (!s.hooked && !s.ok) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(
                     std::string("voice hook shared memory not found"))}}));
            return;
          }
          result->Success(flutter::EncodableValue(status_map(s)));
          return;
        }
        if (method == "status") {
          result->Success(flutter::EncodableValue(
              status_map(hibiki::VoiceHookReader::Instance().Status())));
          return;
        }
        if (method == "grabRecent") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          int back_ms = 0;
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("backMs"));
            if (it != args->end()) {
              back_ms = static_cast<int>(
                  it->second.TryGetLongValue().value_or(0));
            }
          }
          std::vector<uint8_t> pcm;
          const hibiki::VoiceHookStatus s =
              hibiki::VoiceHookReader::Instance().GrabRecent(back_ms, pcm);
          if (!s.ok || pcm.empty()) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(
                     std::string("no voice buffered"))}}));
            return;
          }
          flutter::EncodableMap out = status_map(s);
          out[flutter::EncodableValue("pcm")] =
              flutter::EncodableValue(std::move(pcm));
          result->Success(flutter::EncodableValue(std::move(out)));
          return;
        }
        if (method == "pollText") {
          // 取 (fromSeq, count] 的新台词行，喂 Dart 的 texthooker。
          const uint64_t from_seq =
              static_cast<uint64_t>(read_long("fromSeq"));
          std::vector<hibiki::VoiceHookText> lines;
          hibiki::VoiceHookReader::Instance().PollText(from_seq, lines);
          const uint64_t count =
              hibiki::VoiceHookReader::Instance().TextWriteCount();
          flutter::EncodableList list;
          for (const auto& ln : lines) {
            list.push_back(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("seq"),
                 flutter::EncodableValue(static_cast<int64_t>(ln.seq))},
                {flutter::EncodableValue("ts"),
                 flutter::EncodableValue(static_cast<int64_t>(ln.timestamp_ms))},
                {flutter::EncodableValue("text"),
                 flutter::EncodableValue(ln.utf8)},
            }));
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("count"),
               flutter::EncodableValue(static_cast<int64_t>(count))},
              {flutter::EncodableValue("lines"),
               flutter::EncodableValue(std::move(list))},
          }));
          return;
        }
        if (method == "grabClipNear") {
          // 按句取语音：找时间戳与 tsMs 最近（差 <= tolMs）的语音 clip PCM。
          const uint64_t ts = static_cast<uint64_t>(read_long("tsMs"));
          uint64_t tol = static_cast<uint64_t>(read_long("tolMs"));
          if (tol == 0) {
            tol = 3000;  // 缺省 ±3s
          }
          std::vector<uint8_t> pcm;
          const hibiki::VoiceHookStatus s =
              hibiki::VoiceHookReader::Instance().GrabClipNear(ts, tol, pcm);
          if (!s.ok || pcm.empty()) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(std::string("no clip near timestamp"))}}));
            return;
          }
          flutter::EncodableMap out = status_map(s);
          out[flutter::EncodableValue("pcm")] =
              flutter::EncodableValue(std::move(pcm));
          result->Success(flutter::EncodableValue(std::move(out)));
          return;
        }
        if (method == "processIsWow64") {
          // 查目标进程位数：hibiki.exe 是 64 位，故 IsWow64Process==TRUE 即目标为 32 位
          // （多数 KiriKiri 游戏），Dart 据此选 x86 注入器；FALSE 为 64 位选 x64。
          const uint32_t pid = read_pid();
          if (pid == 0) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(std::string("no pid"))}}));
            return;
          }
          HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 static_cast<DWORD>(pid));
          if (h == nullptr) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(std::string("open process failed"))}}));
            return;
          }
          BOOL wow64 = FALSE;
          const BOOL ok = IsWow64Process(h, &wow64);
          CloseHandle(h);
          if (!ok) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(std::string("IsWow64Process failed"))}}));
            return;
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("isWow64"),
               flutter::EncodableValue(wow64 != FALSE)}}));
          return;
        }
        if (method == "close") {
          hibiki::VoiceHookReader::Instance().Close();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::NotifySystemColorChanged() {
  // TODO-1092: 把「系统强调色/主题色已变」事件推给 Dart。WndProc 跑在 platform
  // 线程，InvokeMethod 可直接调用。channel 在 OnCreate 建好前（极早期消息）可能为
  // 空，做 null 保护后静默忽略——启动完成后所有实时变更都会被投递。
  if (system_theme_channel_) {
    system_theme_channel_->InvokeMethod(
        "onSystemColorChanged", std::make_unique<flutter::EncodableValue>());
  }
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

bool FlutterWindow::ApplyWindowIcon(const std::wstring& path) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  int big_size = GetSystemMetrics(SM_CXICON);
  int small_size = GetSystemMetrics(SM_CXSMICON);
  HICON new_big = CreateIconFromImageFile(path, big_size > 0 ? big_size : 32);
  HICON new_small =
      CreateIconFromImageFile(path, small_size > 0 ? small_size : 16);
  if (new_big == nullptr && new_small == nullptr) {
    return false;
  }
  if (new_big != nullptr) {
    SendMessage(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(new_big));
    if (icon_big_ != nullptr) {
      DestroyIcon(icon_big_);
    }
    icon_big_ = new_big;
  }
  if (new_small != nullptr) {
    SendMessage(hwnd, WM_SETICON, ICON_SMALL,
                reinterpret_cast<LPARAM>(new_small));
    if (icon_small_ != nullptr) {
      DestroyIcon(icon_small_);
    }
    icon_small_ = new_small;
  }
  return true;
}

void FlutterWindow::OnDestroy() {
  if (icon_big_ != nullptr) {
    DestroyIcon(icon_big_);
    icon_big_ = nullptr;
  }
  if (icon_small_ != nullptr) {
    DestroyIcon(icon_small_);
    icon_small_ = nullptr;
  }
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
    case WM_FGSEL_CAPTURE_DONE: {
      // TODO-1030 M0 — a worker-thread UIA capture finished; complete its
      // pending Flutter reply here on the UI thread. On success return a
      // {contextText, selStart, selLen} map; on failure return null so Dart
      // falls back to the clipboard capture. NEVER log capture.text (privacy);
      // only lengths / elapsed / ok are diagnostic-safe.
      auto* pending =
          reinterpret_cast<ForegroundSelectionPending*>(lparam);
      if (pending != nullptr) {
        if (pending->capture.ok) {
          pending->result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("contextText"),
               flutter::EncodableValue(pending->capture.text)},
              {flutter::EncodableValue("selStart"),
               flutter::EncodableValue(pending->capture.sel_start)},
              {flutter::EncodableValue("selLen"),
               flutter::EncodableValue(pending->capture.sel_len)},
              {flutter::EncodableValue("elapsedMs"),
               flutter::EncodableValue(
                   static_cast<int>(pending->elapsed_ms))}}));
        } else {
          pending->result->Success(flutter::EncodableValue());
        }
        delete pending;
      }
      return 0;
    }
    case WM_WINDOWCAP_DONE: {
      // TODO-1162 M0 — a worker-thread WGC capture finished; complete its
      // pending Flutter reply on the UI thread. On success return
      // {pngBytes: Uint8List}; on failure {error: String} (fail-open, never a
      // silent empty success).
      auto* pending = reinterpret_cast<WindowCapturePending*>(lparam);
      if (pending != nullptr) {
        if (pending->result.ok && !pending->result.png.empty()) {
          pending->reply->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("pngBytes"),
               flutter::EncodableValue(pending->result.png)}}));
        } else {
          const std::string err = pending->result.error.empty()
                                      ? std::string("capture failed")
                                      : pending->result.error;
          pending->reply->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("error"),
               flutter::EncodableValue(err)}}));
        }
        delete pending;
      }
      return 0;
    }
    case WM_COPYDATA: {
      // TODO-904 P0 回归：第二实例转交「用 Hibiki 打开视频」的路径。解出 UTF-8 路径
      // （dwData magic 不匹配则 DecodeExternalVideoPath 返回空串，忽略非本协议消息），
      // 经 app.hibiki/external_video channel 推给 Dart 复用 _openExternalVideo。
      // WndProc 跑在 platform 线程，InvokeMethod 可直接调用。
      const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      const std::string video_path = ::hibiki::DecodeExternalVideoPath(cds);
      if (!video_path.empty() && external_video_channel_) {
        external_video_channel_->InvokeMethod(
            "openExternalVideo",
            std::make_unique<flutter::EncodableValue>(video_path));
        return TRUE;  // 已处理本 WM_COPYDATA。
      }
      break;
    }
    // TODO-1092: 系统强调色/主题色实时变更。三条广播覆盖不同触发面：
    //   WM_DWMCOLORIZATIONCOLORCHANGED — DWM 玻璃/强调色变（改强调色即发）；
    //   WM_SETTINGCHANGE + lParam=="ImmersiveColorSet" — 设置里改「浅色/深色/强调色」；
    //   WM_THEMECHANGED — 经典主题切换。
    // 收到后通知 Dart 重新取系统色（refreshSystemPalette），随后 **不消费** 消息、
    // 落到下面 Win32Window::MessageHandler 走默认处理，保持既有其它消息分支语义不变。
    case WM_DWMCOLORIZATIONCOLORCHANGED:
    case WM_THEMECHANGED:
      NotifySystemColorChanged();
      break;
    case WM_SETTINGCHANGE: {
      const auto* area = reinterpret_cast<const wchar_t*>(lparam);
      if (area != nullptr && wcscmp(area, L"ImmersiveColorSet") == 0) {
        NotifySystemColorChanged();
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
