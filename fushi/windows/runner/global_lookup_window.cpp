#include "global_lookup_window.h"

#include <dwmapi.h>
#include <shlwapi.h>
#include <wincodec.h>  // WIC：CapturePreview 的 PNG 流 → BGRA8 直通 alpha 位图
#include <windowsx.h>  // GET_X_LPARAM / GET_KEYSTATE_WPARAM（composition 鼠标转发）

#include "low_level_mouse_hook.h"
#include "resource.h"

// v14 游戏内查词的输入 kind 取值真相源。只为下面那组 static_assert 而 include：
// InjectLookupInput 的 [kind] 是跨进程契约的一部分，在这里手抄 0..4 就又造一个漂移源。
#include "../../../native/galgame_hook/include/voice_hook_ipc.h"

#include <cmath>
#include <charconv>
#include <fstream>
#include <memory>
#include <sstream>

#pragma comment(lib, "Shlwapi.lib")

// 防截屏 — SetWindowDisplayAffinity 的 WDA_EXCLUDEFROMCAPTURE 需 Win10 2004+ SDK。
// 老 SDK 头文件里没有这些常量时兜底定义（运行时 Win10<2004 会让 API 返回失败，
// ApplyBlockCapture 再回退 WDA_MONITOR）。SetWindowDisplayAffinity 本体在 user32，
// windows.h 已声明。
#ifndef WDA_NONE
#define WDA_NONE 0x00000000
#endif
#ifndef WDA_MONITOR
#define WDA_MONITOR 0x00000001
#endif
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

using Microsoft::WRL::Callback;
using Microsoft::WRL::Make;

namespace {

constexpr wchar_t kClassName[] = L"FushiGlobalLookupWindow";

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                 static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                 static_cast<int>(value.size()), nullptr, 0,
                                 nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

bool IsJsonWhitespace(char value) {
  return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

size_t SkipJsonWhitespace(const std::string& json, size_t cursor) {
  while (cursor < json.size() && IsJsonWhitespace(json[cursor])) {
    ++cursor;
  }
  return cursor;
}

bool SkipJsonString(const std::string& json, size_t* cursor) {
  if (cursor == nullptr || *cursor >= json.size() || json[*cursor] != '"') {
    return false;
  }
  size_t current = *cursor + 1;
  while (current < json.size()) {
    const char value = json[current++];
    if (value == '"') {
      *cursor = current;
      return true;
    }
    if (value == '\\') {
      if (current >= json.size()) {
        return false;
      }
      const char escaped = json[current++];
      if (escaped == 'u') {
        if (json.size() - current < 4) {
          return false;
        }
        current += 4;
      }
    }
  }
  return false;
}

bool ParseJsonString(const std::string& json, size_t* cursor,
                     std::string* result) {
  if (cursor == nullptr || result == nullptr || *cursor >= json.size() ||
      json[*cursor] != '"') {
    return false;
  }
  result->clear();
  size_t current = *cursor + 1;
  while (current < json.size()) {
    const char value = json[current++];
    if (value == '"') {
      *cursor = current;
      return true;
    }
    if (value != '\\') {
      result->push_back(value);
      continue;
    }
    if (current >= json.size()) {
      return false;
    }
    const char escaped = json[current++];
    switch (escaped) {
      case '"':
      case '\\':
      case '/':
        result->push_back(escaped);
        break;
      case 'b':
        result->push_back('\b');
        break;
      case 'f':
        result->push_back('\f');
        break;
      case 'n':
        result->push_back('\n');
        break;
      case 'r':
        result->push_back('\r');
        break;
      case 't':
        result->push_back('\t');
        break;
      default:
        // Route keys and source values are ASCII literals emitted by our host.
        // Treat any other escape as malformed instead of guessing its value.
        return false;
    }
  }
  return false;
}

bool SkipJsonValue(const std::string& json, size_t* cursor) {
  if (cursor == nullptr) {
    return false;
  }
  size_t current = SkipJsonWhitespace(json, *cursor);
  if (current >= json.size()) {
    return false;
  }
  if (json[current] == '"') {
    if (!SkipJsonString(json, &current)) {
      return false;
    }
    *cursor = current;
    return true;
  }
  if (json[current] == '{' || json[current] == '[') {
    std::vector<char> closings;
    while (current < json.size()) {
      if (json[current] == '"') {
        if (!SkipJsonString(json, &current)) {
          return false;
        }
        continue;
      }
      if (json[current] == '{') {
        closings.push_back('}');
      } else if (json[current] == '[') {
        closings.push_back(']');
      } else if (json[current] == '}' || json[current] == ']') {
        if (closings.empty() || closings.back() != json[current]) {
          return false;
        }
        closings.pop_back();
        if (closings.empty()) {
          *cursor = current + 1;
          return true;
        }
      }
      ++current;
    }
    return false;
  }
  while (current < json.size() && json[current] != ',' &&
         json[current] != '}') {
    ++current;
  }
  *cursor = current;
  return true;
}

bool FindTopLevelJsonValue(const std::string& json, const char* field,
                           size_t* value_cursor) {
  if (field == nullptr || value_cursor == nullptr) {
    return false;
  }
  size_t current = SkipJsonWhitespace(json, 0);
  if (current >= json.size() || json[current] != '{') {
    return false;
  }
  ++current;
  while (current < json.size()) {
    current = SkipJsonWhitespace(json, current);
    if (current < json.size() && json[current] == ',') {
      current = SkipJsonWhitespace(json, current + 1);
    }
    if (current >= json.size() || json[current] == '}') {
      return false;
    }
    std::string key;
    if (!ParseJsonString(json, &current, &key)) {
      return false;
    }
    current = SkipJsonWhitespace(json, current);
    if (current >= json.size() || json[current] != ':') {
      return false;
    }
    current = SkipJsonWhitespace(json, current + 1);
    if (key == field) {
      *value_cursor = current;
      return true;
    }
    if (!SkipJsonValue(json, &current)) {
      return false;
    }
  }
  return false;
}

bool ReadTopLevelJsonString(const std::string& json, const char* field,
                            std::string* value) {
  size_t cursor = 0;
  return FindTopLevelJsonValue(json, field, &cursor) &&
         ParseJsonString(json, &cursor, value);
}

bool ReadTopLevelJsonInt64(const std::string& json, const char* field,
                           int64_t* value) {
  if (value == nullptr) {
    return false;
  }
  size_t cursor = 0;
  if (!FindTopLevelJsonValue(json, field, &cursor)) {
    return false;
  }
  const char* begin = json.data() + cursor;
  const char* end = json.data() + json.size();
  int64_t parsed = 0;
  const auto converted = std::from_chars(begin, end, parsed);
  if (converted.ec != std::errc() || converted.ptr == begin) {
    return false;
  }
  const size_t next = SkipJsonWhitespace(
      json, static_cast<size_t>(converted.ptr - json.data()));
  if (next < json.size() && json[next] != ',' && json[next] != '}') {
    return false;
  }
  *value = parsed;
  return true;
}

// Picks the HTTP Content-Type header for a resolved custom-scheme resource,
// mirroring the in-app dictionary_webview_media.dart logic so the app-external
// overlay serves the SAME content-type the in-app InAppWebView does:
//   - dictmedia:// (dictionary <link> stylesheets) -> text/css (matches the
//     in-app dictmedia branch which hardcodes text/css).
//   - image:// and everything else -> by file extension (png/jpg/gif/webp/svg),
//     defaulting to application/octet-stream.
// The page only references dictmedia:// for the dictionary's own <link>
// stylesheets, so text/css is the faithful type; image:// covers gaiji/<img>.
std::wstring MediaContentTypeHeader(const std::string& url) {
  const bool is_dictmedia = url.rfind("dictmedia://", 0) == 0;
  if (is_dictmedia) {
    return L"Content-Type: text/css";
  }
  // Extension is taken from the part before any '?' query.
  std::string path = url;
  size_t q = path.find('?');
  if (q != std::string::npos) {
    path = path.substr(0, q);
  }
  size_t dot = path.find_last_of('.');
  std::string ext;
  if (dot != std::string::npos) {
    ext = path.substr(dot + 1);
    for (char& c : ext) {
      c = static_cast<char>(::tolower(static_cast<unsigned char>(c)));
    }
  }
  if (ext == "png") return L"Content-Type: image/png";
  if (ext == "jpg" || ext == "jpeg") return L"Content-Type: image/jpeg";
  if (ext == "gif") return L"Content-Type: image/gif";
  if (ext == "webp") return L"Content-Type: image/webp";
  if (ext == "svg") return L"Content-Type: image/svg+xml";
  return L"Content-Type: application/octet-stream";
}

// TODO-1153 -- native diagnostic logger for the overlay bring-up. The runner is
// a WIN32 GUI exe with no console, so a failed WebView2 environment/controller
// create otherwise vanishes. Appends timestamped lines to the SAME file the Dart
// side uses (glog -> <systemTemp>/hibiki_glookup.log) so both halves of the
// trigger correlate in one log. Best-effort: never throws, never blocks.
void NativeGlog(const std::string& message) {
  wchar_t temp_dir[MAX_PATH];
  DWORD n = GetTempPathW(MAX_PATH, temp_dir);
  if (n == 0 || n >= MAX_PATH) {
    return;
  }
  std::wstring path(temp_dir, n);
  path += L"hibiki_glookup.log";
  std::ofstream out(path, std::ios::app | std::ios::binary);
  if (!out) {
    return;
  }
  SYSTEMTIME st;
  GetLocalTime(&st);
  char stamp[32];
  _snprintf_s(stamp, sizeof(stamp), _TRUNCATE, "%04d-%02d-%02dT%02d:%02d:%02d",
              st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
  out << stamp << "  [native] " << message << "\n";
}

// TODO-1153 -- dedicated WebView2 user data folder for the app-external overlay.
//
// Root cause: the overlay's environment registers the image:// + dictmedia://
// custom schemes (SetCustomSchemeRegistrations below), but was created against
// the process DEFAULT user data folder (userDataFolder == nullptr) -- the SAME
// folder the in-app fork WebView2 environments use. WebView2 forbids two
// environments sharing one user data folder with DIFFERENT CreateOptions and
// fails the second create with 0x8007139F (ERROR_INVALID_STATE). That failure
// was swallowed (the completion callback never fired, the synchronous HRESULT
// was discarded), so the overlay never navigated, webview_ready_ stayed false,
// and the reveal showed a blank transparent window ("no popup").
//
// Giving the overlay its OWN folder makes it an INDEPENDENT WebView2 profile
// scope whose options never have to match any other environment. The folder is
// under %LOCALAPPDATA% (writable per-user) and distinct from the fork's default
// folder, so there is no collision regardless of what schemes the in-app
// environments register. Falls back to %TEMP% then to empty (default) as a last
// resort; empty only re-risks the conflict, which the added error logging then
// surfaces instead of swallowing.
// spec 2026-07-10 — |leaf| is the per-instance profile directory name (lookup
// overlay: GlobalLookupWebView2; clipboard panel: ClipboardPanelWebView2).
// Separate folders keep the two instances' environment options independent
// (same-folder different-options fails the second create with 0x8007139F).
std::wstring OverlayUserDataFolder(const std::wstring& leaf) {
  wchar_t buf[MAX_PATH];
  DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
  std::wstring base;
  if (n > 0 && n < MAX_PATH) {
    base.assign(buf, n);
  } else {
    DWORD t = GetEnvironmentVariableW(L"TEMP", buf, MAX_PATH);
    if (t > 0 && t < MAX_PATH) {
      base.assign(buf, t);
    }
  }
  if (base.empty()) {
    return std::wstring();
  }
  return base + L"\\Fushi\\" + leaf;
}

// v14 游戏内查词 — 把 CapturePreview 吐出的 PNG 流解成契约规定的
// **BGRA8 / 直通（非预乘）alpha / 自顶向下**（voice_hook_ipc.h 的 v14 查词区注释）。
//
// 🔴 必须是 `GUID_WICPixelFormat32bppBGRA` 而**不是** `…32bppPBGRA`：后者是预乘。
// 两端都用直通是有原因的——PNG 解码出来的本来就是直通（不转换就是零成本），注入侧
// KiriKiri 的 `ltAlpha` 也正是直通合成模式（预乘对应的是 `ltAddAlpha`）。写成预乘不会
// 报任何错，只会让卡片的半透明边缘（圆角、阴影、文字抗锯齿）整体发暗，症状是"看起来
// 有点脏"，在真机上极难归因到像素格式。
//
// pitch 恒为 width*4（正数）、行序自顶向下：这块共享内存是我们自己的，不继承任何一侧
// 的行序怪癖（游戏 Layer 的 pitch 可能为负，那是注入侧搬运时的事）。
//
// [max_width]/[max_height] 是硬裁剪上界（不是缩放）：超出就按左上角切，并置 [clamped]。
// 缩放会让卡片文字糊掉，而卡片的价值就是"与 Hibiki 自身像素一致"——宁可切也不缩。
// 全程 HRESULT 校验、零异常（runner 以 _HAS_EXCEPTIONS=0 编译）。
bool DecodePngStreamToStraightBgra(IStream* stream, uint32_t max_width,
                            uint32_t max_height, std::vector<uint8_t>* out,
                            uint32_t* out_width, uint32_t* out_height,
                            uint32_t* out_pitch, bool* out_clamped) {
  if (stream == nullptr || out == nullptr || out_width == nullptr ||
      out_height == nullptr || out_pitch == nullptr || out_clamped == nullptr) {
    return false;
  }
  out->clear();
  *out_width = 0;
  *out_height = 0;
  *out_pitch = 0;
  *out_clamped = false;
  if (max_width == 0 || max_height == 0) {
    return false;
  }
  LARGE_INTEGER origin;
  origin.QuadPart = 0;
  HRESULT hr = stream->Seek(origin, STREAM_SEEK_SET, nullptr);
  if (FAILED(hr)) {
    return false;
  }
  wil::com_ptr<IWICImagingFactory> factory;
  hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                        IID_PPV_ARGS(&factory));
  if (FAILED(hr) || factory == nullptr) {
    return false;
  }
  wil::com_ptr<IWICBitmapDecoder> decoder;
  hr = factory->CreateDecoderFromStream(stream, nullptr,
                                        WICDecodeMetadataCacheOnDemand,
                                        &decoder);
  if (FAILED(hr) || decoder == nullptr) {
    return false;
  }
  wil::com_ptr<IWICBitmapFrameDecode> frame;
  hr = decoder->GetFrame(0, &frame);
  if (FAILED(hr) || frame == nullptr) {
    return false;
  }
  UINT src_w = 0;
  UINT src_h = 0;
  hr = frame->GetSize(&src_w, &src_h);
  if (FAILED(hr) || src_w == 0 || src_h == 0) {
    return false;
  }
  UINT width = src_w;
  UINT height = src_h;
  if (width > max_width) {
    width = static_cast<UINT>(max_width);
    *out_clamped = true;
  }
  if (height > max_height) {
    height = static_cast<UINT>(max_height);
    *out_clamped = true;
  }
  wil::com_ptr<IWICBitmapSource> converted;
  // 直通 alpha（见函数头注释）。改成 32bppPBGRA 会静默地把卡片边缘弄暗。
  hr = WICConvertBitmapSource(GUID_WICPixelFormat32bppBGRA, frame.get(),
                              &converted);
  if (FAILED(hr) || converted == nullptr) {
    return false;
  }
  const uint64_t pitch = static_cast<uint64_t>(width) * 4u;
  const uint64_t needed = pitch * height;
  // 上界纯防御：调用方给的 max_* 已经把它压到 3MiB 量级，这里只挡住溢出/畸形帧。
  if (needed == 0 || needed > 0x20000000ull) {  // 512MiB 硬顶
    return false;
  }
  out->resize(static_cast<size_t>(needed));
  WICRect rect;
  rect.X = 0;
  rect.Y = 0;
  rect.Width = static_cast<INT>(width);
  rect.Height = static_cast<INT>(height);
  hr = converted->CopyPixels(&rect, static_cast<UINT>(pitch),
                             static_cast<UINT>(needed), out->data());
  if (FAILED(hr)) {
    out->clear();
    return false;
  }
  *out_width = static_cast<uint32_t>(width);
  *out_height = static_cast<uint32_t>(height);
  *out_pitch = static_cast<uint32_t>(pitch);
  return true;
}

}  // namespace

GlobalLookupWindow* GlobalLookupWindow::s_hook_owner_ = nullptr;

void CALLBACK GlobalLookupWindow::ForegroundHookProc(HWINEVENTHOOK, DWORD,
                                                     HWND hwnd, LONG, LONG,
                                                     DWORD, DWORD) {
  GlobalLookupWindow* self = s_hook_owner_;
  // The user activated another window (click outside the card). Own-process
  // events are skipped via WINEVENT_SKIPOWNPROCESS, so this never fires for our
  // own overlay/main window.
  if (self != nullptr && self->IsShowing() && hwnd != self->hwnd_) {
    self->Hide();
  }
}

void GlobalLookupWindow::HandleGlobalClick(POINT screen_pt,
                                           bool inside_window) {
  if (!IsShowing()) return;
  // TODO-867 P3c C4/E2 — the window is now the whole nested-stack bounding
  // box (E1): the transparent area BETWEEN cards is inside the HWND rect, so
  // a coarse "PtInRect -> Hide" would wrongly close on a click in that gap.
  // Split the decision: a click OUTSIDE the whole window rect dismisses the
  // overlay (clicked another app); a click INSIDE the window is forwarded to
  // the web host, which owns the per-shell geometry truth and decides whether
  // to keep (hit a card) or dismiss the root (gap between cards). C++ only
  // feeds coordinates; the host hit-tests (no shell geometry duplicated here).
  if (!inside_window) {
    Hide();  // Click outside the whole stack window -> dismiss.
  } else {
    ForwardGlobalClickToHost(screen_pt.x, screen_pt.y);
  }
}

// BUG-1166 — 钩子吞下来的滚轮，在窗口线程还原成一条真滚轮消息交给 WebView2。
//
// 为什么不能把它 PostMessage 回 hwnd_ 了事：windowed 模式下 WebView2 的输入落在
// **子 HWND** 上，本窗的 WndProc 对 WM_MOUSEWHEEL 只会走 DefWindowProc（顶层窗
// 的 DefWindowProc 不往下传），卡片一样滚不动。所以按模式各走各的既有输入路。
void GlobalLookupWindow::HandleGlobalWheel(POINT screen_pt,
                                           const fushi::MouseHookWheel& wheel) {
  if (!IsShowing() || hwnd_ == nullptr || wheel.delta == 0) return;
  const UINT message = wheel.horizontal ? WM_MOUSEHWHEEL : WM_MOUSEWHEEL;
  // 与真滚轮消息同构：wparam 高字 = delta / 低字 = MK_* 修饰键；
  // lparam = **屏幕**坐标（WM_MOUSEWHEEL 的契约，ForwardCompositionMouse 也按此
  // 做 ScreenToClient）。
  const WPARAM wparam = MAKEWPARAM(static_cast<WORD>(wheel.keys),
                                   static_cast<WORD>(wheel.delta));
  const LPARAM lparam = MAKELPARAM(static_cast<WORD>(screen_pt.x),
                                   static_cast<WORD>(screen_pt.y));
  // ── 分流点（复审推翻原始假设后的根因修复）──────────────────────────────
  // 带 Ctrl / Alt 的滚轮**不能**走下面任何一条「合成 WM_MOUSEWHEEL」的路：
  // WebView2/Chromium 取修饰键读的是 GetKeyState 而非 wparam 的 MK_ 位，而合成消息
  // 不更新键状态表（详见 low_level_mouse_hook.h 的 MouseHookWheel 注释）。结果就是
  // e.ctrlKey / e.altKey 恒 false —— PR#462（BUG-1139）刚修好的 Ctrl+滚轮缩放会
  // 静默退化成普通滚动，Alt+滚轮换词条（弹窗 WheelBinding）更是结构上带不过去。
  //
  // 所以把修饰键当**数据**显式送进 web 层，由已有的 JS 监听按用户绑定自行判定：
  //   Ctrl → _globalLookupZoomWheelJs → callHandler('popupZoomFontStep')
  //          → jsMessage → Dart maybeHandleOverlayZoomFontStep（PR#462 原链路整条复用）
  //   Alt  → popup.js popupEntryWheelAction（绑定真值 __fushiEntryWheelBindings 在 JS，
  //          用户可改键位，C++ 不得复制这份语义 —— 这里只做传输，不做策略）
  // 裸滚轮 / 仅 Shift 不绕道：那条原生路本来就是对的，绕道反而丢掉浏览器自己的
  // 平滑滚动与 Shift→deltaX 横滚转换。
  if (wheel.ctrl || wheel.alt) {
    ForwardGlobalWheelToHost(screen_pt, wheel);
    return;
  }
  if (composition_active_) {
    ForwardCompositionMouse(message, wparam, lparam);
    return;
  }
  // windowed：投给光标真正压着的那个窗（= 没被吞时系统本来会投的那个）。
  // WindowFromPoint 认不出来（跨进程子窗层级异常）就退回第一个子窗，仍认不出
  // 就投给本窗——最坏情况是这一格滚轮被丢掉，但游戏依旧收不到，不会回退成穿透。
  HWND hit = WindowFromPoint(screen_pt);
  if (hit == nullptr || (hit != hwnd_ && !IsChild(hwnd_, hit))) {
    hit = GetWindow(hwnd_, GW_CHILD);
  }
  if (hit == nullptr) hit = hwnd_;
  PostMessage(hit, message, wparam, lparam);
}

// BUG-1166 — 带修饰键的滚轮：把「坐标 + 方向 + 修饰键」作为**数据**交给 host JS，
// 由 host 派发一条带显式 ctrlKey/altKey/shiftKey 的 WheelEvent 到命中的那张卡片。
//
// 与 ForwardGlobalClickToHost 同一条既有边界约定（屏幕物理 px → 窗口内 CSS px），
// 复用同一套 dpr 换算：host 侧的几何真值全程是 CSS px。
void GlobalLookupWindow::ForwardGlobalWheelToHost(
    POINT screen_pt, const fushi::MouseHookWheel& wheel) {
  if (webview_ == nullptr || hwnd_ == nullptr || wheel.delta == 0) {
    return;
  }
  RECT rc;
  GetWindowRect(hwnd_, &rc);
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi == 0) {
    dpi = 96;
  }
  const double dpr = static_cast<double>(dpi) / 96.0;
  const double local_x = static_cast<double>(screen_pt.x - rc.left) / dpr;
  const double local_y = static_cast<double>(screen_pt.y - rc.top) / dpr;
  // Win32 delta 与 DOM delta **方向相反**：WM_MOUSEWHEEL 正值 = 向前/向上滚，
  // 而 DOM 的 WheelEvent.deltaY 向上滚是负值。在这里一次转成 DOM 约定，
  // 让 JS 侧（popupEntryWheelAction 的 deltaY 符号、缩放的 deltaY<0 = 放大）
  // 与真滚轮完全同构，JS 不需要知道自己收的是合成事件。
  const double dom_delta_y = -static_cast<double>(wheel.delta);
  std::wstring script =
      L"window.__globalLookupHost && "
      L"window.__globalLookupHost.handleGlobalWheel(" +
      std::to_wstring(local_x) + L", " + std::to_wstring(local_y) + L", " +
      std::to_wstring(dom_delta_y) + L", " +
      std::wstring(wheel.ctrl ? L"true" : L"false") + L", " +
      std::wstring(wheel.alt ? L"true" : L"false") + L", " +
      std::wstring((wheel.keys & MK_SHIFT) != 0 ? L"true" : L"false") + L");";
  webview_->ExecuteScript(script.c_str(), nullptr);
}

GlobalLookupWindow::GlobalLookupWindow() = default;

void GlobalLookupWindow::SetRouteContext(std::string source,
                                         int64_t route_epoch,
                                         int64_t lookup_epoch) {
  if (source != "desktop" && source != "galCard") {
    source = "desktop";
  }
  if (route_epoch < 0) {
    route_epoch = 0;
  }
  if (lookup_epoch < 0) {
    lookup_epoch = 0;
  }

  if (route_context_bound_) {
    if (route_epoch < route_context_.route_epoch ||
        (route_epoch == route_context_.route_epoch &&
         lookup_epoch < route_context_.lookup_epoch)) {
      return;
    }
    // A physical window has exactly one route source. Equal epochs are repeated
    // commands for that same route, never authority to relabel the window.
    if (route_epoch == route_context_.route_epoch &&
        lookup_epoch == route_context_.lookup_epoch &&
        source != route_context_.source) {
      return;
    }
  }

  route_context_ = {std::move(source), route_epoch, lookup_epoch};
  route_context_bound_ = true;
}

GlobalLookupWindow::RouteContext GlobalLookupWindow::RouteForMessage(
    const std::string& json) const {
  RouteContext route = route_context_;
  std::string source;
  if (ReadTopLevelJsonString(json, "__source", &source) &&
      (source == "desktop" || source == "galCard")) {
    route.source = std::move(source);
  }
  int64_t epoch = 0;
  if (ReadTopLevelJsonInt64(json, "__routeEpoch", &epoch) && epoch >= 0) {
    route.route_epoch = epoch;
  }
  if (ReadTopLevelJsonInt64(json, "__lookupEpoch", &epoch) && epoch >= 0) {
    route.lookup_epoch = epoch;
  }
  return route;
}

GlobalLookupWindow::~GlobalLookupWindow() {
  ReleaseDismissHooks();
  if (controller_) {
    controller_->Close();
  }
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  // spec 2026-07-10 — the window class is PROCESS-scoped and shared by both
  // instances (lookup overlay + clipboard panel), so no instance may
  // UnregisterClassW it: destroying one window would rip the class out from
  // under the other. The class stays registered for the process lifetime
  // (registered once in EnsureWindowClass; the OS reclaims it at exit).
}

void GlobalLookupWindow::EnsureWindowClass() {
  // Process-level once-guard: two instances share one class registration. The
  // old per-instance bool re-ran RegisterClassExW (harmless but dirty) and let
  // either destructor unregister the class the OTHER live window still used.
  static bool s_class_registered = false;
  if (s_class_registered) {
    return;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = GlobalLookupWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  // 面板任务栏图标 — 类图标供任务栏按钮 / Alt-Tab 使用（瞬态覆盖窗是
  // TOOLWINDOW 不上任务栏，带图标无副作用）。
  wc.hIcon = LoadIcon(wc.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
  wc.hIconSm = wc.hIcon;
  wc.lpszClassName = kClassName;
  RegisterClassExW(&wc);
  s_class_registered = true;
}

int GlobalLookupWindow::OffscreenX() const {
  // Just past the right edge of the whole virtual desktop: the window is shown
  // (so WebView2 renders + the page can self-measure) but invisible to the
  // user. Avoids the flicker of sizing a *visible* window through the
  // measure->resize convergence. Reveal() moves it to the cursor once stable.
  return GetSystemMetrics(SM_XVIRTUALSCREEN) +
         GetSystemMetrics(SM_CXVIRTUALSCREEN) + 200;
}

bool GlobalLookupWindow::OwnsLiveWindow() const {
  if (hwnd_ == nullptr || !IsWindow(hwnd_)) {
    return false;
  }
  // IsWindow() alone is not enough: Windows recycles HWND values, so a stale
  // hwnd_ could name a DIFFERENT live window. Confirm the handle still points
  // back at us via the GWLP_USERDATA we stamped in WM_NCCREATE.
  return reinterpret_cast<GlobalLookupWindow*>(
             GetWindowLongPtr(hwnd_, GWLP_USERDATA)) == this;
}

void GlobalLookupWindow::ReleaseDismissHooks() {
  if (foreground_hook_ != nullptr) {
    UnhookWinEvent(foreground_hook_);
    foreground_hook_ = nullptr;
  }
  if (mouse_hook_armed_) {
    fushi::DisarmLowLevelMouseHook();
    mouse_hook_armed_ = false;
  }
  // spec 2026-07-10 — only clear the hook owner if it is OURS: the persistent
  // clipboard panel never arms the hooks, and its Hide() must not disarm the
  // transient lookup overlay's live click-outside callbacks.
  if (s_hook_owner_ == this) {
    s_hook_owner_ = nullptr;
  }
}

void GlobalLookupWindow::ForgetDeadWindow() {
  if (hwnd_ == nullptr || OwnsLiveWindow()) {
    return;
  }
  // BUG-1471: the hooks were armed against this now-dead HWND. Releasing them
  // here is what keeps arm/disarm balanced across the crash path — otherwise
  // the mouse hook's liveness timer re-arms a dead pass-through hook forever.
  ReleaseDismissHooks();
  // HWND 已死，定时器随它一起没了；清掉 id 免得下次 Start 以为还开着（BUG-1479）。
  topmost_guard_timer_ = 0;
  // The HWND was destroyed out from under us (WebView2 runtime crash/update,
  // owner teardown, or any external DestroyWindow) yet hwnd_ stayed non-null,
  // so every later ShowAt took the SetWindowPos(else) branch against a corpse
  // and the app-external lookup/panel window "never came back without an app
  // restart". Drop the dangling handle + the now-dead WebView2 proxies (the
  // same release RecoverDeadWebView does) so the next ShowAt/PrewarmWebView
  // rebuilds a fresh window from scratch. Surface it so the destroyer is
  // diagnosable in the device log instead of a silent no-show.
  if (error_cb_) {
    error_cb_(
        "overlay window found destroyed (external teardown) — rebuilding on "
        "this lookup");
  }
  hwnd_ = nullptr;
  controller_ = nullptr;
  webview_ = nullptr;
  env_ = nullptr;
  // 背景逐像素透明：DComp target/visual + composition controller 绑在这个已死的
  // HWND 上，必须一并释放，下次重建从头再建（d3d/dcomp 设备无 HWND 绑定，保留复用）。
  composition_controller_ = nullptr;
  dcomp_target_ = nullptr;
  dcomp_visual_ = nullptr;
  webview_ready_ = false;
  recovering_ = false;
  visible_ = false;
  revealed_ = false;
  offscreen_active_ = false;
  shell_rects_css_.clear();  // BUG-749 — stale rects must not clip a rebuild.
}

bool GlobalLookupWindow::ShowAt(int x, int y, int width, int height,
                                HWND owner) {
  EnsureWindowClass();
  // A previously-created window may have been destroyed out from under us; drop
  // the dangling handle so the guard below rebuilds instead of SetWindowPos-ing
  // a corpse (root cause of "second lookup / reopen shows nothing").
  ForgetDeadWindow();
  // Remember where the card should ultimately appear; Reveal() uses it.
  pending_x_ = x;
  pending_y_ = y;
  revealed_ = false;
  // Render OFF-SCREEN at the requested size. The page measures itself there and
  // Dart calls Reveal() with the final size, so the user only ever sees the
  // settled card (no width/height jitter on screen).
  const int off_x = OffscreenX();
  if (hwnd_ == nullptr) {
    // No WS_EX_LAYERED: WebView2 brings its own composition surface and does not
    // coexist with a layered window. WS_EX_NOACTIVATE keeps the foreground app's
    // keyboard focus intact when the card appears (design §5 guarantee 3).
    // 真机第 4 轮 — 面板实例（activatable_）不带 NOACTIVATE：点击面板时焦点
    // 落面板，滚轮不再穿到底下仍持焦点的游戏。程序化路径全程 SWP_NOACTIVATE /
    // SW_SHOWNOACTIVATE，流式更新不抢焦点。
    // 面板任务栏图标 — taskbar_presence_（面板实例）用 APPWINDOW 换掉
    // TOOLWINDOW：任务栏出现独立按钮，点它即可把被压底的面板拉回前台。
    // 背景逐像素透明 — composition 模式下 OverlayCreateExStyle 带
    // WS_EX_NOREDIRECTIONBITMAP（透明像素经 DComp 上桌面）。
    hwnd_ = CreateWindowExW(
        OverlayCreateExStyle(), kClassName, window_title_.c_str(), WS_POPUP,
        off_x, 0, width, height, owner, nullptr, GetModuleHandle(nullptr),
        this);
    if (hwnd_ == nullptr) {
      return false;
    }
    // 防截屏 — 新窗口一建立就按最后一次 SetBlockCapture 的值置 display affinity，
    // 故 ForgetDeadWindow / 崩溃恢复重建后仍然生效（默认 false = 不影响）。
    ApplyBlockCapture();
    EnsureWebView();
  } else {
    SetWindowPos(hwnd_, HWND_TOPMOST, off_x, 0, width, height, SWP_NOACTIVATE);
  }
  // Shown (so WebView2 lays out + renders) but parked off-screen and NOT yet
  // "visible_" — the click-outside hooks stay disarmed until Reveal().
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  visible_ = false;
  offscreen_active_ = false;
  return true;
}

void GlobalLookupWindow::PrewarmWebView(int width, int height, HWND owner) {
  // TODO-1079 — root-cause fix for the app-external lookup popup "sometimes does
  // not appear". The overlay's WebView2 used to be created LAZILY on the first
  // ShowAt (EnsureWebView), so the very first hotkey raced a cold create chain
  // (CreateCoreWebView2Environment -> controller -> Navigate host.html -> load
  // the popup.html child iframes), commonly >450ms, while the Dart 450ms safety
  // reveal / host overlaySize fired against a not-yet-ready surface -> "window
  // present but blank" or the foreground hook self-closed it. Prewarming builds
  // the window + WebView2 ONCE off-screen at startup and navigates to host.html,
  // so webview_ready_ is set before the user ever presses the hotkey and the hot
  // path only renders + reveals. Semantics mirror the in-app keepWebViewWarm hot
  // slot, but for THIS bare overlay window (webview_prewarm.dart only warms the
  // in-app HeadlessInAppWebView, never this window — that gap was the root cause).
  ForgetDeadWindow();  // A stale prewarm handle that died must be rebuilt.
  if (hwnd_ != nullptr) {
    return;  // Already warm (window + WebView2 exist) — idempotent.
  }
  EnsureWindowClass();
  const int off_x = OffscreenX();
  const int w = width > 0 ? width : 420;
  const int h = height > 0 ? height : 600;
  // 背景逐像素透明 — composition 模式带 WS_EX_NOREDIRECTIONBITMAP（见 ShowAt）。
  hwnd_ = CreateWindowExW(
      OverlayCreateExStyle(), kClassName, window_title_.c_str(), WS_POPUP, off_x,
      0, w, h, owner, nullptr, GetModuleHandle(nullptr), this);
  if (hwnd_ == nullptr) {
    return;
  }
  // 防截屏 — 预热窗同样一建立就套用（见 ShowAt 同名调用）。
  ApplyBlockCapture();
  EnsureWebView();
  // Show off-screen (so WebView2 lays out + navigates and NavigationCompleted
  // fires -> webview_ready_) but keep visible_ false: the click-outside hooks
  // stay disarmed and the user sees nothing until a real lookup reveals it.
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  visible_ = false;
  revealed_ = false;
  offscreen_active_ = false;
}

void GlobalLookupWindow::Reveal(int width, int height) {
  if (hwnd_ == nullptr) {
    return;
  }
  if (width <= 0 || height <= 0) {
    RECT rc;
    GetWindowRect(hwnd_, &rc);
    width = rc.right - rc.left;
    height = rc.bottom - rc.top;
  }
  int x = pending_x_;
  int y = pending_y_;
  // Clamp the final card to the cursor monitor's work area (same math as
  // ResizeTo) so a tall/edge-anchored card stays fully on-screen.
  POINT cursor = {pending_x_, pending_y_};
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(monitor, &mi)) {
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int work_h = mi.rcWork.bottom - mi.rcWork.top;
    width = width < work_w ? width : work_w;
    height = height < work_h ? height : work_h;
    if (x + width > mi.rcWork.right) x = mi.rcWork.right - width;
    if (y + height > mi.rcWork.bottom) y = mi.rcWork.bottom - height;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  revealed_ = true;
  visible_ = true;
  offscreen_active_ = false;
  // BUG-1689 — 把**本线程的活动窗口**换成这个可激活的浮窗（不改前台、不抢焦点）。
  //
  // 根因：用户点一个「所属进程不在前台」的可激活窗口时，Windows 的前台切换会先把该
  // 线程的活动窗口前台化、抬到 Z 序上层，然后才把激活交给真正被点的那个窗口。runner
  // 主窗一直是本线程的活动窗口，于是「在游戏/浏览器里点一下剪贴板查词面板」＝「主界面
  // 浮到用户正在用的窗口上面」（用户 2026-08-16 报，且只有主窗非最小化时看得见）。
  // 抬升发生在系统内部，进程里没有任何一行代码调用它，事后再 SetWindowPos 推回去也
  // 追不上（真机实测：系统给的插入位置与原前驱相同，推回等于没动）。
  //
  // SetActiveWindow 只改**本线程**的活动窗口；本进程不是前台进程时它不改变前台、不动
  // Z 序、不抢键盘焦点（面板照旧 SW_SHOWNOACTIVATE 上屏）。活动窗口换成面板后，那一步
  // 顺带抬升的对象就是面板自己——它本来就要显示在最上，于是主窗彻底不再被牵动。
  // 只对可激活实例做：瞬态卡 / gal 卡窗带 WS_EX_NOACTIVATE，本就不参与激活。
  if (activatable_) {
    SetActiveWindow(hwnd_);
  }
  // BUG-1479：只设一次不够——同置顶带里「最后一次 SetWindowPos 的赢」，
  // 而大量 galgame 会周期性重申自己的置顶。
  StartTopmostGuard();
  // Arm the click-outside dismiss only now that the card is on-screen (skip our
  // own process so interacting with the card / main window does not close it).
  // spec 2026-07-10 — the clipboard panel instance is PERSISTENT (click-outside
  // / foreground-switch must not close it): it never arms these hooks and thus
  // never touches the singleton s_hook_owner_, which stays owned by the
  // transient lookup overlay.
  if (arm_dismiss_hooks_) {
    s_hook_owner_ = this;
    if (foreground_hook_ == nullptr) {
      foreground_hook_ = SetWinEventHook(
          EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
          &GlobalLookupWindow::ForegroundHookProc, 0, 0,
          WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    // BUG-1048 — 钩子跑在专用线程上（见 low_level_mouse_hook.h）：装在 platform 线程
    // 时，全系统每个鼠标事件都要排在 Flutter 的帧后面，游戏里鼠标一动就卡。
    fushi::ArmLowLevelMouseHook(hwnd_);
    mouse_hook_armed_ = true;
  }
}

void GlobalLookupWindow::RevealStack(int dx, int dy, int width, int height,
                                     double bbox_left, double bbox_top) {
  if (hwnd_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  // The window moves to (cursor + dx, cursor + dy) and grows to the bbox size.
  // The host (global_lookup_host.js) shifted its layer by (-bbox.left, -bbox.top)
  // so the ROOT card stays pinned at the cursor while the whole cascade fits in
  // the window. Clamp to the cursor monitor work area like Reveal/ResizeTo.
  int x = pending_x_ + dx;
  int y = pending_y_ + dy;
  const int intended_x = x;
  const int intended_y = y;
  POINT cursor = {pending_x_, pending_y_};
  HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(monitor, &mi)) {
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int work_h = mi.rcWork.bottom - mi.rcWork.top;
    width = width < work_w ? width : work_w;
    height = height < work_h ? height : work_h;
    if (x + width > mi.rcWork.right) x = mi.rcWork.right - width;
    if (y + height > mi.rcWork.bottom) y = mi.rcWork.bottom - height;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  revealed_ = true;
  visible_ = true;
  offscreen_active_ = false;
  // BUG-1479：只设一次不够——同置顶带里「最后一次 SetWindowPos 的赢」，
  // 而大量 galgame 会周期性重申自己的置顶。
  StartTopmostGuard();
  // TODO-1231 P2 — now that the window sits at the new bbox origin, tell the host
  // to apply the compensating layer shift (pin the ROOT card at the cursor while
  // the window covers the whole cascade). Done AFTER SetWindowPos so the window
  // move and the content shift are causally ordered (window first, content ~1
  // frame later) instead of the host shifting its layer a full Dart round-trip
  // BEFORE the window moved (the cross-vsync "几何跳动"). bbox_left/top are
  // window-local CSS px (the host negates them for the layer translate).
  // std::to_wstring on a double yields a plain decimal literal JS parses.
  //
  // BUG-859 — fold any work-area CLAMP delta into the layer shift. The clamp
  // above can silently move the window origin off the intended (pending + dx/dy)
  // position; the host's layer shift was computed against the INTENDED origin,
  // so an un-reported clamp shifted every card (root + nested) on screen by the
  // clamp amount. Adding the delta (converted to CSS px with this window's own
  // dpr, matching the host's coordinate scale) keeps on-screen positions exact:
  // screen = clampedOrigin + dpr·(−(bbox+delta) + shell) = intended + dpr·shell.
  // The Dart reserve-to-edge floor normally makes the clamp a no-op (delta 0 →
  // byte-identical script), so this only engages in the degraded cases (stale
  // work-area data, monitor scale changes mid-lookup).
  if (webview_ != nullptr) {
    const double dpr = GetDpiForWindow(hwnd_) / 96.0;
    const double clamp_dx_css = dpr > 0 ? (x - intended_x) / dpr : 0.0;
    const double clamp_dy_css = dpr > 0 ? (y - intended_y) / dpr : 0.0;
    std::wstring shift_script =
        L"window.__globalLookupHost && "
        L"window.__globalLookupHost.commitLayerShift(" +
        std::to_wstring(bbox_left + clamp_dx_css) + L", " +
        std::to_wstring(bbox_top + clamp_dy_css) + L");";
    webview_->ExecuteScript(shift_script.c_str(), nullptr);
  }
  // Arm the click-outside dismiss hooks now that the stack is on-screen (the
  // first reveal arms; later resizes are idempotent re-arms). The clipboard
  // panel instance never arms them (persistent semantics, see Reveal).
  if (arm_dismiss_hooks_) {
    s_hook_owner_ = this;
    if (foreground_hook_ == nullptr) {
      foreground_hook_ = SetWinEventHook(
          EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
          &GlobalLookupWindow::ForegroundHookProc, 0, 0,
          WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    // BUG-1048 — 钩子跑在专用线程上（见 low_level_mouse_hook.h）：装在 platform 线程
    // 时，全系统每个鼠标事件都要排在 Flutter 的帧后面，游戏里鼠标一动就卡。
    fushi::ArmLowLevelMouseHook(hwnd_);
    mouse_hook_armed_ = true;
  }
}

void GlobalLookupWindow::ResizeTo(int width, int height) {
  if (hwnd_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  RECT rc;
  GetWindowRect(hwnd_, &rc);
  int x = rc.left;
  int y = rc.top;

  HMONITOR monitor = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(monitor, &mi)) {
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int work_h = mi.rcWork.bottom - mi.rcWork.top;
    width = width < work_w ? width : work_w;
    height = height < work_h ? height : work_h;
    if (x + width > mi.rcWork.right) {
      x = mi.rcWork.right - width;
    }
    if (y + height > mi.rcWork.bottom) {
      y = mi.rcWork.bottom - height;
    }
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

void GlobalLookupWindow::ResizeOffscreen(int width, int height) {
  if (hwnd_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  // ResizeTo deliberately clamps its current rectangle into the nearest
  // monitor's work area. That is correct for desktop overlays, but it moves the
  // galgame capture surface from OffscreenX() back onto the desktop. Keep this
  // HWND shown (WebView2 must continue laying out and painting for capture),
  // while parking it outside the virtual desktop and keeping reveal semantics
  // explicitly false.
  SetWindowPos(hwnd_, HWND_TOPMOST, OffscreenX(), 0, width, height,
               SWP_NOACTIVATE | SWP_NOOWNERZORDER);
  visible_ = false;
  revealed_ = false;
  offscreen_active_ = true;
}

void GlobalLookupWindow::ResizeStackOffscreen(int width, int height,
                                              double bbox_left,
                                              double bbox_top) {
  ResizeOffscreen(width, height);
  if (hwnd_ == nullptr || width <= 0 || height <= 0 || webview_ == nullptr) {
    return;
  }
  // Nested cards share the normal popup renderer. Its union bbox may extend to
  // the left or above the root card, so the host layer still needs the same
  // compensating translation as an on-screen RevealStack. The off-screen HWND
  // itself stays at OffscreenX(); there is no monitor-clamp delta to fold in.
  const std::wstring route_script =
      L"{source:'" + Utf8ToWide(route_context_.source) +
      L"',routeEpoch:" + std::to_wstring(route_context_.route_epoch) +
      L",lookupEpoch:" + std::to_wstring(route_context_.lookup_epoch) + L"}";
  // Keep an inline double-rAF fallback for a WebView that is still running the
  // previous host asset during an app update/hot restart.  A guarded no-op here
  // would be fatal for galCard: Dart has already committed this resize and is
  // waiting exclusively for captureReady, so its old reveal safety cannot fire.
  // The fallback preserves the old commitLayerShift when present, then posts the
  // same route-stamped message after a paint opportunity.  The production path
  // remains the host helper, which additionally rejects a stale active route.
  std::wstring shift_script =
      L"(function(host,route,w,h){"
      L"if(host&&typeof host.commitLayerShiftAndArmCapture==='function'){"
      L"host.commitLayerShiftAndArmCapture(" +
      std::to_wstring(bbox_left) + L"," + std::to_wstring(bbox_top) +
      L",route,w,h);return;}"
      L"if(host&&typeof host.commitLayerShift==='function'){host.commitLayerShift(" +
      std::to_wstring(bbox_left) + L"," + std::to_wstring(bbox_top) +
      L");}"
      L"var token=(window.__fushiGalCaptureReadyToken||0)+1;"
      L"window.__fushiGalCaptureReadyToken=token;"
      L"var post=function(){if(window.__fushiGalCaptureReadyToken!==token)"
      L"return;try{window.chrome.webview.postMessage({"
      L"handler:'captureReady',args:[w,h],__source:route.source,"
      L"__routeEpoch:route.routeEpoch,__lookupEpoch:route.lookupEpoch});"
      L"}catch(e){}};"
      L"if(typeof window.requestAnimationFrame==='function'){"
      L"window.requestAnimationFrame(function(){"
      L"window.requestAnimationFrame(post);});}else{post();}"
      L"})(window.__globalLookupHost," +
      route_script + L"," + std::to_wstring(width) + L"," +
      std::to_wstring(height) + L");";
  webview_->ExecuteScript(shift_script.c_str(), nullptr);
}

namespace {

// spec §6 Win10 translucency fallback — the undocumented user32
// SetWindowCompositionAttribute accent policy (the API TranslucentTB /
// EarTrumpet shipped on for ~a decade; Win10 is feature-frozen so the removal
// risk is effectively nil). Win10 has no documented per-window backdrop and
// WS_EX_LAYERED is WebView2-incompatible, so this is the only viable
// translucency path there. Deliberately ACCENT_ENABLE_BLURBEHIND (3), NOT
// ACCENT_ENABLE_ACRYLICBLURBEHIND (4): the acrylic accent has a well-known,
// never-fixed drag/resize lag regression since Win10 1903 — and the panel is
// repositioned via the HTCAPTION modal drag loop, which would hit it head-on.
// GradientColor is ABGR and must carry a non-zero alpha on some builds for the
// blur to engage (0x01 black tint = visually neutral).
struct AccentPolicy {
  int accent_state;
  int accent_flags;
  DWORD gradient_color;
  int animation_id;
};

struct WindowCompositionAttribData {
  int attrib;
  PVOID pv_data;
  SIZE_T cb_data;
};

using SetWindowCompositionAttributeProc =
    BOOL(WINAPI*)(HWND, WindowCompositionAttribData*);

bool ApplyWin10AccentBlurBehind(HWND hwnd) {
  const HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32 == nullptr) {
    return false;
  }
  const auto set_wca = reinterpret_cast<SetWindowCompositionAttributeProc>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (set_wca == nullptr) {
    return false;
  }
  AccentPolicy accent{};
  accent.accent_state = 3;             // ACCENT_ENABLE_BLURBEHIND
  accent.accent_flags = 0;
  accent.gradient_color = 0x01000000;  // ABGR: alpha 0x01, black tint
  accent.animation_id = 0;
  WindowCompositionAttribData data{};
  data.attrib = 19;  // WCA_ACCENT_POLICY
  data.pv_data = &accent;
  data.cb_data = sizeof(accent);
  return set_wca(hwnd, &data) != FALSE;
}

}  // namespace

bool GlobalLookupWindow::ApplySystemBackdrop() {
  if (hwnd_ == nullptr) {
    return false;
  }
  // spec §6 semi-transparency gate — translucency chain (first hit wins):
  // 1) Win11 22H2+ system backdrop: DWM paints acrylic (blurred desktop
  //    content behind the window) wherever the client pixels are transparent;
  //    the WebView2 default background is already fully transparent
  //    (put_DefaultBackgroundColor A=0, TODO-893), so a CSS rgba card
  //    background composites over the acrylic. Extend the frame into the whole
  //    client area first — without it the backdrop only covers the (zero-size)
  //    frame region.
  // 2) Win10 fallback: undocumented accent-policy blur-behind (see
  //    ApplyWin10AccentBlurBehind above) — same WebView2 transparency
  //    prerequisite, plain blur instead of acrylic.
  // 3) Both unavailable -> false: the panel stays opaque and Dart hides the
  //    opacity slider (graceful degrade, spec §6 fallback).
  const MARGINS margins{-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(hwnd_, &margins);
  int backdrop = 3;  // DWMSBT_TRANSIENTWINDOW (acrylic)
  const HRESULT hr = DwmSetWindowAttribute(
      hwnd_, 38 /* DWMWA_SYSTEMBACKDROP_TYPE */, &backdrop, sizeof(backdrop));
  if (SUCCEEDED(hr)) {
    return true;
  }
  return ApplyWin10AccentBlurBehind(hwnd_);
}

void GlobalLookupWindow::SetWindowTitle(const std::wstring& title) {
  if (title.empty()) {
    return;
  }
  window_title_ = title;
  if (hwnd_ != nullptr) {
    // 已创建（面板启动即预热）：任务栏按钮标题即时更新。
    SetWindowTextW(hwnd_, window_title_.c_str());
  }
}

// BUG-1479 — 显示期间周期性重申置顶。
//
// 判据必须是「本实例本来就要置顶」而不是「无脑重申」：未 pin 的常驻剪贴板面板
// 有意落在非置顶带（见 RaiseToFront），定时器把它拖回置顶带就是另一个 bug。
namespace {
constexpr UINT_PTR kTopmostGuardTimerId = 0xA11D;
// 800ms：够快到用户看不出被压过（游戏重申置顶通常在切场景/取焦点时），
// 又慢到一次 SetWindowPos 的开销可以忽略。
constexpr UINT kTopmostGuardIntervalMs = 800;
}  // namespace

void GlobalLookupWindow::ReassertTopmost() {
  if (hwnd_ == nullptr || !wants_topmost_ || !IsShowing()) {
    return;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

void GlobalLookupWindow::StartTopmostGuard() {
  if (hwnd_ == nullptr || !wants_topmost_ || topmost_guard_timer_ != 0) {
    return;
  }
  topmost_guard_timer_ =
      SetTimer(hwnd_, kTopmostGuardTimerId, kTopmostGuardIntervalMs, nullptr);
}

void GlobalLookupWindow::StopTopmostGuard() {
  if (hwnd_ == nullptr || topmost_guard_timer_ == 0) {
    return;
  }
  KillTimer(hwnd_, kTopmostGuardTimerId);
  topmost_guard_timer_ = 0;
}

void GlobalLookupWindow::SetTopmost(bool topmost) {
  if (hwnd_ == nullptr) {
    return;
  }
  // 记住意图：重申定时器据此决定该不该把窗口拖回置顶带。
  wants_topmost_ = topmost;
  if (!topmost) StopTopmostGuard();
  // SWP_NOOWNERZORDER：不带它时改 Z 序会连带 owner 的 Z 序（真机症状=点图钉
  // 把主 app 拉到前台）。面板现已无 owner（见 RegisterClipboardPanelChannel），
  // 此标志兜底防回归；与 Reveal/RevealStack 的 SetWindowPos 口径一致。
  SetWindowPos(hwnd_, topmost ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

void GlobalLookupWindow::SetBlockCapture(bool block) {
  block_capture_ = block;
  ApplyBlockCapture();
}

void GlobalLookupWindow::ApplyBlockCapture() {
  if (hwnd_ == nullptr) {
    return;
  }
  // WDA_EXCLUDEFROMCAPTURE：窗口对用户可见但从截图 / 录屏 / 屏幕共享里排除
  // （查词内容不外泄）。Win10<2004 该值不被支持 -> API 失败，回退 WDA_MONITOR
  // （被捕获处画成黑块，同样不泄露内容）。关闭时 WDA_NONE 恢复正常可截。
  if (!block_capture_) {
    SetWindowDisplayAffinity(hwnd_, WDA_NONE);
    return;
  }
  if (!SetWindowDisplayAffinity(hwnd_, WDA_EXCLUDEFROMCAPTURE)) {
    SetWindowDisplayAffinity(hwnd_, WDA_MONITOR);
  }
}

void GlobalLookupWindow::RaiseToFront(bool topmost) {
  if (hwnd_ == nullptr) {
    return;
  }
  // 每次查词把已显示的面板重排到 z 序最上，绝不激活（SWP_NOACTIVATE，不抢当前
  // 前台窗口键盘焦点）。SWP_NOOWNERZORDER 兜底不连带 owner（面板现无 owner，
  // 与 SetTopmost/Reveal 口径一致）。
  const UINT flags =
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER;
  if (topmost) {
    // 已 pin：直接顶到置顶带最上。
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0, flags);
    return;
  }
  // 未 pin：裸 HWND_TOP 在别的 app 处于前台时可能被前台锁拒绝，故先短暂置顶
  // 再撤销——面板落到「非置顶带最上、仍压在前台游戏/浏览器之上」，且全程不激活。
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0, flags);
  SetWindowPos(hwnd_, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
}

void GlobalLookupWindow::SetWindowAlpha(int percent) {
  if (hwnd_ == nullptr) {
    return;
  }
  // 背景逐像素透明（composition）模式：透明由 DComp per-pixel 承担，整窗
  // WS_EX_LAYERED + LWA_ALPHA 会与之冲突（把文字一起变淡、甚至令 NOREDIRECTIONBITMAP
  // 窗不渲染）。此模式下整窗 alpha 是 no-op，透明度语义交给 CSS 卡背景（cardBgAlpha）。
  if (composition_active_) {
    return;
  }
  if (percent < 30) percent = 30;
  if (percent > 100) percent = 100;
  const LONG_PTR ex = GetWindowLongPtrW(hwnd_, GWL_EXSTYLE);
  if ((ex & WS_EX_LAYERED) == 0) {
    SetWindowLongPtrW(hwnd_, GWL_EXSTYLE, ex | WS_EX_LAYERED);
  }
  // A WS_EX_LAYERED window does not render AT ALL until
  // SetLayeredWindowAttributes is called — always call it (100% => 255), and
  // keep the layered bit once set (toggling it forces repaint quirks).
  SetLayeredWindowAttributes(
      hwnd_, 0, static_cast<BYTE>((255 * percent) / 100), LWA_ALPHA);
}

void GlobalLookupWindow::Hide(bool notify) {
  // Capture BEFORE clearing: the HiddenCallback must only fire on a transition
  // FROM on-screen (was_showing) so a double dismiss (mouse hook then foreground
  // hook, both fire on one click-outside) does not double-notify Dart.
  const bool was_showing = visible_ || offscreen_active_;
  const RouteContext hidden_route = route_context_;
  visible_ = false;
  revealed_ = false;
  offscreen_active_ = false;
  // BUG-749 — drop the per-shell region rects: the next lookup renders a new
  // cascade and re-posts fresh rects (the host resets its de-dup key in
  // beginLookup), so a stale region can never clip the next card.
  shell_rects_css_.clear();
  ReleaseDismissHooks();
  StopTopmostGuard();
  if (hwnd_ != nullptr) {
    ShowWindow(hwnd_, SW_HIDE);
  }
  // TODO-1233 -- tell Dart the overlay dismissed. The foreground hook, the
  // click-outside mouse hook and the JS 'dismiss'/'tapOutside' path all funnel
  // through Hide() (notify defaults true), so this is the single dismissal
  // funnel. The programmatic reset that GlobalLookupController runs right BEFORE
  // a fresh lookup passes notify=false, so the between-lookups collapse to
  // known-hidden never looks like a user dismissal (which would spuriously
  // resume a paused video mid re-lookup). Fires on the platform thread (hooks
  // post to the creating thread's loop; the JS path is already there), so the
  // channel InvokeMethod wired to this callback is safe.
  if (notify && was_showing && hidden_cb_) {
    hidden_cb_(hidden_route);
  }
}

bool GlobalLookupWindow::IsShowing() const {
  // OwnsLiveWindow() (not a bare hwnd_ != nullptr) so a dangling/recycled handle
  // can never report the overlay as showing — otherwise Dart's re-check skips
  // the rebuild and renders into a window that no longer exists.
  return visible_ && OwnsLiveWindow() && IsWindowVisible(hwnd_);
}

std::wstring GlobalLookupWindow::LoadAdapterScript() const {
  if (popup_assets_dir_.empty()) {
    return std::wstring();
  }
  std::wstring path = popup_assets_dir_ + L"\\popup_bridge_adapter.js";
  std::ifstream file(path.c_str(), std::ios::binary);
  if (!file) {
    return std::wstring();
  }
  std::ostringstream ss;
  ss << file.rdbuf();
  return Utf8ToWide(ss.str());
}

// TODO-867 P3c — load the app-OUTSIDE nested-stack host script. Injected into
// the top-level WebView2 document (global_lookup_host.html) so
// window.__globalLookupHost.renderStack exists; the single-frame and nested
// lookups both render through the host iframe stack (no top-level direct
// renderPopup). Mirrors LoadAdapterScript exactly (read + UTF8->Wide).
std::wstring GlobalLookupWindow::LoadHostScript() const {
  if (popup_assets_dir_.empty()) {
    return std::wstring();
  }
  std::wstring path = popup_assets_dir_ + L"\\global_lookup_host.js";
  std::ifstream file(path.c_str(), std::ios::binary);
  if (!file) {
    return std::wstring();
  }
  std::ostringstream ss;
  ss << file.rdbuf();
  return Utf8ToWide(ss.str());
}

// TODO-1153 -- single failure sink for the overlay WebView2 bring-up. Writes the
// message + HRESULT (hex) to the native diagnostic log AND routes it to Dart's
// ErrorLogService via the error callback (wired in RegisterGlobalLookupChannel),
// so an app-external "no popup" failure is user-visible/diagnosable exactly like
// the TODO-1086 hotkey-registration failure, instead of being silently dropped.
// Runs on the platform thread (WebView2 posts completion callbacks to the
// creating thread's loop), so invoking the channel callback here is safe.
void GlobalLookupWindow::ReportOverlayError(const std::string& message,
                                            HRESULT hr) {
  char hr_buf[16];
  _snprintf_s(hr_buf, sizeof(hr_buf), _TRUNCATE, "0x%08lX",
              static_cast<unsigned long>(hr));
  const std::string full = message + " hr=" + hr_buf;
  NativeGlog(full);
  if (error_cb_) {
    error_cb_(full);
  }
}

// 背景逐像素透明 — 建 D3D11 + DirectComposition 设备（无需 HWND，可在建窗前探测
// 能力）。硬件设备失败回退 WARP（远程桌面/无 GPU），仍失败则整条回退 windowed
// （composition_active_=false），面板照常工作、只是不透明。幂等（已建则直接 true）。
bool GlobalLookupWindow::InitCompositionDevice() {
  if (dcomp_device_ != nullptr) {
    return true;
  }
  const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  D3D_FEATURE_LEVEL feature_level = D3D_FEATURE_LEVEL_11_0;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, nullptr, 0, D3D11_SDK_VERSION,
                                 &d3d_device_, &feature_level, nullptr);
  if (FAILED(hr) || d3d_device_ == nullptr) {
    // 无硬件 GPU / 远程桌面：WARP 软件设备兜底。
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                           nullptr, 0, D3D11_SDK_VERSION, &d3d_device_,
                           &feature_level, nullptr);
  }
  if (FAILED(hr) || d3d_device_ == nullptr) {
    ReportOverlayError("composition: D3D11CreateDevice failed", hr);
    return false;
  }
  wil::com_ptr<IDXGIDevice> dxgi_device;
  hr = d3d_device_->QueryInterface(IID_PPV_ARGS(&dxgi_device));
  if (FAILED(hr) || dxgi_device == nullptr) {
    ReportOverlayError("composition: QI IDXGIDevice failed", hr);
    d3d_device_ = nullptr;
    return false;
  }
  hr = DCompositionCreateDevice(dxgi_device.get(),
                                IID_PPV_ARGS(&dcomp_device_));
  if (FAILED(hr) || dcomp_device_ == nullptr) {
    ReportOverlayError("composition: DCompositionCreateDevice failed", hr);
    d3d_device_ = nullptr;
    dcomp_device_ = nullptr;
    return false;
  }
  return true;
}

// 背景逐像素透明 — 为已创建的 hwnd_ 建 DComp target + 承载 WebView 的根 visual。
// composition controller 的 put_RootVisualTarget 挂到这个 visual，Commit 后透明像素
// 上桌面。幂等。失败返回 false（调用方回退 / 报错）。
bool GlobalLookupWindow::EnsureCompositionTargetVisual() {
  if (dcomp_device_ == nullptr || hwnd_ == nullptr) {
    return false;
  }
  if (dcomp_target_ != nullptr && dcomp_visual_ != nullptr) {
    return true;
  }
  HRESULT hr =
      dcomp_device_->CreateTargetForHwnd(hwnd_, TRUE, &dcomp_target_);
  if (FAILED(hr) || dcomp_target_ == nullptr) {
    ReportOverlayError("composition: CreateTargetForHwnd failed", hr);
    return false;
  }
  hr = dcomp_device_->CreateVisual(&dcomp_visual_);
  if (FAILED(hr) || dcomp_visual_ == nullptr) {
    ReportOverlayError("composition: CreateVisual failed", hr);
    return false;
  }
  dcomp_target_->SetRoot(dcomp_visual_.get());
  return true;
}

DWORD GlobalLookupWindow::OverlayCreateExStyle() {
  // 背景逐像素透明：composition 请求下先探测 D3D11+DComp 设备能力（无需 HWND），
  // 成功才带 WS_EX_NOREDIRECTIONBITMAP（无重定向表面，透明像素经 DComp 上桌面）。
  // 探测失败回退 composition_active_=false（windowed），面板不透明但照常工作。
  if (composition_mode_ && !composition_active_) {
    composition_active_ = InitCompositionDevice();
  }
  return WS_EX_TOPMOST |
         (taskbar_presence_ ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW) |
         (activatable_ ? 0 : WS_EX_NOACTIVATE) |
         (composition_active_ ? WS_EX_NOREDIRECTIONBITMAP : 0);
}

// 背景逐像素透明（composition）— 把本窗收到的鼠标消息转发给 composition controller。
// windowed 模式 WebView2 子窗自动收输入，不走这里。坐标：非滚轮消息 lParam 已是
// 客户区物理像素（窗口 per-monitor DPI 感知，bounds 用 RAW_PIXELS，客户区=WebView 坐标）；
// 滚轮消息 lParam 是屏幕坐标，需 ScreenToClient。virtualKeys 与 MK_* 位值一一对应，
// 直接 cast。mouseData：滚轮=WHEEL_DELTA 倍数，其余 0。
void GlobalLookupWindow::ForwardCompositionMouse(UINT message, WPARAM wparam,
                                                 LPARAM lparam) {
  if (composition_controller_ == nullptr) {
    return;
  }
  const bool is_wheel =
      (message == WM_MOUSEWHEEL || message == WM_MOUSEHWHEEL);
  POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  UINT32 mouse_data = 0;
  COREWEBVIEW2_MOUSE_EVENT_KIND kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE;
  if (is_wheel) {
    ScreenToClient(hwnd_, &point);  // 滚轮 lParam 是屏幕坐标。
    mouse_data =
        static_cast<UINT32>(GET_WHEEL_DELTA_WPARAM(wparam));
    kind = (message == WM_MOUSEWHEEL)
               ? COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL
               : COREWEBVIEW2_MOUSE_EVENT_KIND_HORIZONTAL_WHEEL;
  } else {
    switch (message) {
      case WM_MOUSEMOVE:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE;
        break;
      case WM_LBUTTONDOWN:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOWN;
        break;
      case WM_LBUTTONUP:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_UP;
        break;
      case WM_LBUTTONDBLCLK:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOUBLE_CLICK;
        break;
      case WM_RBUTTONDOWN:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_DOWN;
        break;
      case WM_RBUTTONUP:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_RIGHT_BUTTON_UP;
        break;
      case WM_MBUTTONDOWN:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_DOWN;
        break;
      case WM_MBUTTONUP:
        kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MIDDLE_BUTTON_UP;
        break;
      default:
        return;
    }
  }
  const auto keys = static_cast<COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS>(
      GET_KEYSTATE_WPARAM(wparam));
  composition_controller_->SendMouseInput(kind, keys, mouse_data, point);
}

// v14 游戏内查词 — 注入侧转发来的 kind 与本地映射必须锁死在契约上。手抄 0..4 就等于
// 在 host 侧复制一份枚举，注入侧改了这边不会红——所以直接对真相源做 static_assert。
static_assert(fushi_voice_hook::kLookupInputMove == 0, "lookup input kind drift");
static_assert(fushi_voice_hook::kLookupInputLeftDown == 1,
              "lookup input kind drift");
static_assert(fushi_voice_hook::kLookupInputLeftUp == 2,
              "lookup input kind drift");
static_assert(fushi_voice_hook::kLookupInputWheel == 3,
              "lookup input kind drift");
static_assert(fushi_voice_hook::kLookupInputLeave == 4,
              "lookup input kind drift");

bool GlobalLookupWindow::InjectLookupInput(uint32_t kind, int32_t x, int32_t y,
                                           int32_t wheel, uint32_t keys) {
  // 游戏内卡片没有子 HWND，输入只能经 composition controller 进 WebView2。
  // windowed 实例在这里返回 false 而不是"看起来成功"，是为了让上层的
  // "卡片点不动" 立刻定位到"像素源实例没开 composition"，而不是去猜坐标换算。
  if (composition_controller_ == nullptr) {
    return false;
  }
  COREWEBVIEW2_MOUSE_EVENT_KIND event_kind =
      COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE;
  UINT32 mouse_data = 0;
  POINT point{static_cast<LONG>(x), static_cast<LONG>(y)};
  switch (kind) {
    case fushi_voice_hook::kLookupInputMove:
      event_kind = COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE;
      break;
    case fushi_voice_hook::kLookupInputLeftDown:
      event_kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOWN;
      break;
    case fushi_voice_hook::kLookupInputLeftUp:
      event_kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_UP;
      break;
    case fushi_voice_hook::kLookupInputWheel:
      event_kind = COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL;
      // WebView2 与 WM_MOUSEWHEEL 同款：mouseData 是 WHEEL_DELTA 的倍数（有符号，
      // 经 UINT32 传递）。注入侧填的就是游戏那边的原始 delta，这里不做二次缩放。
      mouse_data = static_cast<UINT32>(wheel);
      break;
    case fushi_voice_hook::kLookupInputLeave:
      event_kind = COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE;
      // SDK 契约：LEAVE 必须带 (0,0)，否则 SendMouseInput 返回 E_INVALIDARG。
      point.x = 0;
      point.y = 0;
      break;
    default:
      return false;
  }
  const auto virtual_keys =
      static_cast<COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS>(keys);
  const bool injected = SUCCEEDED(composition_controller_->SendMouseInput(
      event_kind, virtual_keys, mouse_data, point));
  if (injected && webview_ != nullptr) {
    // SendMouseInput only means the event reached WebView2; it does not mean
    // the renderer has painted the resulting scroll/hover/button state.  Ask
    // the host to publish a route-stamped dirty signal after two animation
    // frames.  Dart captures only in response to that signal, never directly
    // from the MethodChannel input acknowledgement.
    const std::wstring dirty_script =
        L"window.__globalLookupHost && "
        L"window.__globalLookupHost.armGalFrameDirty && "
        L"window.__globalLookupHost.armGalFrameDirty({source:'" +
        Utf8ToWide(route_context_.source) + L"',routeEpoch:" +
        std::to_wstring(route_context_.route_epoch) + L",lookupEpoch:" +
        std::to_wstring(route_context_.lookup_epoch) + L"});";
    webview_->ExecuteScript(dirty_script.c_str(), nullptr);
  }
  return injected;
}

void GlobalLookupWindow::CaptureBgraAsync(uint32_t max_width,
                                          uint32_t max_height,
                                          BgraFrameCallback done) {
  if (!done) {
    return;
  }
  // 失败一律走同一条出口：调用方永远收得到一次 continuation，绝不出现"投帧请求
  // 石沉大海"——那会让 Dart 侧的 present 调用永远挂着不回。
  auto fail = [&done]() {
    done(false, false, std::vector<uint8_t>(), 0, 0, 0);
  };
  if (webview_ == nullptr || !webview_ready_ || recovering_) {
    fail();
    return;
  }
  wil::com_ptr<IStream> stream;
  stream.attach(SHCreateMemStream(nullptr, 0));
  if (stream == nullptr) {
    fail();
    return;
  }
  // WRL 的 Callback 要求可调用对象可拷贝，而 BgraFrameCallback 只保证可移动语义可用；
  // 包一层 shared_ptr 既满足可拷贝，又保证 continuation 只有一份状态。
  auto sink = std::make_shared<BgraFrameCallback>(std::move(done));
  const HRESULT hr = webview_->CapturePreview(
      COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, stream.get(),
      Callback<ICoreWebView2CapturePreviewCompletedHandler>(
          [stream, sink, max_width, max_height](HRESULT result) -> HRESULT {
            std::vector<uint8_t> bgra;
            uint32_t width = 0;
            uint32_t height = 0;
            uint32_t pitch = 0;
            bool clamped = false;
            const bool ok =
                SUCCEEDED(result) &&
                DecodePngStreamToStraightBgra(stream.get(), max_width, max_height,
                                       &bgra, &width, &height, &pitch,
                                       &clamped);
            (*sink)(ok, clamped, bgra, width, height, pitch);
            return S_OK;
          })
          .Get());
  if (FAILED(hr)) {
    // 同步失败 => 完成回调不会被调用，必须在这里补一次 continuation。
    (*sink)(false, false, std::vector<uint8_t>(), 0, 0, 0);
  }
}

void GlobalLookupWindow::EnsureWebView() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  auto options = Make<CoreWebView2EnvironmentOptions>();
  // BUG-1091: mirror the in-app fork (in_app_webview.cpp) — WebView2 has no
  // per-view autoplay setting, so allow media autoplay process-wide for this
  // overlay environment. The overlay popup plays word audio via its own HTML5
  // <audio>; without this, an auto-read on a never-clicked overlay document
  // would be rejected by Chromium's autoplay policy exactly like in-app.
  options->put_AdditionalBrowserArguments(
      L"--autoplay-policy=no-user-gesture-required");
  // Register image:// AND dictmedia:// as custom schemes so WebResourceRequested
  // fires for them (non file/http(s) schemes are otherwise ignored). Must mirror
  // the in-app InAppWebView which registers BOTH schemes (see
  // dictionary_webview_media.dart dictionaryMediaCustomSchemes = [image,
  // dictmedia]). image:// serves gaiji/img bytes; dictmedia:// serves the
  // dictionary's <link> stylesheets (+ their relative font/bg resources). Mirrors
  // the fork's webview_environment.cpp:69-76.
  wil::com_ptr<ICoreWebView2EnvironmentOptions4> options4;
  if (SUCCEEDED(options->QueryInterface(IID_PPV_ARGS(&options4)))) {
    auto image_reg = Make<CoreWebView2CustomSchemeRegistration>(L"image");
    image_reg->put_TreatAsSecure(TRUE);
    image_reg->put_HasAuthorityComponent(TRUE);
    auto dictmedia_reg =
        Make<CoreWebView2CustomSchemeRegistration>(L"dictmedia");
    dictmedia_reg->put_TreatAsSecure(TRUE);
    dictmedia_reg->put_HasAuthorityComponent(TRUE);
    ICoreWebView2CustomSchemeRegistration* regs[] = {image_reg.Get(),
                                                     dictmedia_reg.Get()};
    options4->SetCustomSchemeRegistrations(2, regs);
  }

  // TODO-1153 -- create the overlay environment against its OWN user data folder
  // (see OverlayUserDataFolder above) so the image:// + dictmedia:// custom
  // schemes never clash with the in-app fork environments on the shared default
  // folder (0x8007139F), which previously failed this create silently and left
  // the overlay a blank window.
  const std::wstring overlay_folder = OverlayUserDataFolder(user_data_leaf_);
  HRESULT create_hr = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, overlay_folder.empty() ? nullptr : overlay_folder.c_str(),
      options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [this](HRESULT env_hr, ICoreWebView2Environment* env) -> HRESULT {
            // TODO-1153 -- do NOT swallow a failed environment create. A null
            // env here (or a failing HRESULT) means WebView2 could not build the
            // overlay environment; dereferencing it would crash, and ignoring it
            // leaves webview_ready_ false forever (blank popup). Surface it.
            if (FAILED(env_hr) || env == nullptr) {
              ReportOverlayError("WebView2 environment create failed (async)",
                                 env_hr);
              return env_hr;
            }
            env_ = env;
            // 背景逐像素透明 — composition 分区：QI env3 + DComp target/visual +
            // composition controller，透明像素经 DComp 上桌面（背景全透、文字实心）。
            // 瞬态窗 composition_active_=false，走下面 windowed 原路（一字不改）。任一
            // 步失败仅在 InitCompositionDevice 已成功后才可能（composition_active_=true、
            // 窗口已带 NOREDIRECTIONBITMAP），落到 windowed 也渲染不出——极罕见，已记日志。
            if (composition_active_ && EnsureCompositionTargetVisual()) {
              wil::com_ptr<ICoreWebView2Environment3> env3;
              if (SUCCEEDED(env_->QueryInterface(IID_PPV_ARGS(&env3))) &&
                  env3 != nullptr) {
                HRESULT cc_call_hr =
                    env3->CreateCoreWebView2CompositionController(
                        hwnd_,
                        Callback<
                            ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>(
                            [this](HRESULT cc_hr,
                                   ICoreWebView2CompositionController* cc)
                                -> HRESULT {
                              if (FAILED(cc_hr) || cc == nullptr) {
                                ReportOverlayError(
                                    "composition controller create failed",
                                    cc_hr);
                                return S_OK;
                              }
                              composition_controller_ = cc;
                              wil::com_ptr<ICoreWebView2Controller> base;
                              if (FAILED(composition_controller_->QueryInterface(
                                      IID_PPV_ARGS(&base))) ||
                                  base == nullptr) {
                                ReportOverlayError(
                                    "composition: QI ICoreWebView2Controller "
                                    "failed",
                                    E_NOINTERFACE);
                                return S_OK;
                              }
                              controller_ = base;
                              controller_->get_CoreWebView2(&webview_);
                              controller_->put_IsVisible(TRUE);
                              // 透明背景色（A=0）：只有实心像素画，其余透到桌面。
                              wil::com_ptr<ICoreWebView2Controller2> controller2;
                              if (SUCCEEDED(controller_->QueryInterface(
                                      IID_PPV_ARGS(&controller2)))) {
                                COREWEBVIEW2_COLOR transparent = {0, 0, 0, 0};
                                controller2->put_DefaultBackgroundColor(
                                    transparent);
                              }
                              // BUG-1104 — BoundsMode=RAW_PIXELS + 按窗口 DPI
                              // 钉死光栅缩放。原来这段是 composition 路径的内联
                              // 代码，windowed 回退路径没有对应物；现在两条路径
                              // 共用 ApplyDpiScale()。
                              ApplyDpiScale();
                              // WebView 的 visual 挂到 DComp 视觉树 → Commit 上桌面。
                              composition_controller_->put_RootVisualTarget(
                                  dcomp_visual_.get());
                              // 光标形状：composition 无子窗自动管光标，靠 WebView2
                              // 的 CursorChanged 通知 + WM_SETCURSOR 应用（hover 链接
                              // /文本时光标正确）。
                              composition_controller_->add_CursorChanged(
                                  Callback<
                                      ICoreWebView2CursorChangedEventHandler>(
                                      [this](
                                          ICoreWebView2CompositionController*
                                              sender,
                                          IUnknown*) -> HRESULT {
                                        HCURSOR cursor = nullptr;
                                        if (sender != nullptr &&
                                            SUCCEEDED(
                                                sender->get_Cursor(&cursor))) {
                                          composition_cursor_ = cursor;
                                          SetCursor(cursor);
                                        }
                                        return S_OK;
                                      })
                                      .Get(),
                                  nullptr);
                              RECT rc;
                              GetClientRect(hwnd_, &rc);
                              controller_->put_Bounds(rc);
                              if (dcomp_device_ != nullptr) {
                                dcomp_device_->Commit();
                              }
                              ConfigureWebView();
                              wil::com_ptr<ICoreWebView2_3> wv3;
                              if (webview_ &&
                                  SUCCEEDED(webview_->QueryInterface(
                                      IID_PPV_ARGS(&wv3))) &&
                                  !popup_assets_dir_.empty()) {
                                wv3->SetVirtualHostNameToFolderMapping(
                                    L"hibiki.popup", popup_assets_dir_.c_str(),
                                    COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
                              }
                              if (webview_) {
                                webview_->Navigate(
                                    L"https://hibiki.popup/"
                                    L"global_lookup_host.html");
                              }
                              return S_OK;
                            })
                            .Get());
                if (FAILED(cc_call_hr)) {
                  ReportOverlayError(
                      "CreateCoreWebView2CompositionController call failed",
                      cc_call_hr);
                }
                return S_OK;  // composition 路径已接管，不再走 windowed。
              }
            }
            HRESULT ctrl_hr = env_->CreateCoreWebView2Controller(
                hwnd_,
                Callback<
                    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [this](HRESULT ctrl_hr,
                           ICoreWebView2Controller* ctrl) -> HRESULT {
                      // TODO-1153 -- a null controller (or failing HRESULT) is a
                      // real failure, not a benign no-op: log it instead of
                      // silently returning S_OK so the blank-popup cause is
                      // diagnosable.
                      if (FAILED(ctrl_hr) || ctrl == nullptr) {
                        ReportOverlayError(
                            "WebView2 controller create failed", ctrl_hr);
                        return S_OK;
                      }
                      controller_ = ctrl;
                      controller_->get_CoreWebView2(&webview_);
                      controller_->put_IsVisible(TRUE);
                      // TODO-893 — paint the WebView2 composition surface
                      // TRANSPARENT (symptom 1, white-background half). The
                      // default DefaultBackgroundColor is opaque white, so the
                      // area OUTSIDE the rounded card shell (the host document
                      // has no body background of its own) shows as a hard white
                      // box — most visible once E1 enlarges the window into the
                      // cascade bounding box, where the white shows around the
                      // shell. ICoreWebView2Controller2::put_DefaultBackgroundColor
                      // with A=0 makes the surface transparent so only the shell
                      // (its theme card fill) paints. Available since WebView2
                      // 1.0.774+ (well below our SDK floor); a no-op if the
                      // interface is absent on an ancient runtime.
                      wil::com_ptr<ICoreWebView2Controller2> controller2;
                      if (SUCCEEDED(controller_->QueryInterface(
                              IID_PPV_ARGS(&controller2)))) {
                        COREWEBVIEW2_COLOR transparent = {0, 0, 0, 0};
                        controller2->put_DefaultBackgroundColor(transparent);
                      }
                      // BUG-1104 — windowed 回退路径过去**完全没有** DPI 处理：
                      // composition 路径钉了 RasterizationScale 并关掉自动探测，
                      // 这条路径却任由 WebView2 自己探测 monitor scale。于是同一
                      // 个窗在两条路径下位图缩放的真值来源不同，多屏 / 非 100%
                      // 缩放时可以差一档，亚像素取整误差被放大（BUG-1098 备注里
                      // 记的“放大器”）。统一到同一个入口。
                      ApplyDpiScale();
                      RECT rc;
                      GetClientRect(hwnd_, &rc);
                      controller_->put_Bounds(rc);
                      ConfigureWebView();

                      wil::com_ptr<ICoreWebView2_3> wv3;
                      if (webview_ &&
                          SUCCEEDED(webview_->QueryInterface(
                              IID_PPV_ARGS(&wv3))) &&
                          !popup_assets_dir_.empty()) {
                        wv3->SetVirtualHostNameToFolderMapping(
                            L"hibiki.popup", popup_assets_dir_.c_str(),
                            COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
                      }
                      if (webview_) {
                        webview_->Navigate(L"https://hibiki.popup/global_lookup_host.html");
                      }
                      // webview_ready_ is set in NavigationCompleted (popup.js
                      // must be loaded before renderPopup() exists).
                      return S_OK;
                    })
                    .Get());
            if (FAILED(ctrl_hr)) {
              ReportOverlayError("CreateCoreWebView2Controller call failed",
                                 ctrl_hr);
            }
            return S_OK;
          })
          .Get());
  // TODO-1153 -- capture the SYNCHRONOUS HRESULT. On an options/user-data-folder
  // conflict the create fails synchronously (the completion callback never
  // fires), so this is the only place the 0x8007139F is observable.
  if (FAILED(create_hr)) {
    ReportOverlayError(
        "CreateCoreWebView2EnvironmentWithOptions call failed (sync)",
        create_hr);
  }
}

// BUG-1104 — 两条 WebView2 创建路径的 DPI 处理必须同源。
//
// 窗口坐标、shell 卡矩形、commitLayerShift 的 CSS px 换算，全部按
// GetDpiForWindow(hwnd_) 算；而 WebView2 默认打开 ShouldDetectMonitorScaleChanges，
// 自己去探测 monitor scale。这是两个独立的真值来源——单屏 100% 时恰好相等，多屏
// 或非 100% 缩放时可以差一档，差出来的就是被放大的亚像素取整误差。composition
// 路径当年已经钉死了这一项，windowed 回退路径没有，于是同一个窗走哪条路径出来
// 的渲染都不完全一样。
//
// 解法是消除“两个来源”，而不是给 windowed 打补丁：真值只有一个——这个 HWND 的
// DPI，两条创建路径和 WM_DPICHANGED 都从这里读。关掉自动探测之后跟随 DPI 变化
// 就成了我们自己的责任，见 HandleMessage 的 WM_DPICHANGED。
//
// 老 runtime 拿不到 ICoreWebView2Controller3 时直接返回：保持它自己的默认行为，
// 绝不半套地只设一项。
void GlobalLookupWindow::ApplyDpiScale() {
  if (!controller_ || hwnd_ == nullptr) {
    return;
  }
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi == 0) {
    dpi = 96;
  }
  wil::com_ptr<ICoreWebView2Controller3> controller3;
  if (FAILED(controller_->QueryInterface(IID_PPV_ARGS(&controller3))) ||
      controller3 == nullptr) {
    return;
  }
  controller3->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);
  controller3->put_ShouldDetectMonitorScaleChanges(FALSE);
  controller3->put_RasterizationScale(static_cast<double>(dpi) / 96.0);
}

void GlobalLookupWindow::ConfigureWebView() {
  if (!webview_) {
    return;
  }

  // BUG-1097 — turn off the WebView2 status bar (the link-target preview).
  //
  // Yomitan structured content writes dictionary-internal links straight into
  // href (assets/popup/popup.js: element.setAttribute('href', node.href)), so
  // hovering a glossary cross-reference makes WebView2 paint
  // "https://hibiki.popup/popup.html?query=…&wildcards=off" in the bottom-left
  // corner of ITS OWN surface. The overlay host is a topmost frameless window
  // stretched over the whole cascade bounding box, so that strip reads to the
  // user as a stray URL in the bottom-left of the app. The href itself must
  // stay (the click handler needs it, and preventDefault only cancels the
  // click — it can never cancel the hover preview), so the fix is to disable
  // the preview surface.
  //
  // put_IsStatusBarEnabled lives on the BASE ICoreWebView2Settings, so no
  // version QI is needed. ConfigureWebView() is the single funnel for both
  // creation paths (composition + windowed) and for the BUG-693 self-heal
  // rebuild, so this one call covers every surface this window ever owns.
  wil::com_ptr<ICoreWebView2Settings> settings;
  HRESULT status_bar_hr = webview_->get_Settings(&settings);
  if (SUCCEEDED(status_bar_hr) && settings != nullptr) {
    status_bar_hr = settings->put_IsStatusBarEnabled(FALSE);
  } else if (SUCCEEDED(status_bar_hr)) {
    status_bar_hr = E_POINTER;  // get_Settings said OK but handed back null.
  }
  if (FAILED(status_bar_hr)) {
    // Never swallow it: a failure here means the stray URL is back, and we do
    // not want to re-investigate that from zero.
    ReportOverlayError("put_IsStatusBarEnabled(FALSE) failed", status_bar_hr);
  }

  // BUG-1139 — 关掉 WebView2 自带的页面缩放（Ctrl+滚轮 / Ctrl+加减 / 触控板捏合）。
  //
  // 这个窗的几何链**整条**按「CSS px @ zoom=1」算：host 的 measureAndReport 用
  // shell.style.left/width + body.scrollHeight 报 bbox 与 shellRects（CSS px），
  // Dart 按 `逻辑宽 × appUiScale × dpr` 定物理窗口大小（global_lookup_controller
  // .dart 的 _applyOverlayBox / ShowAt），C++ 再用同一批数值 SetWindowPos + 裁
  // window region（ApplyRoundedRegion）。WebView2 的 ZoomFactor 不在这条链的任何
  // 一环里——它只放大**绘制**，不改这些 CSS px 读数。
  //
  // 而 ForwardCompositionMouse 把 WM_MOUSEWHEEL 连同 MK_CONTROL 原样
  // SendMouseInput 给 WebView2，popup.js 的滚轮监听又明确 `if (e.ctrlKey) return`
  // 把 Ctrl+滚轮让给原生。于是用户在 app 外浮窗上 Ctrl+滚轮 → 内容按 z 放大绘制，
  // 窗口和 region 仍是 z=1 的尺寸 → 卡片被窗口边缘竖着切掉、region 外直接露出底下
  // 的应用（用户报的「左边是空的」）。
  //
  // 这里断掉原生缩放这个「看不见的第二真值来源」，与 in-app 弹窗的
  // `supportZoom: false`（dictionary_popup_webview.dart 的 InAppWebViewSettings）
  // 对齐；缩放能力不丢：Ctrl+滚轮改由 popup_settings_injection 注入的监听回传
  // popupZoomFontStep，Dart 改「词典字号」后整栈重渲，排版沿现有链路自然更新，
  // 几何链一行不用改。
  //
  // put_ZoomFactor(1.0) 是必须的第二步，不是保险：WebView2 的缩放档位按 origin
  // **持久记忆**在用户数据目录里，只关 IsZoomControlEnabled 不会复位已经缩过的
  // 那一档——老用户升级后窗口照样是切的。IsZoomControlEnabled 在基础
  // ICoreWebView2Settings 上、ZoomFactor 在 ICoreWebView2Controller 上，两者都无需
  // 版本 QI。ConfigureWebView 是两条创建路径 + BUG-693 自愈重建的唯一漏斗，所以
  // 这个窗曾经拥有的每个 surface 都被覆盖。
  if (settings != nullptr) {
    HRESULT zoom_ctl_hr = settings->put_IsZoomControlEnabled(FALSE);
    if (FAILED(zoom_ctl_hr)) {
      ReportOverlayError("put_IsZoomControlEnabled(FALSE) failed", zoom_ctl_hr);
    }
  }
  if (controller_ != nullptr) {
    HRESULT zoom_reset_hr = controller_->put_ZoomFactor(1.0);
    if (FAILED(zoom_reset_hr)) {
      ReportOverlayError("put_ZoomFactor(1.0) failed", zoom_reset_hr);
    }
  }

  // Inject the bridge adapter at document start so popup.js's
  // window.flutter_inappwebview.callHandler maps to chrome.webview.postMessage.
  std::wstring adapter = LoadAdapterScript();
  if (!adapter.empty()) {
    webview_->AddScriptToExecuteOnDocumentCreated(adapter.c_str(), nullptr);
  }

  // TODO-867 P3c — inject the nested-stack host AFTER the adapter (host.js does
  // not depend on the adapter, but keeping adapter-first is the stable order).
  // AddScriptToExecuteOnDocumentCreated runs on EVERY frame incl. child iframes;
  // host.js bails on sub-frames via its `window.top !== window.self` guard so it
  // only installs on the top-level host document.
  std::wstring host = LoadHostScript();
  if (!host.empty()) {
    webview_->AddScriptToExecuteOnDocumentCreated(host.c_str(), nullptr);
  }

  // Render only after popup.html (and popup.js) finished loading, otherwise
  // window.renderPopup() does not exist yet.
  webview_->add_NavigationCompleted(
      Callback<ICoreWebView2NavigationCompletedEventHandler>(
          [this](ICoreWebView2*,
                 ICoreWebView2NavigationCompletedEventArgs*) -> HRESULT {
            webview_ready_ = true;
            // TODO-1268 (BUG-693) -- a recovery rebuild (RecoverDeadWebView)
            // completes here: the new surface is ready, further renders may
            // execute directly again.
            recovering_ = false;
            if (!pending_json_.empty()) {
              std::string json = pending_json_;
              pending_json_.clear();
              RenderJson(json);
            }
            return S_OK;
          })
          .Get(),
      nullptr);

  // TODO-1268 (BUG-693) -- self-heal a dead overlay WebView2 process tree.
  //
  // The overlay is a prewarmed, hidden, hours-lived surface: it is created once
  // at startup and only SW_HIDE'd between lookups for the rest of the app
  // session. When its render or browser process dies mid-session (WebView2
  // runtime update, GPU reset, OOM kill, renderer crash), the COM proxies here
  // stayed alive and webview_ready_ stayed TRUE, so every later lookup
  // ExecuteScript'ed into a dead page: the host never posted
  // overlaySize/popupRendered again and Dart could only blank-reveal via the
  // READY-SAFETY fallback until the app was restarted. That is the exact
  // device-log signature of TODO-1268 ("lookupText -> searched -> showAt ->
  // reveal: READY-SAFETY" with ZERO host messages, while the SAME session's
  // earlier hotkey lookup worked): the floating-subtitle strip tap is the
  // overlay's main mid-session consumer, so it was the reporter, but the
  // global hotkey dies identically once the process is gone.
  //
  // Recovery follows the documented WebView2 contract:
  //   - BROWSER_PROCESS_EXITED kills every COM object under env_ -> drop them
  //     and rebuild the environment/controller/webview against the SAME hwnd_
  //     (EnsureWebView -> ConfigureWebView re-registers these handlers on the
  //     new instance and re-navigates the host document).
  //   - RENDER_PROCESS_EXITED / RENDER_PROCESS_UNRESPONSIVE keep the browser
  //     process alive -> Reload() the host document.
  //   - Any other (extended) kind - GPU / utility / frame helper failures -
  //     does not tear down the page: log only, and critically do NOT clear
  //     webview_ready_ (nothing would re-arm it without a navigation).
  // For the two recovered kinds webview_ready_ goes FALSE first, so
  // RenderJson() caches the next lookup's script in pending_json_ instead of
  // executing into the dead page, and NavigationCompleted (above) re-arms
  // ready + flushes it -- the very next tap renders a REAL card again.
  webview_->add_ProcessFailed(
      Callback<ICoreWebView2ProcessFailedEventHandler>(
          [this](ICoreWebView2*,
                 ICoreWebView2ProcessFailedEventArgs* args) -> HRESULT {
            COREWEBVIEW2_PROCESS_FAILED_KIND kind =
                COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED;
            if (args != nullptr) {
              args->get_ProcessFailedKind(&kind);
            }
            ReportOverlayError(
                "overlay WebView2 process failed, kind=" +
                    std::to_string(static_cast<int>(kind)) + "; recovering",
                E_FAIL);
            switch (kind) {
              case COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED:
              case COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED:
              case COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_UNRESPONSIVE:
                // Same single rebuild path as the ExecuteScript liveness check
                // (see RecoverDeadWebView): keep whatever render is already
                // cached and rebuild the surface. Extended kinds (GPU/utility
                // helper failures) do not tear down the page: log only, and
                // critically do NOT clear webview_ready_ (nothing would re-arm
                // it without a navigation).
                RecoverDeadWebView(pending_json_);
                break;
              default:
                break;
            }
            return S_OK;
          })
          .Get(),
      nullptr);

  // Receive JS postMessage (callHandler bridge + dismiss/audio).
  webview_->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
          [this](ICoreWebView2*,
                 ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
            wil::unique_cotaskmem_string json;
            if (SUCCEEDED(args->get_WebMessageAsJson(&json))) {
              std::string body = WideToUtf8(json.get());
              // spec 2026-07-10 panel — host-chrome window drag/resize. The
              // client area is fully covered by the WebView2 child HWND, so
              // WM_NCHITTEST never reaches this window; the panel grip posts
              // {handler:'beginWindowDrag'/'beginWindowResize'} instead and we
              // enter the modal move/size loop via the HTCAPTION trick.
              // 真机修复：必须 PostMessage 而非 SendMessage——SendMessage 在
              // WebMessageReceived 的 COM 回调栈里同步进模态循环，会把 WebView2
              // 的消息派发挂在回调里（真机表现=面板拖不动）。PostMessage 让模态
              // 循环从消息泵正常入口启动；拖/拉结束后由 WM_EXITSIZEMOVE（见
              // HandleMessage）统一回报最终 rect 给 Dart 持久化。Matching
              // quoted handler names keeps glossary text that merely mentions
              // the words from triggering this.
              // BUG-749 — the transient host reports its per-shell card rects
              // (window-relative CSS px) whenever the cascade layout changes.
              // Handled fully natively (region update is pure Win32 state, no
              // Dart decision involved) and NOT forwarded, so the Dart message
              // log is not spammed once per measure pass.
              if (body.find("\"handler\":\"shellRects\"") !=
                  std::string::npos) {
                SetShellRectsFromCsv(body);
                return S_OK;
              }
              if (body.find("\"handler\":\"beginWindowDrag\"") !=
                      std::string::npos ||
                  body.find("\"handler\":\"beginWindowResize\"") !=
                      std::string::npos) {
                const bool resize =
                    body.find("\"handler\":\"beginWindowResize\"") !=
                    std::string::npos;
                if (hwnd_ != nullptr) {
                  ReleaseCapture();
                  PostMessage(hwnd_, WM_NCLBUTTONDOWN,
                              resize ? HTBOTTOMRIGHT : HTCAPTION, 0);
                }
                return S_OK;
              }
              if (message_cb_) {
                message_cb_(body, RouteForMessage(body));
              }
              // Resolve the callHandler promise so popup.js await-points never
              // hang. Most handlers are read-only here and get an immediate
              // null. The AUDIO handlers, however, need a real reply from the
              // main Dart engine (audio URL / play result), so they are
              // DEFERRED: native does not resolve them; Dart computes the reply
              // and calls back ResolveBridge(id, json). The id is the integer
              // after "__bridgeId":.
              // TODO-1188 — favoriteEntry/favoriteCheck are ALSO deferred: the
              // main Dart engine toggles/reads the FavoriteWords row and returns
              // the new ☆/★ state via ResolveBridge. An immediate null here would
              // resolve the popup.js Promise with null BEFORE Dart's real reply,
              // so the star never flips (the earlier "favorite button does
              // nothing" bug). The reply is routed back to the SOURCE iframe by
              // the host bridge router (global_lookup_host.js).
              // TODO-1188 follow-up — mineEntry/duplicateCheck are DEFERRED for
              // the SAME reason: the +/mine button awaits mineEntry's real
              // {ankiConnect,noteId} (repo.mineEntry via AnkiConnect/AnkiDroid)
              // and then duplicateCheck's real bool to flip +/mine into the
              // already-mined check. An immediate null here would resolve
              // mineEntry with null (parseMineResult -> no card / no refresh) and
              // duplicateCheck with null (never mined), so app-external mining
              // silently did nothing. Dart computes both replies and
              // ResolveBridge()s them; the host router returns each reply to the
              // source iframe (no host.js change needed).
              // TODO-1225 follow-up -- overwriteTargetNoteId + updateEntry are the
              // OTHER half of the overwrite (✓↩) panel and are now DEFERRED
              // too: popup.js awaits overwriteTargetNoteId's real note id (Dart
              // repo.findOverwriteTargetNoteId; non-null only when overwrite scope =
              // all) to promote an existing card to the editable ✓↩ state,
              // and awaits updateEntry's real {ankiConnect,noteId}
              // (repo.updateMinedNote) to overwrite that note in place. An immediate
              // null here would resolve overwriteTargetNoteId with null (card never
              // promoted, no overwrite affordance) and updateEntry with null
              // (parseMineResult -> overwrite silently did nothing), so app-external
              // overwrite could never work.
              // BUG-1064 -- minedCardAction (the "overwrite which / add duplicate /
              // view" action panel) still stays NON-deferred -> immediate null, for
              // the SAME unchanged reason: it is a Flutter dialog and the main window
              // is backgrounded behind the external app, so it cannot be presented
              // here. What WAS broken is that popup.js took that null as "the host
              // handled it" and did nothing at all, so clicking an already-mined ✓
              // outside the app was visibly DEAD (the user could neither overwrite an
              // older card nor add a duplicate). popup.js now renders the action panel
              // INSIDE its own WebView whenever the host has no native dialog
              // (window.__fushiMinedCardActionNative false), and that panel needs two
              // DEFERRED data bridges: findMinedMatches (repo.findMatchingNotes -> the
              // existing cards) and openMinedNote (repo.openNoteInAnki). Its overwrite
              // / add-duplicate actions reuse the already-deferred updateEntry /
              // mineEntry, so this adds NO new write path.
              // playWordAudio removed from this list: the bridge is dead —
              // popup.js plays the resolved URL itself (see bridge-shim.js) and
              // the Dart handler branch was deleted (it could only fail: a
              // data: URL fed to playAudioRef classifies as a local file).
              const bool deferred =
                  body.find("\"resolveWordAudio\"") != std::string::npos ||
                  body.find("\"queryLocalAudio\"") != std::string::npos ||
                  body.find("\"favoriteEntry\"") != std::string::npos ||
                  body.find("\"favoriteCheck\"") != std::string::npos ||
                  body.find("\"mineEntry\"") != std::string::npos ||
                  body.find("\"duplicateCheck\"") != std::string::npos ||
                  body.find("\"overwriteTargetNoteId\"") != std::string::npos ||
                  body.find("\"updateEntry\"") != std::string::npos ||
                  body.find("\"findMinedMatches\"") != std::string::npos ||
                  body.find("\"openMinedNote\"") != std::string::npos;
              const std::string key = "\"__bridgeId\":";
              size_t pos = body.find(key);
              if (!deferred && pos != std::string::npos) {
                pos += key.size();
                size_t end = pos;
                while (end < body.size() && body[end] >= '0' &&
                       body[end] <= '9') {
                  ++end;
                }
                if (end > pos && webview_) {
                  std::string id = body.substr(pos, end - pos);
                  std::wstring script = L"window.__fushiBridgeResolve && "
                                        L"window.__fushiBridgeResolve(" +
                                        Utf8ToWide(id) + L", null);";
                  webview_->ExecuteScript(script.c_str(), nullptr);
                }
              }
            }
            return S_OK;
          })
          .Get(),
      nullptr);

  // Intercept image:// and dictmedia:// and route the bytes from the main
  // Dart engine (the in-app InAppWebView handles both schemes).
  webview_->AddWebResourceRequestedFilter(
      L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  webview_->add_WebResourceRequested(
      Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [this](ICoreWebView2*,
                 ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
            wil::com_ptr<ICoreWebView2WebResourceRequest> req;
            args->get_Request(&req);
            wil::unique_cotaskmem_string uri;
            req->get_Uri(&uri);
            std::string url = WideToUtf8(uri.get());
            // Route BOTH custom schemes through the main Dart engine, matching
            // the in-app InAppWebView (image:// gaiji/img bytes + dictmedia://
            // dictionary stylesheets). Anything else is a popup asset served by
            // the virtual host.
            const bool is_image = url.rfind("image://", 0) == 0;
            const bool is_dictmedia = url.rfind("dictmedia://", 0) == 0;
            if (!is_image && !is_dictmedia) {
              return S_OK;  // Let the virtual host serve popup assets.
            }
            if (!media_resolver_) {
              return S_OK;
            }
            wil::com_ptr<ICoreWebView2Deferral> deferral;
            args->GetDeferral(&deferral);
            // Keep args + deferral alive until Dart replies. Both this callback
            // and the resolver's reply run on the platform thread, so building
            // the response here is safe.
            wil::com_ptr<ICoreWebView2WebResourceRequestedEventArgs> args_keep =
                args;
            // Content-Type is derived from the URL (scheme/extension) so the
            // overlay serves the SAME type the in-app InAppWebView does — CSS
            // for dictmedia://, image/* by extension for image:// (a hardcoded
            // image/png would make WebView2 reject the dictionary stylesheet).
            std::wstring content_type = MediaContentTypeHeader(url);
            media_resolver_(
                url, [this, deferral, args_keep, content_type](
                         std::vector<uint8_t> bytes) {
                  wil::com_ptr<IStream> stream = SHCreateMemStream(
                      bytes.empty() ? nullptr : bytes.data(),
                      static_cast<UINT>(bytes.size()));
                  wil::com_ptr<ICoreWebView2WebResourceResponse> resp;
                  env_->CreateWebResourceResponse(
                      stream.get(), bytes.empty() ? 404 : 200,
                      bytes.empty() ? L"Not Found" : L"OK",
                      content_type.c_str(), &resp);
                  args_keep->put_Response(resp.get());
                  deferral->Complete();
                });
            return S_OK;
          })
          .Get(),
      nullptr);
}

void GlobalLookupWindow::RenderJson(const std::string& full_script) {
  // full_script is the complete JS built in Dart (settings + lookupEntries +
  // renderPopup), mirroring dictionary_popup_webview._pushResults. Cached until
  // the page finishes loading (renderPopup must exist).
  if (recovering_ || !webview_ready_ || !webview_) {
    pending_json_ = full_script;
    return;
  }
  // TODO-1268 (BUG-693) -- deterministic dead-surface detection. The overlay
  // WebView2 is prewarmed once and lives (hidden) for the whole app session;
  // when its process tree dies mid-session (runtime update, GPU reset, OOM
  // kill, crash) the COM proxies stay alive and webview_ready_ stays TRUE, so
  // this ExecuteScript used to be fired blind into a dead page: the host never
  // posted overlaySize/popupRendered again and every later lookup could only
  // blank-reveal via the Dart READY-SAFETY fallback until app restart -- the
  // TODO-1268 device-log signature (lookupText -> searched -> showAt ->
  // READY-SAFETY, zero host messages). The webview-level ProcessFailed event
  // alone is NOT a reliable trigger for this (a force-killed process tree was
  // observed to raise no event at all in the offscreen harness), so liveness
  // is checked HERE, on the call itself: a FAILED synchronous HRESULT or a
  // FAILED completion HRESULT can only mean an infra-dead surface (JS
  // exceptions still complete with S_OK), and either one triggers
  // RecoverDeadWebView which caches this script and rebuilds the
  // environment/controller/webview; NavigationCompleted then replays it, so
  // the very lookup that DISCOVERS the dead surface still renders a real card.
  const std::string script_copy = full_script;
  HRESULT sync_hr = webview_->ExecuteScript(
      Utf8ToWide(full_script).c_str(),
      Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
          [this, script_copy](HRESULT error_code, LPCWSTR) -> HRESULT {
            if (FAILED(error_code)) {
              ReportOverlayError(
                  "overlay ExecuteScript completed with failure; recovering",
                  error_code);
              RecoverDeadWebView(script_copy);
            }
            return S_OK;
          })
          .Get());
  if (FAILED(sync_hr)) {
    ReportOverlayError("overlay ExecuteScript call failed; recovering",
                       sync_hr);
    RecoverDeadWebView(full_script);
  }
}

// TODO-1268 (BUG-693) -- rebuild a dead overlay WebView2 in place.
//
// [replay_script] is cached into pending_json_ (last-wins, the same contract
// the not-ready path uses) and re-executed by NavigationCompleted once the
// rebuilt surface finishes loading the host document. A burst of failed
// renders (or a ProcessFailed racing the ExecuteScript failure path) triggers
// exactly ONE rebuild via the recovering_ guard; later calls only refresh the
// replay payload. The window itself (hwnd_) survives -- only the WebView2
// environment/controller/webview are torn down and recreated, and
// ConfigureWebView re-registers every handler on the new instance.
void GlobalLookupWindow::RecoverDeadWebView(const std::string& replay_script) {
  if (!replay_script.empty()) {
    pending_json_ = replay_script;
  }
  webview_ready_ = false;
  if (recovering_) {
    return;
  }
  recovering_ = true;
  // The old proxies point into a dead process tree; releasing them is safe.
  controller_ = nullptr;
  webview_ = nullptr;
  env_ = nullptr;
  // 背景逐像素透明：composition controller 也在死进程里，释放它让重建分支重造并
  // 重新 put_RootVisualTarget。hwnd_ 仍活，dcomp target/visual 保留复用（幂等）。
  composition_controller_ = nullptr;
  if (hwnd_ != nullptr) {
    EnsureWebView();
  }
}

void GlobalLookupWindow::ResolveBridge(int64_t id,
                                       const std::string& json_value) {
  if (!webview_) {
    return;
  }
  // json_value is a ready JS string literal (Dart double-encodes it) — the
  // overlay adapter does JSON.parse on it. Splice it in verbatim.
  std::wstring script = L"window.__fushiBridgeResolve && "
                        L"window.__fushiBridgeResolve(" +
                        std::to_wstring(id) + L", " + Utf8ToWide(json_value) +
                        L");";
  webview_->ExecuteScript(script.c_str(), nullptr);
}

LRESULT CALLBACK GlobalLookupWindow::WndProc(HWND hwnd, UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    auto* self = static_cast<GlobalLookupWindow*>(create->lpCreateParams);
    self->hwnd_ = hwnd;
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<GlobalLookupWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMessage(message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

// TODO-867 P2: apply a rounded-rectangle window region so the opaque WebView2
// lookup window has rounded corners that match popup.css's 10px card radius.
// Called on every WM_SIZE. The corner diameter (2 * radius) is scaled by the
// window DPI so the rounding stays a constant ~10 logical px across monitors.
//
// BUG-749 — when the host has reported per-shell rects (transient cascade
// mode), the region is the UNION of those rounded card rects instead of the
// full window. Root cause chain: the TODO-1345 reserved cascade floor makes
// the revealed window span ~the whole work area (so a nested child never
// moves the window = BUG-583 zero-motion); this window is OPAQUE (no
// WS_EX_LAYERED, WebView2 composition), so a full-window region both painted
// a near-fullscreen sheet AND swallowed every click meant for the app below —
// the user's "click the next word in the clipboard panel → the card just
// vanishes and the click is eaten" regression. Clipping the region to the
// real cards keeps the window geometry 100% untouched (zero-motion holds)
// while gap clicks physically pass through to whatever is beneath.
void GlobalLookupWindow::ApplyRoundedRegion() {
  if (hwnd_ == nullptr) {
    return;
  }
  RECT rc;
  GetClientRect(hwnd_, &rc);
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  if (width <= 0 || height <= 0) {
    return;
  }
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi == 0) {
    dpi = 96;
  }
  // 10 logical px radius -> diameter = 20 logical px, scaled to physical px.
  const int diameter = MulDiv(20, static_cast<int>(dpi), 96);
  // Phase C（弹窗尺寸精细化 2026-07-13）— 用户正拖右下角 grip 调整瞬态窗尺寸时，跳过
  // shell 卡矩形裁剪、临时用整窗区域，让窗口可见地随拖拽增长（否则区域钉死在旧卡矩形，
  // 拖拽毫无视觉变化）。WM_EXITSIZEMOVE 结束时 resizing_=false 并重新 ApplyRoundedRegion
  // 复原 shell 裁剪。面板实例 shell_rects_css_ 恒空，本就走整窗区域，此条件对它是 no-op。
  if (!shell_rects_css_.empty() && !resizing_) {
    const double dpr = static_cast<double>(dpi) / 96.0;
    HRGN union_region = CreateRectRgn(0, 0, 0, 0);
    if (union_region != nullptr) {
      bool any = false;
      for (const std::array<double, 4>& r : shell_rects_css_) {
        if (r[2] <= 0 || r[3] <= 0) {
          continue;
        }
        const int l = static_cast<int>(std::floor(r[0] * dpr));
        const int t = static_cast<int>(std::floor(r[1] * dpr));
        const int rt = static_cast<int>(std::ceil((r[0] + r[2]) * dpr));
        const int b = static_cast<int>(std::ceil((r[1] + r[3]) * dpr));
        HRGN shell = CreateRoundRectRgn(l, t, rt + 1, b + 1, diameter, diameter);
        if (shell != nullptr) {
          CombineRgn(union_region, union_region, shell, RGN_OR);
          DeleteObject(shell);
          any = true;
        }
      }
      if (any) {
        // SetWindowRgn takes ownership on success; the system frees it.
        SetWindowRgn(hwnd_, union_region, TRUE);
        return;
      }
      DeleteObject(union_region);
    }
    // Region build failed -> fall through to the full-window region (worse UX,
    // never a missing/garbage region).
  }
  HRGN region =
      CreateRoundRectRgn(0, 0, width + 1, height + 1, diameter, diameter);
  if (region != nullptr) {
    // SetWindowRgn takes ownership of the region on success; the system frees it.
    SetWindowRgn(hwnd_, region, TRUE);
  }
}

// BUG-749 — parse {handler:'shellRects', args:['l,t,w,h;l,t,w,h;…']} (window-
// relative CSS px, numbers only — produced by global_lookup_host.js
// measureAndReport) and re-apply the window region. A malformed payload (or a
// glossary string that merely contains the handler name) parses to zero rects
// and leaves the previous region untouched — degraded, never garbage.
void GlobalLookupWindow::SetShellRectsFromCsv(const std::string& body) {
  const std::string args_marker = "\"args\":[\"";
  const size_t args_at = body.find(args_marker);
  if (args_at == std::string::npos) {
    return;
  }
  const size_t start = args_at + args_marker.size();
  const size_t end = body.find('"', start);
  if (end == std::string::npos || end <= start) {
    return;
  }
  const std::string csv = body.substr(start, end - start);
  std::vector<std::array<double, 4>> rects;
  size_t pos = 0;
  while (pos < csv.size()) {
    size_t next = csv.find(';', pos);
    if (next == std::string::npos) {
      next = csv.size();
    }
    const std::string rect_str = csv.substr(pos, next - pos);
    std::array<double, 4> rect{};
    int idx = 0;
    size_t p = 0;
    bool ok = true;
    while (idx < 4 && p <= rect_str.size()) {
      size_t comma = rect_str.find(',', p);
      if (comma == std::string::npos) {
        comma = rect_str.size();
      }
      try {
        rect[idx] = std::stod(rect_str.substr(p, comma - p));
      } catch (...) {
        ok = false;
        break;
      }
      ++idx;
      p = comma + 1;
    }
    if (ok && idx == 4) {
      rects.push_back(rect);
    }
    pos = next + 1;
  }
  if (rects.empty()) {
    return;
  }
  shell_rects_css_ = std::move(rects);
  ApplyRoundedRegion();
}

void GlobalLookupWindow::ForwardGlobalClickToHost(int screen_x, int screen_y) {
  if (webview_ == nullptr || hwnd_ == nullptr) {
    return;
  }
  RECT rc;
  GetWindowRect(hwnd_, &rc);
  // Screen physical px -> window-local physical px -> host CSS px (÷ dpr). This
  // is the documented "WH_MOUSE_LL physical -> web CSS px" boundary; the host
  // layout math stays in CSS px throughout. Window DPI (96-based) gives dpr.
  UINT dpi = GetDpiForWindow(hwnd_);
  if (dpi == 0) {
    dpi = 96;
  }
  const double dpr = static_cast<double>(dpi) / 96.0;
  const double local_x = static_cast<double>(screen_x - rc.left) / dpr;
  const double local_y = static_cast<double>(screen_y - rc.top) / dpr;
  std::wstring script =
      L"window.__globalLookupHost && "
      L"window.__globalLookupHost.handleGlobalClick(" +
      std::to_wstring(local_x) + L", " + std::to_wstring(local_y) + L");";
  webview_->ExecuteScript(script.c_str(), nullptr);
}

LRESULT GlobalLookupWindow::HandleMessage(UINT message, WPARAM wparam,
                                          LPARAM lparam) {
  switch (message) {
    // BUG-1479 — 显示期间周期性重申置顶。见 ReassertTopmost 的注释：查词卡被
    // galgame 盖住不是独占全屏那条 OS 硬限制（那样 Luna 也会中招），是同一置顶带内
    // 「最后一次 SetWindowPos 的赢」而我们只在 Reveal 设过一次。
    case WM_TIMER:
      if (wparam == kTopmostGuardTimerId) {
        ReassertTopmost();
        return 0;
      }
      // 别的定时器（本类目前没有，但别给未来留坑）交回系统。
      // 这里**不能**写 break：本 switch 每个分支都 return，break 会掉到函数尾部
      // 而没有返回值 —— CI 的 /WX 把 C4715 当错误（本机 debug 构建不开 /WX，
      // 所以本地那次 `flutter build windows --debug` 是绿的，别再被它骗一次）。
      return DefWindowProc(hwnd_, message, wparam, lparam);
    case fushi::kLowLevelMouseClickMessage:
      // BUG-1048 — 钩子线程投递的全局点击（wparam 打包屏幕物理坐标，lparam=是否
      // 落在本窗口 rect 内）。真正的决策（关闭 / 转发给 host）在这里做，钩子线程
      // 只搬坐标：那条线程必须随时能返回，否则整个系统的鼠标输入都跟着它排队。
      HandleGlobalClick(fushi::UnpackMouseHookPoint(wparam), lparam != 0);
      return 0;
    case fushi::kLowLevelMouseWheelMessage:
      // BUG-1166 — 钩子线程已把这一格滚轮从输入流里吞掉（游戏收不到了），这里负责
      // 让卡片照常滚。同样是钩子线程只搬数据、窗口线程做事。
      HandleGlobalWheel(fushi::UnpackMouseHookPoint(wparam),
                        fushi::UnpackMouseHookWheel(lparam));
      return 0;
    case WM_SIZE:
      if (controller_) {
        RECT rc;
        GetClientRect(hwnd_, &rc);
        controller_->put_Bounds(rc);
      }
      // 背景逐像素透明（composition）：put_Bounds 后必须 Commit 才把新尺寸的透明帧
      // 推上桌面；且**不**设窗口 region——逐像素透明已让圆角/卡间隙靠 CSS 呈现，
      // 一个不透明的窗口 region 会硬裁并吞掉透明区（游戏区）的点击。windowed 瞬态
      // 窗保持原有 ApplyRoundedRegion（非 layered，圆角只能靠 region）。
      if (composition_active_) {
        if (dcomp_device_ != nullptr) {
          dcomp_device_->Commit();
        }
        return 0;
      }
      // TODO-867 P2: round the actual window corners to match popup.css's hoshi
      // card radius. The window is opaque (no WS_EX_LAYERED — it conflicts with
      // WebView2's composition surface, see ShowAt), so true rounded corners must
      // come from a window region, not CSS. A real drop-shadow is not achievable
      // on a non-layered topmost window — that is a platform limitation; the CSS
      // border supplies the card frame, this region supplies the rounded corners.
      ApplyRoundedRegion();
      return 0;
    case WM_DPICHANGED: {
      // BUG-1104 — 窗口被拖到另一块缩放不同的显示器（或用户改了缩放）。
      //
      // 两条创建路径都关掉了 WebView2 的自动 monitor-scale 探测（理由见
      // ApplyDpiScale），所以跟随 DPI 变化是**我们的**责任；不处理的话光栅缩放
      // 会永远停在建窗那一刻所在的那块屏上——而这个窗是开机预热、整个 app 会话
      // 只隐藏不销毁的长命窗口，"建窗那一刻" 可能是几小时前的事。
      //
      // lparam 是系统按新 DPI 算好的建议矩形，照单全收是官方契约（窗口的物理
      // 观感大小不变）。SWP_NOZORDER | SWP_NOACTIVATE 保证不动 Z 序、不抢焦点；
      // 且不带任何“显示窗口”标志，所以预热期的隐藏窗口不会凭空出现在桌面上
      // （守卫 global_lookup_dpi_scale_guard_test.dart ③ 就是盯这一点）。
      const RECT* suggested = reinterpret_cast<const RECT*>(lparam);
      if (suggested != nullptr && hwnd_ != nullptr) {
        SetWindowPos(hwnd_, nullptr, suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
      }
      ApplyDpiScale();
      // 上面的 SetWindowPos 若真改了尺寸会触发 WM_SIZE 走同样的收尾；尺寸没变时
      // 不会，所以这里显式再收一次（幂等）。
      if (controller_) {
        RECT rc;
        GetClientRect(hwnd_, &rc);
        controller_->put_Bounds(rc);
      }
      if (composition_active_) {
        if (dcomp_device_ != nullptr) {
          dcomp_device_->Commit();
        }
      } else {
        // 圆角区域的直径按 DPI 算（ApplyRoundedRegion），换屏必须重算。
        ApplyRoundedRegion();
      }
      return 0;
    }
    case WM_ENTERSIZEMOVE:
      // Phase C（弹窗尺寸精细化 2026-07-13）— 进入模态 move/size 循环（面板拖动/调整，
      // 或 —— Phase C 起 —— 瞬态覆盖窗拖右下角 grip）。瞬态窗平时按 shell 卡矩形裁剪
      // 窗口区域，裁剪区不随窗口增大 → 拖拽看不到窗口变大；置 resizing_ 并立即重算区域，
      // 拖拽期间改用整窗区域（见 ApplyRoundedRegion）。面板实例区域本就是整窗，此为 no-op。
      resizing_ = true;
      // Phase C（2026-07-14）— 记下拖拽起始的真实窗口物理尺寸；WM_EXITSIZEMOVE 一并回报，
      // Dart 用「结束−起始」增量折算（抵消恒定级联余量）。GetWindowRect 是拖拽前实际尺寸，
      // 比 Dart 侧 last-sent（可能被 clamp）可靠。
      if (hwnd_ != nullptr) {
        RECT sr{};
        if (GetWindowRect(hwnd_, &sr)) {
          resize_start_w_ = sr.right - sr.left;
          resize_start_h_ = sr.bottom - sr.top;
        }
      }
      ApplyRoundedRegion();
      return 0;
    case WM_EXITSIZEMOVE: {
      // 模态 move/size 循环结束（面板拖动/调整，或 Phase C 起的瞬态覆盖窗拖角 resize）：
      // 回报最终窗口 rect（物理 px）供 Dart 持久化。同一 windowMoved 通道，两实例各自的
      // message_cb_ 落不同真值——面板落 clipboardPanelRect，瞬态窗落 overlay 尺寸键（Dart
      // 侧按实例区分去向，见各自 controller 的 _onJsMessage / windowMoved 分支）。
      // Phase C — 先复原 resize 期间临时挂起的 shell 区域裁剪（resizing_ 归零后重算）。
      resizing_ = false;
      ApplyRoundedRegion();
      if (message_cb_ && hwnd_ != nullptr) {
        RECT r{};
        GetWindowRect(hwnd_, &r);
        // Phase C（2026-07-14）— 追加拖拽起始尺寸 [startW, startH]，Dart 用「结束−起始」
        // 增量折算 overlay 尺寸（面板实例读 [0..3] 绝对 rect，忽略 [4][5]，向后兼容）。
        const std::string body =
            std::string("{\"handler\":\"windowMoved\",\"args\":[") +
            std::to_string(r.left) + "," + std::to_string(r.top) + "," +
            std::to_string(r.right - r.left) + "," +
            std::to_string(r.bottom - r.top) + "," +
            std::to_string(resize_start_w_) + "," +
            std::to_string(resize_start_h_) + "]}";
        message_cb_(body, RouteForMessage(body));
      }
      return 0;
    }
    // 背景逐像素透明（composition）— 无子 HWND，客户区鼠标消息直达本窗，转发给
    // composition controller（否则透明面板点不动/滚不动）。windowed 瞬态窗
    // composition_active_=false，落 default→DefWindowProc（子窗自动收输入，行为不变）。
    case WM_MOUSEMOVE:
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
      if (composition_active_) {
        if (message == WM_MOUSEMOVE) {
          // 追踪离开事件（hover-reveal / 悬停状态需要 mouseleave）。
          TRACKMOUSEEVENT tme{sizeof(TRACKMOUSEEVENT), TME_LEAVE, hwnd_, 0};
          TrackMouseEvent(&tme);
        }
        ForwardCompositionMouse(message, wparam, lparam);
        return 0;
      }
      return DefWindowProc(hwnd_, message, wparam, lparam);
    case WM_MOUSELEAVE:
      if (composition_active_ && composition_controller_ != nullptr) {
        POINT pt{0, 0};
        composition_controller_->SendMouseInput(
            COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE,
            COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE, 0, pt);
        return 0;
      }
      return DefWindowProc(hwnd_, message, wparam, lparam);
    case WM_SETCURSOR:
      // composition 无子窗托管光标：客户区内用 WebView2 请求的光标形状。
      if (composition_active_ && LOWORD(lparam) == HTCLIENT &&
          composition_cursor_ != nullptr) {
        SetCursor(composition_cursor_);
        return TRUE;
      }
      return DefWindowProc(hwnd_, message, wparam, lparam);
    // WM_TIMER 只有 kTopmostGuardTimerId 由本窗口消费；其它 timer 和一切未处理
    // 消息都从这里继续走默认窗口过程。这条 default 已覆盖 switch 的全部剩余路径，
    // 所以函数不存在 C4715 无返回路径——switch 之后**不要**再补一条兜底 return，
    // 那条永远到不了，CI 的 /WX 会把 C4702 unreachable code 直接判成错误。
    default:
      return DefWindowProc(hwnd_, message, wparam, lparam);
  }
}
