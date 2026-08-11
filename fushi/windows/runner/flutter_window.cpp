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
#include "ime_space_dispatch.h"
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
std::wstring FushiShortcutInFolder(REFKNOWNFOLDERID folder_id,
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

// TODO-901: points the desktop + Start menu Fushi shortcuts at |icon_path|
// (a freshly generated multi-size .ico). Installer (hibiki.iss) drops the .lnk
// at {userdesktop}\Fushi (Desktop\Fushi.lnk) and {group}\Fushi, where
// {group} = {autoprograms}\{DefaultGroupName=Fushi} -> Programs\Fushi\Fushi.lnk
// (DisableProgramGroupPage only hides the wizard page; the Fushi subfolder
// still exists). Returns true if at least one shortcut was updated. Taskbar
// pinned items are intentionally NOT touched (fragile, cached in the registry;
// see plan).
bool ApplyShortcutIcon(const std::wstring& icon_path) {
  if (icon_path.empty()) {
    return false;
  }
  bool any = false;
  const std::wstring desktop_lnk =
      FushiShortcutInFolder(FOLDERID_Desktop, L"Fushi.lnk");
  if (!desktop_lnk.empty()) {
    any |= SetShortcutIconLocation(desktop_lnk, icon_path);
  }
  // Start menu lives under the Fushi program group subfolder, not Programs root.
  const std::wstring programs_lnk =
      FushiShortcutInFolder(FOLDERID_Programs, L"Fushi\\Fushi.lnk");
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
          flutter_controller_->engine()->messenger(), "app.fushi/window",
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
          // TODO-901: rewrite the desktop + Start menu Fushi .lnk IconLocation
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
          "app.fushi.reader/clipboard_image",
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
          "app.fushi/external_video",
          &flutter::StandardMethodCodec::GetInstance());

  // TODO-1092: 系统强调色/主题色实时变更通知 channel。runner 侧收到 Windows 的
  // WM_DWMCOLORIZATIONCOLORCHANGED / WM_SETTINGCHANGE("ImmersiveColorSet") /
  // WM_THEMECHANGED 后，经此 channel 把 onSystemColorChanged 推给 Dart，触发
  // ThemeNotifier.refreshSystemPalette()——动态取色不再依赖 app 生命周期 resumed。
  // 首实例无需主动调用任何方法，仅作为 MessageHandler 的出口。
  system_theme_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.fushi/system_theme",
          &flutter::StandardMethodCodec::GetInstance());

  windows_ime_space_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.fushi/windows_ime_space",
          &flutter::StandardMethodCodec::GetInstance());

  RegisterImeGuardChannel();
  RegisterFloatingLyricChannel();
  RegisterClipboardTextChannel();
  RegisterGalHookTextChannel();
  RegisterGlobalLookupChannel();
  RegisterClipboardPanelChannel();
  RegisterForegroundSelectionChannel();
  RegisterWindowCaptureChannel();
  RegisterAudioLoopbackChannel();
  RegisterVoiceHookChannel();
  RegisterMagpieChannel();

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

// 解包可选的注音区间列表（`[{start, length, ruby}, ...]`）。
//
// 字段缺失、类型不对、区间非法都只是「这条没有注音」，绝不让整条 updateText 失败：
// 旧 Dart 端不会带这个字段，浮窗必须照常显示文本（never-break userspace）。
// start / length 的越界校验放在 FloatingLyricWindow::UpdateText 里做，因为只有那里
// 才知道最终文本长度。
std::vector<FloatingLyricWindow::RubySpan> RubySpansFromValue(
    const flutter::EncodableMap* args, const char* key) {
  std::vector<FloatingLyricWindow::RubySpan> spans;
  if (args == nullptr) {
    return spans;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return spans;
  }
  const auto* list = std::get_if<flutter::EncodableList>(&it->second);
  if (list == nullptr) {
    return spans;
  }
  for (const auto& item : *list) {
    const auto* map = std::get_if<flutter::EncodableMap>(&item);
    if (map == nullptr) {
      continue;
    }
    FloatingLyricWindow::RubySpan span;
    span.start = IntFromValue(map, "start", -1);
    span.length = IntFromValue(map, "length", 0);
    span.ruby = WideFromValue(map, "ruby", L"");
    if (span.start < 0 || span.length <= 0 || span.ruby.empty()) {
      continue;
    }
    spans.push_back(std::move(span));
  }
  return spans;
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
  style.window_height =
      DoubleFromValue(args, "windowHeight", style.window_height);
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
  fushi::WindowCaptureResult result;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> reply;
};

}  // namespace

void FlutterWindow::RegisterFloatingLyricChannel() {
  floating_lyric_window_ = std::make_unique<FloatingLyricWindow>();

  floating_lyric_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.fushi.reader/floating_lyric",
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

void FlutterWindow::RegisterImeGuardChannel() {
  // BUG-1450: Dart owns focus knowledge, the runner owns the HWND. Dart calls
  // setImeEnabled(false) while nothing editable holds focus so a CJK IME stops
  // consuming shortcut keys, and setImeEnabled(true) the moment a text field
  // takes focus so Chinese/Japanese input keeps working everywhere.
  ime_association_guard_ = ImeAssociationGuard(
      [](HWND hwnd, bool enable, void*) {
        return ApplyImeAssociation(hwnd, enable);
      },
      nullptr);

  windows_ime_guard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.fushi/windows_ime_guard",
          &flutter::StandardMethodCodec::GetInstance());

  windows_ime_guard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setImeEnabled") {
          result->NotImplemented();
          return;
        }
        const auto* enable = std::get_if<bool>(call.arguments());
        if (enable == nullptr) {
          result->Error("bad_args", "setImeEnabled expects a bool");
          return;
        }
        // The IME context is per-HWND and applies to whichever window holds
        // focus. Win32Window::SetChildContent does SetFocus(child), so the
        // Flutter view — not the top-level frame — is the window the IME talks
        // to. Fall back to the frame only if the view is gone (teardown).
        HWND target = flutter_controller_ && flutter_controller_->view()
                          ? flutter_controller_->view()->GetNativeWindow()
                          : nullptr;
        if (target == nullptr) {
          target = GetHandle();
        }
        const ImeAssociationUpdate update =
            ime_association_guard_.SetEnabled(target, *enable);
        if (update == ImeAssociationUpdate::kFailed) {
          // Let Dart clear its optimistic cache so the same desired state can
          // be retried. Reporting Success here would strand a recreated view
          // with the wrong association until some unrelated focus transition.
          result->Error("ime_association_failed",
                        "ImmAssociateContextEx failed for the Flutter view");
          return;
        }
        result->Success();
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
          "app.fushi.reader/clipboard_text",
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
          // Localised taskbar / Alt+Tab label (seeds the title before the first
          // Show creates the window, retitles it thereafter).
          clipboard_text_window_->SetWindowTitle(
              WideFromValue(args, "windowTitle", L""));
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
          // full colour). rubySpans 缺省 = 无注音，排版逐像素与今天一致。
          clipboard_text_window_->UpdateText(
              WideFromValue(args, "text", L""), -1, 0, std::string(),
              RubySpansFromValue(args, "rubySpans"));
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

void FlutterWindow::RegisterGalHookTextChannel() {
  gal_hook_text_window_ = std::make_unique<FloatingLyricWindow>();
  gal_hook_text_window_->SetHookTextMode(true);

  gal_hook_text_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.fushi.reader/gal_hook_text",
          &flutter::StandardMethodCodec::GetInstance());

  gal_hook_text_window_->SetContextLookupCallback(
      [this](const std::string& line_id, const std::string& text,
             int char_index, const D2D1_RECT_F& word_rect) {
        // wordLeft/Top/Width/Height：被点字的屏幕逻辑 px 矩形，供查词卡锚定到
        // 那个词（而不是鼠标位置）。
        flutter::EncodableMap map{
            {flutter::EncodableValue("lineId"),
             flutter::EncodableValue(line_id)},
            {flutter::EncodableValue("text"), flutter::EncodableValue(text)},
            {flutter::EncodableValue("index"),
             flutter::EncodableValue(char_index)},
            {flutter::EncodableValue("wordLeft"),
             flutter::EncodableValue(static_cast<double>(word_rect.left))},
            {flutter::EncodableValue("wordTop"),
             flutter::EncodableValue(static_cast<double>(word_rect.top))},
            {flutter::EncodableValue("wordWidth"),
             flutter::EncodableValue(
                 static_cast<double>(word_rect.right - word_rect.left))},
            {flutter::EncodableValue("wordHeight"),
             flutter::EncodableValue(
                 static_cast<double>(word_rect.bottom - word_rect.top))},
        };
        gal_hook_text_channel_->InvokeMethod(
            "lookupText",
            std::make_unique<flutter::EncodableValue>(std::move(map)));
      });
  gal_hook_text_window_->SetControlCallback(
      [this](const std::string& action) {
        gal_hook_text_channel_->InvokeMethod(
            action, std::make_unique<flutter::EncodableValue>());
      });
  gal_hook_text_window_->SetLockCallback([this](bool locked) {
    flutter::EncodableMap map{
        {flutter::EncodableValue("locked"), flutter::EncodableValue(locked)},
    };
    gal_hook_text_channel_->InvokeMethod(
        "lockChanged",
        std::make_unique<flutter::EncodableValue>(std::move(map)));
  });
  gal_hook_text_window_->SetPassThroughCallback([this](bool enabled) {
    flutter::EncodableMap map{
        {flutter::EncodableValue("passThrough"),
         flutter::EncodableValue(enabled)},
    };
    gal_hook_text_channel_->InvokeMethod(
        "passThroughChanged",
        std::make_unique<flutter::EncodableValue>(std::move(map)));
  });
  gal_hook_text_window_->SetBoundsCallback(
      [this](int left, int top, int width, int height) {
        flutter::EncodableMap map{
            {flutter::EncodableValue("left"), flutter::EncodableValue(left)},
            {flutter::EncodableValue("top"), flutter::EncodableValue(top)},
            {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
            {flutter::EncodableValue("height"),
             flutter::EncodableValue(height)},
        };
        gal_hook_text_channel_->InvokeMethod(
            "windowRectChanged",
            std::make_unique<flutter::EncodableValue>(std::move(map)));
      });

  // ── v14 游戏内查词：把共享内存查词通道接到这条既有通道上 ──────────────────
  // 通道复用 gal_hook_text 而不是新开一条：查词命中与台词浮窗是同一个 galgame 会话的
  // 两个面，Dart 侧的 GalHookTextOverlayController 已经守着这条通道。
  fushi::VoiceHookReader::Instance().AttachLookupChannel(
      flutter_controller_->engine()->messenger());
  // 像素源与输入落点都指向懒建的第三个 GlobalLookupWindow 实例。lambda 里每次重新
  // Ensure：用户可能在会话中途才开启查词，那时才建得起来。
  fushi::VoiceHookReader::Instance().SetLookupCaptureRequest(
      [this](uint32_t max_width, uint32_t max_height,
             fushi::VoiceHookReader::LookupCaptureCallback done) {
        GlobalLookupWindow* card = EnsureGalLookupCardWindow();
        if (card == nullptr) {
          done(false, false, {}, 0, 0, 0);
          return;
        }
        card->CaptureBgraAsync(max_width, max_height, std::move(done));
      });
  fushi::VoiceHookReader::Instance().SetLookupInputSink(
      [this](uint32_t kind, int32_t x, int32_t y, int32_t wheel,
             uint32_t keys) {
        GlobalLookupWindow* card = EnsureGalLookupCardWindow();
        if (card == nullptr) return;
        card->InjectLookupInput(kind, x, y, wheel, keys);
      });

  gal_hook_text_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        // 查词方法先走一遍：同名通道只有一个 handler 槽位，所以 reader 侧不能自己
        // 注册（会顶掉本处理器），只能挂在分发链最前面。不认的方法它返回 false。
        if (fushi::VoiceHookReader::Instance().TryHandleLookupMethodCall(
                call, result)) {
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string& method = call.method_name();
        if (method == "canDrawOverlays") {
          result->Success(flutter::EncodableValue(true));
        } else if (method == "show") {
          gal_hook_text_window_->UpdateStyle(StyleFromArgs(args));
          gal_hook_text_window_->SetClickLookupEnabled(
              BoolFromValue(args, "clickLookupEnabled", true));
          gal_hook_text_window_->SetHoverAutoLookup(
              BoolFromValue(args, "hoverAutoLookup", false));
          // 置顶按会话复位（与 locked / passThrough / following 同规矩）：上一局
          // 关掉置顶后，这一局的浮窗不该藏在全屏游戏后面让用户以为它没出来。
          gal_hook_text_window_->SetTopmost(
              BoolFromValue(args, "topmost", true));
          gal_hook_text_window_->SetLocked(
              BoolFromValue(args, "locked", false));
          gal_hook_text_window_->SetPassThrough(
              BoolFromValue(args, "passThrough", false));
          gal_hook_text_window_->SetPlaybackState(
              BoolFromValue(args, "following", true));
          // 同一 window 对象跨会话复用：重新 show 时语音控件必须回到静止态，
          // 否则上一会话遗留的「录音中」高亮会挂在新会话的浮窗上。
          gal_hook_text_window_->SetVoiceState(false, false);
          gal_hook_text_window_->SetInitialBounds(
              IntFromValue(args, "left", 0), IntFromValue(args, "top", 0),
              IntFromValue(args, "width", 0),
              IntFromValue(args, "height", 0));
          result->Success(
              flutter::EncodableValue(gal_hook_text_window_->Show(GetHandle())));
        } else if (method == "hide") {
          gal_hook_text_window_->Hide();
          result->Success();
        } else if (method == "isShowing") {
          result->Success(
              flutter::EncodableValue(gal_hook_text_window_->IsShowing()));
        } else if (method == "updateText") {
          gal_hook_text_window_->UpdateText(
              WideFromValue(args, "text", L""), -1, 0,
              StringFromValue(args, "lineId", ""),
              RubySpansFromValue(args, "rubySpans"));
          result->Success();
        } else if (method == "updateStyle") {
          gal_hook_text_window_->UpdateStyle(StyleFromArgs(args));
          result->Success();
        } else if (method == "setClickLookupEnabled") {
          gal_hook_text_window_->SetClickLookupEnabled(
              BoolFromValue(args, "enabled", true));
          result->Success();
        } else if (method == "setHoverAutoLookup") {
          // 「悬停即查词」live 下发：设置页一改，正在开着的浮窗立刻跟上，不必等下
          // 一局游戏（与字号 applyFontSizeFromPreferences 同款纪律）。
          gal_hook_text_window_->SetHoverAutoLookup(
              BoolFromValue(args, "enabled", false));
          result->Success();
        } else if (method == "setLocked") {
          gal_hook_text_window_->SetLocked(
              BoolFromValue(args, "locked", false));
          result->Success();
        } else if (method == "setPassThrough") {
          gal_hook_text_window_->SetPassThrough(
              BoolFromValue(args, "enabled", false));
          result->Success();
        } else if (method == "setFollowing") {
          gal_hook_text_window_->SetPlaybackState(
              BoolFromValue(args, "following", true));
          result->Success();
        } else if (method == "setVoiceState") {
          gal_hook_text_window_->SetVoiceState(
              BoolFromValue(args, "replaying", false),
              BoolFromValue(args, "recapturing", false));
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

// v14 游戏内查词的像素源。懒建：只有用户真开启这个功能才付 WebView2 的启动代价，
// 没开的用户一分钱不花。返回 nullptr 表示这次拿不到（尚未 prepare 过 popup 资源目录）。
GlobalLookupWindow* FlutterWindow::EnsureGalLookupCardWindow() {
  if (gal_lookup_card_window_ != nullptr) return gal_lookup_card_window_.get();
  // 没有资源目录就起不来（WebView2 会导航到空路径，出一张白卡）。宁可这次失败并让
  // 上层回 no_capture_source，也不要起一个注定渲染不出东西的实例——后者的症状是
  // 「卡片出来了但是白的」，比「卡片没出来」难查得多。
  if (popup_assets_dir_.empty()) return nullptr;

  gal_lookup_card_window_ = std::make_unique<GlobalLookupWindow>();
  // 交互式卡片全靠 composition controller 的 SendMouseInput；windowed 实例没有它。
  gal_lookup_card_window_->SetCompositionMode(true);
  gal_lookup_card_window_->SetPopupAssetsDir(popup_assets_dir_);

  // 外字（image://）走与主浮窗同一个 Dart 处理器：卡片内容本来就是同一份 popup.html，
  // 没有理由让它有第二套资源解析语义。
  gal_lookup_card_window_->SetMediaResolver(
      [this](const std::string& url,
             std::function<void(std::vector<uint8_t>)> respond) {
        auto args = std::make_unique<flutter::EncodableValue>(
            flutter::EncodableMap{
                {flutter::EncodableValue("url"), flutter::EncodableValue(url)}});
        auto result = std::make_unique<
            flutter::MethodResultFunctions<flutter::EncodableValue>>(
            [respond](const flutter::EncodableValue* ok) {
              std::vector<uint8_t> bytes;
              if (ok != nullptr) {
                if (const auto* b = std::get_if<std::vector<uint8_t>>(ok)) {
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

  // WebView2 起不来必须能被看见。否则症状是「游戏内查词永远没反应」，而真因在 native
  // 环境创建失败——和「hook 没装上」「host 没投帧」三者同形，真机上分不开。
  gal_lookup_card_window_->SetErrorCallback([this](const std::string& message) {
    global_lookup_channel_->InvokeMethod(
        "nativeError",
        std::make_unique<flutter::EncodableValue>(
            std::string("gal-lookup-card: ") + message));
  });

  // 只离屏预热，从不 ShowAt——这个实例的像素只经共享内存进游戏，永远不作为窗口出现。
  // owner 传 nullptr，与另外两个实例同源解耦，不把主窗拉到前台。
  gal_lookup_card_window_->PrewarmWebView(480, 360, nullptr);
  return gal_lookup_card_window_.get();
}

void FlutterWindow::RegisterGlobalLookupChannel() {
  global_lookup_window_ = std::make_unique<GlobalLookupWindow>();

  global_lookup_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.fushi.reader/global_lookup",
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
        // 同一套查词管线要能驱动**两个**窗口：可见的桌面浮窗，以及游戏内查词专用的
        // 离屏卡片窗（`target: "galCard"`）。
        //
        // 🔴 之前离屏窗只被 EnsureGalLookupCardWindow 建出来并预热，**没有任何一处
        // 往它里面塞过内容**；而 Dart 侧查词走的是可见浮窗。结果就是：桌面弹出浮窗
        // （用户看到的那个），投进游戏的却是那张 480x360 的空白预热页——"游戏内渲染"
        // 从头到尾没有内容。渲染器建好却没接上，是本 PR 的核心接线缺失。
        GlobalLookupWindow* win = global_lookup_window_.get();
        if (StringFromValue(args, "target", "") == "galCard") {
          win = EnsureGalLookupCardWindow();
          if (win == nullptr) {
            result->Error("gal_card_unavailable",
                          "in-game lookup card window is not available");
            return;
          }
        }

        if (method == "prepare") {
          const std::wstring assets_dir = WideFromValue(args, "assetsDir", L"");
          win->SetPopupAssetsDir(assets_dir);
          // v14：游戏内查词卡片用同一份 popup 资源，但它懒建于「用户开启游戏内查词」，
          // 那时 Dart 不会再发一次 prepare。留存一份，别让第三个实例拿着空目录起来。
          popup_assets_dir_ = assets_dir;
          result->Success();
        } else if (method == "prewarmWebView") {
          // TODO-1079 — build the overlay window + WebView2 off-screen at
          // startup so the first hotkey lookup hits a WARM surface (no cold
          // create-chain race that left the popup blank / self-closed).
          // nullptr owner：与 showAt 同源解耦（无 owner，不拉主窗前台）。prewarm
          // 与 showAt 的 owner 必须一致，否则 ForgetDeadWindow 重建时 owner 漂移。
          win->PrewarmWebView(
              IntFromValue(args, "width", 420),
              IntFromValue(args, "height", 600), nullptr);
          result->Success();
        } else if (method == "isWebViewReady") {
          // TODO-1079 — the ready-driven reveal fallback confirms the WebView2
          // finished its initial navigation before revealing (else it defers).
          result->Success(flutter::EncodableValue(
              win->IsWebViewReady()));
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
          const bool ok = win->ShowAt(
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
          win->RenderJson(StringFromValue(args, "json", ""));
          result->Success();
        } else if (method == "resize") {
          win->ResizeTo(IntFromValue(args, "width", 0),
                                          IntFromValue(args, "height", 0));
          result->Success();
        } else if (method == "reveal") {
          // 🔴 游戏内卡片窗**永远不上屏**：reveal 是"把离屏渲染好的窗口挪到屏幕上"
          // 这一步，对它只保留定尺寸。放过去就等于把桌面浮窗换成另一个桌面浮窗，
          // 用户要的恰恰是别弹窗。卡片像素由 CaptureBgraAsync 取走后投进游戏图层。
          if (win == gal_lookup_card_window_.get()) {
            win->ResizeTo(IntFromValue(args, "width", 0),
                          IntFromValue(args, "height", 0));
          } else {
            win->Reveal(IntFromValue(args, "width", 0),
                        IntFromValue(args, "height", 0));
          }
          result->Success();
        } else if (method == "revealStack") {
          // TODO-867 P3c E1 — reveal/resize to the nested-stack union bbox.
          if (win == gal_lookup_card_window_.get()) {
            // 同上：嵌套栈的 reveal 也只定尺寸，不上屏。
            win->ResizeTo(IntFromValue(args, "width", 0),
                          IntFromValue(args, "height", 0));
          } else {
            win->RevealStack(
                IntFromValue(args, "dx", 0), IntFromValue(args, "dy", 0),
                IntFromValue(args, "width", 0), IntFromValue(args, "height", 0),
                DoubleFromValue(args, "left", 0.0),
                DoubleFromValue(args, "top", 0.0));
          }
          result->Success();
        } else if (method == "resolveBridge") {
          // Dart's real reply for a deferred audio handler. "value" is a JSON
          // literal string (jsonEncode'd in Dart): pass it straight through.
          win->ResolveBridge(
              IntFromValue(args, "id", 0),
              StringFromValue(args, "value", "null"));
          result->Success();
        } else if (method == "hide") {
          // TODO-1233 -- notify defaults true (genuine dismiss); the controller
          // passes notify=false for the reset that precedes a fresh lookup so it
          // does not fire overlayHidden between two lookups.
          win->Hide(BoolFromValue(args, "notify", true));
          result->Success();
        } else if (method == "isShowing") {
          result->Success(
              flutter::EncodableValue(win->IsShowing()));
        } else if (method == "setBlockCapture") {
          // 防截屏 — 与剪贴板面板同口径（WDA_EXCLUDEFROMCAPTURE）：瞬态查词窗
          // 对用户可见但不进截图 / 录屏 / 屏幕共享。GlobalLookupWindow 记住该值，
          // 窗口重建后由 ApplyBlockCapture 自动重加（同一 pref
          // clipboardPanelBlockCapture，默认 true）。
          win->SetBlockCapture(
              BoolFromValue(args, "block", true));
          result->Success();
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
  clipboard_panel_window_->SetWindowTitle(L"Fushi");
  clipboard_panel_window_->SetUserDataLeaf(L"ClipboardPanelWebView2");

  clipboard_panel_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "app.fushi.reader/clipboard_panel",
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
          "app.fushi.reader/foreground_selection",
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
          "app.fushi.reader/window_capture",
          &flutter::StandardMethodCodec::GetInstance());

  window_capture_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "listWindows") {
          const std::vector<fushi::ExternalWindow> windows =
              fushi::EnumerateTopLevelWindows(GetHandle());
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
          pending->result = fushi::CaptureWindowPng(target);
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
          "app.fushi.reader/audio_loopback",
          &flutter::StandardMethodCodec::GetInstance());

  audio_loopback_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        auto format_map = [](const fushi::LoopbackFormat& f) {
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
          const fushi::LoopbackFormat f =
              fushi::AudioLoopbackCapture::Instance().Start();
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
          fushi::AudioLoopbackCapture::Instance().Stop();
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
          const fushi::LoopbackFormat f =
              fushi::AudioLoopbackCapture::Instance().GrabRecent(back_ms, pcm);
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
          "app.fushi.reader/voice_hook",
          &flutter::StandardMethodCodec::GetInstance());

  voice_hook_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        auto status_map = [](const fushi::VoiceHookStatus& s) {
          return flutter::EncodableMap{
              {flutter::EncodableValue("ipcProtocolVersion"),
               flutter::EncodableValue(s.ipc_protocol_version)},
              {flutter::EncodableValue("lunaBridgeAbiVersion"),
               flutter::EncodableValue(s.luna_bridge_abi_version)},
              {flutter::EncodableValue("lunaVendoredVersion"),
               flutter::EncodableValue(s.luna_vendored_version)},
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
              {flutter::EncodableValue("audioHooksReady"),
               flutter::EncodableValue(s.audio_hooks_ready)},
              {flutter::EncodableValue("rawVoiceReady"),
               flutter::EncodableValue(s.raw_voice_ready)},
              {flutter::EncodableValue("textLaneRecycles"),
               flutter::EncodableValue(s.text_lane_recycles)},
              {flutter::EncodableValue("textLaneOverflows"),
               flutter::EncodableValue(s.text_lane_overflows)},
              {flutter::EncodableValue("ready"),
               flutter::EncodableValue(s.ok || s.raw_voice_ready)},
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
          const fushi::VoiceHookOpenResult opened =
              fushi::VoiceHookReader::Instance().Open(pid);
          // open 成功但 hook 未就绪**不是错误**（调用方轮询 status）。旧判据
          // `!s.hooked && !s.ok` 把「映射已建、DLL 还没置 hooked 位」这段启动窗口
          // 误报成「共享内存不存在」，Dart 侧据此立刻降级回 loopback——引擎 hook 明明
          // 装得上，只是慢了一拍。真实失败的唯一判据是 Open 自己报的 error。
          if (!opened.ok()) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                // 机器可读 token：Dart 侧据此归类成可执行处置（要管理员 / 重开游戏 /
                // 更新 helper），不再一律说「重启 Fushi」。
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(
                     std::string(fushi::VoiceHookOpenErrorToken(
                         opened.error)))},
                // 一手事实（win32 码 / 映射名 / 双方版本对照），原样进用户可见诊断。
                {flutter::EncodableValue("detail"),
                 flutter::EncodableValue(opened.detail)},
                {flutter::EncodableValue("win32"),
                 flutter::EncodableValue(
                     static_cast<int>(opened.win32_error))}}));
            return;
          }
          result->Success(flutter::EncodableValue(status_map(opened.status)));
          return;
        }
        if (method == "status") {
          result->Success(flutter::EncodableValue(
              status_map(fushi::VoiceHookReader::Instance().Status())));
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
          const fushi::VoiceHookStatus s =
              fushi::VoiceHookReader::Instance().GrabRecent(back_ms, pcm);
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
          std::vector<fushi::VoiceHookText> lines;
          fushi::VoiceHookReader::Instance().PollText(from_seq, lines);
          const uint64_t count =
              fushi::VoiceHookReader::Instance().TextWriteCount();
          flutter::EncodableList list;
          for (const auto& ln : lines) {
            list.push_back(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("seq"),
                 flutter::EncodableValue(static_cast<int64_t>(ln.seq))},
                {flutter::EncodableValue("ts"),
                 flutter::EncodableValue(static_cast<int64_t>(ln.timestamp_ms))},
                {flutter::EncodableValue("text"),
                 flutter::EncodableValue(ln.utf8)},
                {flutter::EncodableValue("threadId"),
                 flutter::EncodableValue(static_cast<int64_t>(ln.thread_id))},
                {flutter::EncodableValue("faceId"),
                 flutter::EncodableValue(static_cast<int64_t>(ln.face_id))},
                {flutter::EncodableValue("threadAddress"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(ln.thread_address))},
                {flutter::EncodableValue("threadContext"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(ln.thread_context))},
                {flutter::EncodableValue("threadContext2"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(ln.thread_context2))},
                {flutter::EncodableValue("processId"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(ln.process_id))},
                {flutter::EncodableValue("sourceKind"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(ln.source_kind))},
                {flutter::EncodableValue("eventKind"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(ln.event_kind))},
                {flutter::EncodableValue("eventFlags"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(ln.event_flags))},
                {flutter::EncodableValue("hookName"),
                 flutter::EncodableValue(ln.hook_name)},
                {flutter::EncodableValue("hookCode"),
                 flutter::EncodableValue(ln.hook_code)},
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
        if (method == "pollThreadPreviews") {
          // v12：每条线程的最近一行（含未被选中的线程），供选择器展示。全量快照，无游标。
          std::vector<fushi::VoiceHookThreadPreview> previews;
          const uint64_t write_count =
              fushi::VoiceHookReader::Instance().PollThreadPreviews(previews);
          flutter::EncodableList list;
          for (const auto& pv : previews) {
            list.push_back(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("threadId"),
                 flutter::EncodableValue(static_cast<int64_t>(pv.thread_id))},
                {flutter::EncodableValue("seq"),
                 flutter::EncodableValue(static_cast<int64_t>(pv.seq))},
                {flutter::EncodableValue("ts"),
                 flutter::EncodableValue(static_cast<int64_t>(pv.timestamp_ms))},
                {flutter::EncodableValue("lineCount"),
                 flutter::EncodableValue(static_cast<int64_t>(pv.line_count))},
                {flutter::EncodableValue("artifactCount"),
                 flutter::EncodableValue(
                     static_cast<int64_t>(pv.artifact_count))},
                {flutter::EncodableValue("eventFlags"),
                 flutter::EncodableValue(static_cast<int64_t>(pv.event_flags))},
                {flutter::EncodableValue("text"),
                 flutter::EncodableValue(pv.utf8)},
            }));
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("writeCount"),
               flutter::EncodableValue(static_cast<int64_t>(write_count))},
              {flutter::EncodableValue("previews"),
               flutter::EncodableValue(std::move(list))},
          }));
          return;
        }
        if (method == "selectTextThread") {
          const uint64_t thread_id =
              static_cast<uint64_t>(read_long("threadId"));
          const bool ok =
              fushi::VoiceHookReader::Instance().SelectTextThread(thread_id);
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("ok"), flutter::EncodableValue(ok)},
          }));
          return;
        }
        if (method == "grabClipNear") {
          // 按句取语音：找时间戳与 tsMs 最近（差 <= tolMs）的语音 clip PCM。
          // 选轨/排除参数与 grabUtterance 同契约：本方法是它的兜底，必须同样遵守。
          const uint64_t ts = static_cast<uint64_t>(read_long("tsMs"));
          uint64_t tol = static_cast<uint64_t>(read_long("tolMs"));
          if (tol == 0) {
            tol = 3000;  // 缺省 ±3s
          }
          const uint64_t target =
              static_cast<uint64_t>(read_long("sourcePtr"));
          std::vector<uint64_t> exclude;
          const auto* cargs =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (cargs != nullptr) {
            const auto ex_it = cargs->find(flutter::EncodableValue("exclude"));
            if (ex_it != cargs->end()) {
              const auto* list =
                  std::get_if<flutter::EncodableList>(&ex_it->second);
              if (list != nullptr) {
                for (const auto& e : *list) {
                  exclude.push_back(
                      static_cast<uint64_t>(e.TryGetLongValue().value_or(0)));
                }
              }
            }
          }
          std::vector<uint8_t> pcm;
          const fushi::VoiceHookStatus s =
              fushi::VoiceHookReader::Instance().GrabClipNear(ts, tol, target,
                                                               exclude, pcm);
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
        if (method == "grabUtterance") {
          // 按句取「整句」语音：拼同源整段（sourcePtr 非 0=手动选轨；缺省能量自动选，可
          // exclude BGM 源）。返回 PCM + 格式，或 {error} 让 Dart 回退 grabClipNear。
          const uint64_t ts = static_cast<uint64_t>(read_long("tsMs"));
          const uint64_t target =
              static_cast<uint64_t>(read_long("sourcePtr"));
          // BUG-1475：可选的前向窗口上界（下一句的时间戳）。缺省 0 = 旧行为。
          const uint64_t end_ts = static_cast<uint64_t>(read_long("endTsMs"));
          std::vector<uint64_t> exclude;
          const auto* uargs =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (uargs != nullptr) {
            const auto exit_it =
                uargs->find(flutter::EncodableValue("exclude"));
            if (exit_it != uargs->end()) {
              const auto* list =
                  std::get_if<flutter::EncodableList>(&exit_it->second);
              if (list != nullptr) {
                for (const auto& e : *list) {
                  exclude.push_back(
                      static_cast<uint64_t>(e.TryGetLongValue().value_or(0)));
                }
              }
            }
          }
          std::vector<uint8_t> pcm;
          const fushi::VoiceHookStatus s =
              fushi::VoiceHookReader::Instance().GrabUtterance(
                  ts, target, exclude, pcm, end_ts);
          if (!s.ok || pcm.empty()) {
            result->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("error"),
                 flutter::EncodableValue(
                     std::string("no utterance near timestamp"))}}));
            return;
          }
          flutter::EncodableMap out = status_map(s);
          out[flutter::EncodableValue("pcm")] =
              flutter::EncodableValue(std::move(pcm));
          result->Success(flutter::EncodableValue(std::move(out)));
          return;
        }
        if (method == "listAudioTracks") {
          // 枚举 ts 附近活跃语音源（供 UI 音轨列表让用户手动选/排除语音源）。
          const uint64_t ts = static_cast<uint64_t>(read_long("tsMs"));
          std::vector<fushi::VoiceTrackInfo> tracks;
          fushi::VoiceHookReader::Instance().ListAudioTracks(ts, tracks);
          flutter::EncodableList list;
          for (const auto& tk : tracks) {
            list.push_back(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("sourcePtr"),
                 flutter::EncodableValue(static_cast<int64_t>(tk.source_ptr))},
                {flutter::EncodableValue("sampleRate"),
                 flutter::EncodableValue(tk.sample_rate)},
                {flutter::EncodableValue("channels"),
                 flutter::EncodableValue(tk.channels)},
                {flutter::EncodableValue("bitsPerSample"),
                 flutter::EncodableValue(tk.bits_per_sample)},
                {flutter::EncodableValue("isFloat"),
                 flutter::EncodableValue(tk.is_float)},
                {flutter::EncodableValue("avgBytes"),
                 flutter::EncodableValue(static_cast<int64_t>(tk.avg_bytes))},
                {flutter::EncodableValue("avgEnergy"),
                 flutter::EncodableValue(tk.avg_energy)},
                {flutter::EncodableValue("orderIndex"),
                 flutter::EncodableValue(tk.order_index)},
                {flutter::EncodableValue("clipCount"),
                 flutter::EncodableValue(tk.clip_count)},
                {flutter::EncodableValue("clipCountAtCue"),
                 flutter::EncodableValue(tk.clip_count_at_cue)},
            }));
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("tracks"),
               flutter::EncodableValue(std::move(list))}}));
          return;
        }
        if (method == "processIsWow64") {
          // 查目标进程位数：fushi.exe 是 64 位，故 IsWow64Process==TRUE 即目标为 32 位
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
          fushi::VoiceHookReader::Instance().Close();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

// Magpie 缩放状态监听（仅 Windows）。Magpie 用 RegisterWindowMessage 注册的广播消息
// "MagpieScalingChanged" 通知全系统顶层窗口缩放状态变化；本 runner 只读不回，收到后
// 经 app.fushi.reader/magpie channel 把事件推给 Dart。
void FlutterWindow::RegisterMagpieChannel() {
  magpie_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "app.fushi.reader/magpie",
          &flutter::StandardMethodCodec::GetInstance());

  // 广播消息号只注册一次：同一字符串在全系统映射到同一个消息号，Magpie 侧
  // RegisterWindowMessage 同名即可对上。
  magpie_scaling_message_ = RegisterWindowMessageW(L"MagpieScalingChanged");
  if (magpie_scaling_message_ == 0) {
    // 注册失败只丢监听能力（Dart 侧收不到事件、按未缩放处理），绝不能让 OnCreate
    // 失败把整个 app 拖挂。
    return;
  }

  // UIPI：Magpie 可能以与本进程不同的完整性级别运行，跨完整性级别的窗口消息默认被
  // 消息过滤器丢弃。对这一条消息显式放行；失败同样忽略（同级别时本来就收得到）。
  const HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ChangeWindowMessageFilterEx(hwnd, magpie_scaling_message_, MSGFLT_ALLOW,
                                nullptr);
  }
}

void FlutterWindow::NotifyMagpieScalingChanged(WPARAM wparam, LPARAM lparam) {
  // WndProc 跑在 platform 线程，InvokeMethod 可直接调用。channel 在 OnCreate 建好
  // 前（极早期消息）可能为空；**退出期**则是引擎先被拆掉、窗口还在收广播消息，此时
  // channel 指针虽非空但底下的 messenger 已随 flutter_controller_ 一起销毁 ——
  // 两个都要判，否则退出期收到一条 Magpie 广播就是 use-after-free。
  if (!flutter_controller_ || !magpie_channel_) {
    return;
  }
  // Magpie 广播语义（state = wParam）：
  //   1                  -> 缩放开始，或源窗口重新回到前台；lParam = 缩放窗口 HWND。
  //   0 且 lParam == 0   -> 缩放窗口 WM_DESTROY，缩放**真正结束**。
  //   0 且 lParam != 0   -> 仅源窗口切到后台，**缩放仍在跑**：必须仍算缩放中，
  //                         否则一切走到后台就被误判成「已退出缩放」。
  //   2 / 3              -> 窗口模式下位置/大小变化 / 用户开始拖动；不改变缩放态，
  //                         原样透传给 Dart。
  const bool scaling = (wparam == 0) ? (lparam != 0) : true;
  flutter::EncodableMap map{
      {flutter::EncodableValue("state"),
       flutter::EncodableValue(static_cast<int>(wparam))},
      {flutter::EncodableValue("handle"),
       flutter::EncodableValue(static_cast<int64_t>(lparam))},
      {flutter::EncodableValue("scaling"), flutter::EncodableValue(scaling)},
  };
  magpie_channel_->InvokeMethod(
      "onScalingChanged",
      std::make_unique<flutter::EncodableValue>(std::move(map)));
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
  // BUG-1239: inspect VK_PROCESSKEY before Flutter handles the message. The
  // engine deliberately reports IME-owned keys as physical=0/logical=0, so
  // checking after HandleTopLevelWindowProc can no longer identify Space.
  // Notify Dart without consuming the Win32 message; Flutter/IME processing
  // continues unchanged.
  if (windows_ime_space_channel_) {
    const ImeSpaceModifierState modifiers{
        GetKeyState(VK_CONTROL) < 0, GetKeyState(VK_SHIFT) < 0,
        GetKeyState(VK_MENU) < 0,    GetKeyState(VK_LWIN) < 0,
        GetKeyState(VK_RWIN) < 0};
    DispatchInitialUnmodifiedImeSpaceDown(
        message, wparam, lparam, modifiers,
        [](void* context) {
          auto* channel = static_cast<
              flutter::MethodChannel<flutter::EncodableValue>*>(context);
          channel->InvokeMethod(
              "onImeSpaceDown",
              std::make_unique<flutter::EncodableValue>());
        },
        windows_ime_space_channel_.get());
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Magpie 缩放状态广播。RegisterWindowMessage 得到的消息号是运行时值，不能写成
  // case 标签，只能在 switch 之前判；magpie_scaling_message_ == 0 表示没注册成功，
  // 此时不做任何匹配。收到后**不消费**（不 return），因为这是系统广播，落到下面的
  // 默认处理，保持既有消息语义不变。
  if (magpie_scaling_message_ != 0 && message == magpie_scaling_message_) {
    NotifyMagpieScalingChanged(wparam, lparam);
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
        flutter::EncodableMap reply;
        if (pending->result.ok && !pending->result.png.empty()) {
          reply[flutter::EncodableValue("pngBytes")] =
              flutter::EncodableValue(pending->result.png);
        } else {
          reply[flutter::EncodableValue("error")] =
              flutter::EncodableValue(pending->result.error.empty()
                                          ? std::string("capture failed")
                                          : pending->result.error);
        }
        // BUG-1096 — 成功路径上的可观测事实（WGC 光标抑制是否真的生效 / 捕获目标是否
        // 被从 Magpie 缩放窗重定向）。空则不带字段，Dart 侧只在非空时记一条日志。
        if (!pending->result.diagnostics.empty()) {
          reply[flutter::EncodableValue("diagnostics")] =
              flutter::EncodableValue(pending->result.diagnostics);
        }
        pending->reply->Success(flutter::EncodableValue(std::move(reply)));
        delete pending;
      }
      return 0;
    }
    case WM_COPYDATA: {
      // TODO-904 P0 回归：第二实例转交「用 Fushi 打开视频」的路径。解出 UTF-8 路径
      // （dwData magic 不匹配则 DecodeExternalVideoPath 返回空串，忽略非本协议消息），
      // 经 app.fushi/external_video channel 推给 Dart 复用 _openExternalVideo。
      // WndProc 跑在 platform 线程，InvokeMethod 可直接调用。
      const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      const std::string video_path = ::fushi::DecodeExternalVideoPath(cds);
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
