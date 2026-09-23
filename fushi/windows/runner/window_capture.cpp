#include "window_capture.h"

#include <windows.h>

#include <dwmapi.h>
#include <d3d11.h>
#include <dxgi.h>
#include <shellapi.h>
#include <wincodec.h>
#include <shlwapi.h>

#include <wrl/client.h>
#include <wrl/event.h>

#include <windows.foundation.h>
#include <windows.graphics.h>
#include <windows.graphics.capture.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.h>
#include <windows.graphics.directx.direct3d11.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include "wgc_interop.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <limits>

namespace fushi {

namespace {

// Bound each BGRA frame before allocating the WGC pool or CPU staging copy.
// The Dart calibration boundary uses the same 32-megapixel image limit.
constexpr bool CaptureSizeWithinBudget(uint64_t width, uint64_t height) {
  constexpr uint64_t kMaximumFrameBytes = 128ULL * 1024 * 1024;
  return width > 0 && height > 0 &&
         width <= (kMaximumFrameBytes / 4) / height;
}
static_assert(CaptureSizeWithinBudget(7680, 4320));
static_assert(!CaptureSizeWithinBudget(0, 1080));
static_assert(!CaptureSizeWithinBudget(65536, 65536));
static_assert(!CaptureSizeWithinBudget(UINT64_MAX, UINT64_MAX));

}  // namespace

bool ReadPhysicalClientScreenRect(HWND hwnd, RECT* rect) {
  if (rect == nullptr) {
    return false;
  }
  *rect = RECT{};
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    return false;
  }
  WINDOWINFO info{};
  info.cbSize = sizeof(info);
  if (!GetWindowInfo(hwnd, &info) ||
      info.rcClient.right <= info.rcClient.left ||
      info.rcClient.bottom <= info.rcClient.top) {
    return false;
  }
  *rect = info.rcClient;
  return true;
}

namespace {

bool ReadCaptureClient(HWND hwnd, WindowCaptureMetadata* metadata) {
  RECT client{};
  if (!metadata || IsIconic(hwnd) ||
      !ReadPhysicalClientScreenRect(hwnd, &client)) {
    return false;
  }
  DWORD pid = 0;
  if (!GetWindowThreadProcessId(hwnd, &pid) || pid == 0) {
    return false;
  }
  const UINT dpi = GetDpiForWindow(hwnd);
  if (dpi == 0) return false;
  metadata->captured_hwnd = reinterpret_cast<int64_t>(hwnd);
  metadata->captured_pid = pid;
  metadata->client_left_px = client.left;
  metadata->client_top_px = client.top;
  metadata->client_width_px = client.right - client.left;
  metadata->client_height_px = client.bottom - client.top;
  metadata->dpi = dpi;
  return true;
}

bool SameCaptureClient(const WindowCaptureMetadata& a,
                       const WindowCaptureMetadata& b) {
  return a.captured_hwnd == b.captured_hwnd &&
         a.captured_pid == b.captured_pid &&
         a.client_left_px == b.client_left_px &&
         a.client_top_px == b.client_top_px &&
         a.client_width_px == b.client_width_px &&
         a.client_height_px == b.client_height_px && a.dpi == b.dpi;
}

bool RectHasArea(const RECT& rect) {
  return rect.right > rect.left && rect.bottom > rect.top;
}

bool RectWithin(const RECT& inner, const RECT& outer) {
  return RectHasArea(inner) && RectHasArea(outer) &&
         inner.left >= outer.left && inner.top >= outer.top &&
         inner.right <= outer.right && inner.bottom <= outer.bottom;
}

bool SameRect(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

int RectWidth(const RECT& rect) {
  return rect.right > rect.left ? rect.right - rect.left : 0;
}

int RectHeight(const RECT& rect) {
  return rect.bottom > rect.top ? rect.bottom - rect.top : 0;
}

uint32_t ReadWindowPid(HWND hwnd) {
  DWORD pid = 0;
  if (hwnd != nullptr) {
    GetWindowThreadProcessId(hwnd, &pid);
  }
  return static_cast<uint32_t>(pid);
}

void SetRectMetadata(const RECT& source_rect, const RECT& destination_rect,
                     WindowCaptureMetadata* metadata) {
  if (metadata == nullptr) {
    return;
  }
  metadata->source_viewport_left_px = source_rect.left;
  metadata->source_viewport_top_px = source_rect.top;
  metadata->source_viewport_width_px = RectWidth(source_rect);
  metadata->source_viewport_height_px = RectHeight(source_rect);
  metadata->destination_viewport_left_px = destination_rect.left;
  metadata->destination_viewport_top_px = destination_rect.top;
  metadata->destination_viewport_width_px = RectWidth(destination_rect);
  metadata->destination_viewport_height_px = RectHeight(destination_rect);
}

void SetCaptureProvenance(WindowCaptureMetadata* metadata, HWND captured_hwnd,
                          HWND source_hwnd,
                          const MagpiePresentationMapping* mapping) {
  if (metadata == nullptr) {
    return;
  }
  if (source_hwnd == nullptr) {
    source_hwnd = captured_hwnd;
  }
  metadata->source_hwnd = reinterpret_cast<int64_t>(source_hwnd);
  metadata->source_pid = ReadWindowPid(source_hwnd);
  metadata->presentation_hwnd = reinterpret_cast<int64_t>(captured_hwnd);
  metadata->presentation_pid = ReadWindowPid(captured_hwnd);
  metadata->used_presentation_capture = mapping != nullptr;
  metadata->presentation_viewport_complete = false;

  WindowCaptureMetadata source_client;
  if (ReadCaptureClient(source_hwnd, &source_client)) {
    metadata->source_client_left_px = source_client.client_left_px;
    metadata->source_client_top_px = source_client.client_top_px;
    metadata->source_client_width_px = source_client.client_width_px;
    metadata->source_client_height_px = source_client.client_height_px;
    metadata->source_client_dpi = static_cast<int>(source_client.dpi);
  }

  RECT source_rect{};
  RECT destination_rect{};
  if (mapping != nullptr) {
    source_rect = mapping->source_rect_screen;
    destination_rect = mapping->destination_rect_screen;
  } else {
    source_rect.left = metadata->client_left_px;
    source_rect.top = metadata->client_top_px;
    source_rect.right = source_rect.left + metadata->client_width_px;
    source_rect.bottom = source_rect.top + metadata->client_height_px;
    destination_rect = source_rect;
  }
  SetRectMetadata(source_rect, destination_rect, metadata);
}

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Callback;
namespace WGC = ABI::Windows::Graphics::Capture;
namespace WGDX = ABI::Windows::Graphics::DirectX;
namespace WGDXD3D = ABI::Windows::Graphics::DirectX::Direct3D11;

using wgc::GetActivationFactory;
using wgc::IDxgiInterfaceAccessLocal;
using wgc::CloseIfClosable;

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) {
    return std::string();
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, w.data(),
                                 static_cast<int>(w.size()), nullptr, 0,
                                 nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

// BUG-1096：把一次「成功但值得记录」的事实追加进 diagnostics（多条以 "; " 相连）。
// [hr] 为 S_OK 时不附 HRESULT（纯陈述），否则附十六进制码。
void AppendDiagnostic(WindowCaptureResult* out, const char* note, HRESULT hr) {
  if (out == nullptr || note == nullptr) {
    return;
  }
  std::string line = note;
  if (hr != S_OK) {
    char hr_buf[16];
    _snprintf_s(hr_buf, sizeof(hr_buf), _TRUNCATE, "0x%08lX",
                static_cast<unsigned long>(hr));
    line += " hr=";
    line += hr_buf;
  }
  if (!out->diagnostics.empty()) {
    out->diagnostics += "; ";
  }
  out->diagnostics += line;
}

// Keep the capture reason bounded and machine-readable. The human-readable
// error remains useful to the immediate caller, but must not be persisted into
// calibration diagnostics.
void SetCaptureFailure(WindowCaptureResult* out, const char* reason,
                       const char* error) {
  if (out == nullptr) {
    return;
  }
  out->capture_reason = reason == nullptr ? "capture_failed" : reason;
  out->error = error == nullptr ? "capture failed" : error;
}

void SetCaptureReason(WindowCaptureResult* out, const char* reason) {
  if (out != nullptr && reason != nullptr) {
    out->capture_reason = reason;
  }
}

}  // namespace

// BUG-1854：把 WGC 整窗纹理裁到窗口**客户区**。
//
// `CreateForWindow` 拿到的 item 覆盖窗口的整个 DWM 视觉（= DWMWA_EXTENDED_FRAME_BOUNDS），
// 标题栏 / 菜单栏 / 边框全在里面，窗口化跑的 galgame 制卡必然把标题栏拍进卡片。
// 裁剪原点 = 客户区屏幕原点（WINDOWINFO.rcClient）− 扩展框架原点：不能用 GetWindowRect
// 的 left/top，Win10+ 的不可见 resize 边框会让它比 DWM 视觉原点偏出几像素（OBS 的
// 「Client Area」选项是同一套算法）。
//
// **不要把 GetClientRect 的逻辑宽高加到屏幕原点上**。老 galgame 大量是
// DPI-unaware 进程，在缩放屏上跨 DPI 的两个 ClientToScreen 端点可能独立舍入，
// 使屏幕空间的右边少几个像素；GetWindowInfo.rcClient 一次返回完整的屏幕矩形。
//
// 返回 true 时 [box] 是 [width]×[height] 纹理内的一个非空子矩形（已与纹理求交）；
// 任何一步失败（窗口最小化 / API 失败 / 退化成空矩形）返回 false，调用方回退整窗——
// 宁可多一条标题栏，也不能因为裁剪把卡片图弄丢。
bool ComputeClientCropBox(HWND hwnd, UINT width, UINT height, RECT* box) {
  if (hwnd == nullptr || box == nullptr || width == 0 || height == 0) {
    return false;
  }
  RECT client{};
  RECT frame{};
  if (!ReadPhysicalClientScreenRect(hwnd, &client) ||
      FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &frame,
                                   sizeof(frame)))) {
    return false;
  }
  const LONG left = std::max<LONG>(0, client.left - frame.left);
  const LONG top = std::max<LONG>(0, client.top - frame.top);
  if (left >= static_cast<LONG>(width) || top >= static_cast<LONG>(height)) {
    return false;
  }
  const LONG right =
      std::min<LONG>(static_cast<LONG>(width), client.right - frame.left);
  const LONG bottom =
      std::min<LONG>(static_cast<LONG>(height), client.bottom - frame.top);
  if (right <= left || bottom <= top) {
    return false;
  }
  box->left = left;
  box->top = top;
  box->right = right;
  box->bottom = bottom;
  return true;
}

// Convert a screen-space Magpie viewport into the WGC texture's coordinates.
// Magpie publishes physical screen pixels, while CreateForWindow starts at
// the DWM extended frame.  The caller must still verify that the returned box
// was not clipped and that its dimensions equal the published destination
// viewport; this helper only computes the intersection with the texture.
bool ComputeScreenCropBox(HWND hwnd, const RECT& screen_rect, UINT width,
                          UINT height, RECT* box) {
  if (hwnd == nullptr || box == nullptr || width == 0 || height == 0 ||
      !RectHasArea(screen_rect)) {
    return false;
  }
  RECT frame{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &frame,
                                   sizeof(frame)))) {
    return false;
  }
  const LONG left = std::max<LONG>(0, screen_rect.left - frame.left);
  const LONG top = std::max<LONG>(0, screen_rect.top - frame.top);
  if (left >= static_cast<LONG>(width) || top >= static_cast<LONG>(height)) {
    return false;
  }
  const LONG right = std::min<LONG>(static_cast<LONG>(width),
                                    screen_rect.right - frame.left);
  const LONG bottom = std::min<LONG>(static_cast<LONG>(height),
                                     screen_rect.bottom - frame.top);
  if (right <= left || bottom <= top) {
    return false;
  }
  box->left = left;
  box->top = top;
  box->right = right;
  box->bottom = bottom;
  return true;
}

namespace {

// 读窗口标题（无标题返回空串）。
std::wstring ReadWindowTitle(HWND hwnd) {
  const int len = GetWindowTextLengthW(hwnd);
  if (len <= 0) {
    return std::wstring();
  }
  std::wstring title(static_cast<size_t>(len) + 1, L'\0');
  const int got = GetWindowTextW(hwnd, title.data(), len + 1);
  title.resize(got > 0 ? static_cast<size_t>(got) : 0);
  return title;
}

struct EnumContext {
  HWND self;
  std::vector<ExternalWindow>* out;
};

BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<EnumContext*>(lparam);
  if (hwnd == ctx->self || !IsWindowVisible(hwnd)) {
    return TRUE;
  }
  // 跳过 cloaked 窗口（UWP 挂起 / 其它虚拟桌面的隐藏窗口）。
  BOOL cloaked = FALSE;
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                      sizeof(cloaked))) &&
      cloaked) {
    return TRUE;
  }
  // 跳过工具窗口（浮动工具条等，非用户内容窗口）。
  const LONG ex_style = GetWindowLong(hwnd, GWL_EXSTYLE);
  if (ex_style & WS_EX_TOOLWINDOW) {
    return TRUE;
  }
  std::wstring title = ReadWindowTitle(hwnd);
  if (title.empty()) {
    return TRUE;
  }
  // BUG-1096：Magpie 缩放窗口在这里就换成它正在缩放的**源窗口**——否则用户选中的
  // 是「游戏画面 + Magpie 补画的第二个光标」那一层，PID 也是 Magpie.exe 而不是游戏
  // （voice hook 的注入目标同样会错）。拿不到属性时保持原窗口不变。
  HWND target = hwnd;
  if (const HWND source = ResolveScalingSourceWindow(hwnd)) {
    target = source;
    std::wstring source_title = ReadWindowTitle(source);
    if (!source_title.empty()) {
      title = std::move(source_title);
    }
  }
  // 重定向后可能与单独枚举到的源窗口重合（Z 序谁先到都可能），按 hwnd 去重。
  for (const ExternalWindow& existing : *ctx->out) {
    if (existing.hwnd == target) {
      return TRUE;
    }
  }
  ExternalWindow w;
  w.hwnd = target;
  w.title = WideToUtf8(title);
  // 所属进程 PID（供 galgame 引擎级 voice hook 注入目标；纯读，不改窗口）。
  GetWindowThreadProcessId(target, &w.pid);
  ctx->out->push_back(std::move(w));
  return TRUE;
}

// BGRA 像素缓冲 -> PNG 字节（WIC）。stride 为源每行字节数（可含行尾 padding）。
std::vector<uint8_t> EncodeBgraToPng(const uint8_t* pixels, UINT width,
                                     UINT height, UINT stride,
                                     std::string* error) {
  std::vector<uint8_t> result;
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    *error = "WIC factory create failed";
    return result;
  }
  ComPtr<IStream> stream;
  stream.Attach(SHCreateMemStream(nullptr, 0));
  if (!stream) {
    *error = "memory stream alloc failed";
    return result;
  }
  ComPtr<IWICBitmapEncoder> encoder;
  hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(hr)) {
    hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  }
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  if (SUCCEEDED(hr)) {
    hr = encoder->CreateNewFrame(&frame, &props);
  }
  if (SUCCEEDED(hr)) {
    hr = frame->Initialize(props.Get());
  }
  if (SUCCEEDED(hr)) {
    hr = frame->SetSize(width, height);
  }
  WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(hr)) {
    hr = frame->SetPixelFormat(&fmt);
  }
  if (SUCCEEDED(hr)) {
    const UINT buf_size = stride * height;
    hr = frame->WritePixels(height, stride, buf_size,
                            const_cast<BYTE*>(pixels));
  }
  if (SUCCEEDED(hr)) {
    hr = frame->Commit();
  }
  if (SUCCEEDED(hr)) {
    hr = encoder->Commit();
  }
  if (FAILED(hr)) {
    *error = "PNG encode failed";
    return result;
  }
  // 把内存流回读进 vector。
  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) {
    *error = "stream stat failed";
    return result;
  }
  const ULONG size = static_cast<ULONG>(stat.cbSize.QuadPart);
  LARGE_INTEGER zero = {};
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  result.resize(size);
  ULONG read = 0;
  if (size > 0 && FAILED(stream->Read(result.data(), size, &read))) {
    *error = "stream read failed";
    result.clear();
    return result;
  }
  result.resize(read);
  return result;
}

constexpr UINT kPrintWindowTimeoutMs = 750;
constexpr UINT kPrintWindowHelperExitGraceMs = 500;
constexpr wchar_t kPrintWindowHelperSwitch[] =
    L"--fushi-print-window-helper";
constexpr uint32_t kPrintWindowHelperMagic = 0x46505748u;
constexpr uint32_t kPrintWindowHelperVersion = 1u;
std::atomic<bool> g_print_window_worker_busy{false};

enum class PrintWindowWorkerStatus {
  kPending,
  kComUnavailable,
  kDcCreateFailed,
  kDibCreateFailed,
  kDibSelectFailed,
  kPrintFailed,
  kNoPixels,
  kPartialPixels,
  kBlackPixels,
  kTransparentPixels,
  kClientChanged,
  kPngEncodeFailed,
  kHelperProtocolFailed,
  kComplete,
};

// This is the only data crossing the helper boundary. The mapping contains a
// fixed header followed by one bounded BGRA buffer; it never contains a C++
// container, a GDI handle, or a pointer into either process.
struct PrintWindowHelperSharedState {
  uint32_t magic = 0;
  uint32_t version = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t stride = 0;
  uint32_t reserved = 0;
  uint64_t pixel_bytes = 0;
  volatile LONG status =
      static_cast<LONG>(PrintWindowWorkerStatus::kPending);
  volatile LONG failure_hr = static_cast<LONG>(S_OK);
  WindowCaptureMetadata initial_client;
  WindowCaptureMetadata final_client;
};

class ScopedWinHandle {
 public:
  ScopedWinHandle() = default;
  explicit ScopedWinHandle(HANDLE handle) : handle_(handle) {}
  ScopedWinHandle(const ScopedWinHandle&) = delete;
  ScopedWinHandle& operator=(const ScopedWinHandle&) = delete;
  ~ScopedWinHandle() { reset(); }

  HANDLE get() const { return handle_; }
  explicit operator bool() const {
    return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
  }

  void reset(HANDLE handle = nullptr) {
    if (*this) {
      CloseHandle(handle_);
    }
    handle_ = handle;
  }

 private:
  HANDLE handle_ = nullptr;
};

class ScopedMappedView {
 public:
  explicit ScopedMappedView(void* view) : view_(view) {}
  ScopedMappedView(const ScopedMappedView&) = delete;
  ScopedMappedView& operator=(const ScopedMappedView&) = delete;
  ~ScopedMappedView() {
    if (view_ != nullptr) {
      UnmapViewOfFile(view_);
    }
  }

  void* get() const { return view_; }
  explicit operator bool() const { return view_ != nullptr; }

 private:
  void* view_ = nullptr;
};

struct PrintWindowBusyGuard {
  ~PrintWindowBusyGuard() {
    g_print_window_worker_busy.store(false, std::memory_order_release);
  }
};

struct PrintWindowGdiResources {
  HDC dc = nullptr;
  HBITMAP dib = nullptr;
  HGDIOBJ previous = nullptr;
  void* bits = nullptr;

  void ReleaseGdiOnOwnerThread() {
    if (dc != nullptr && previous != nullptr && previous != HGDI_ERROR) {
      SelectObject(dc, previous);
    }
    previous = nullptr;
    if (dib != nullptr) {
      DeleteObject(dib);
    }
    dib = nullptr;
    bits = nullptr;
    if (dc != nullptr) {
      DeleteDC(dc);
    }
    dc = nullptr;
  }

  ~PrintWindowGdiResources() { ReleaseGdiOnOwnerThread(); }
};

HRESULT LastWin32ErrorAsHresult() {
  const DWORD error = GetLastError();
  return error == ERROR_SUCCESS ? E_FAIL : HRESULT_FROM_WIN32(error);
}

// WGC cannot create an item for some composition-only windows. PrintWindow is
// a bounded compatibility path for that narrow case. It must never become a
// generic screen/window fallback: the target must be visible and unprotected,
// and must remain geometrically stable.
void SignalPrintWindowHelper(PrintWindowHelperSharedState* state,
                             PrintWindowWorkerStatus status, HRESULT hr,
                             HANDLE completed) {
  if (state != nullptr) {
    state->failure_hr = static_cast<LONG>(hr);
    ::InterlockedExchange(&state->status, static_cast<LONG>(status));
  }
  if (completed != nullptr) {
    SetEvent(completed);
  }
}

bool VerifyPrintWindowTarget(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd) || !IsWindowVisible(hwnd) ||
      IsIconic(hwnd)) {
    return false;
  }
  BOOL cloaked = FALSE;
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                   sizeof(cloaked))) ||
      cloaked) {
    return false;
  }
  DWORD affinity = WDA_NONE;
  if (!GetWindowDisplayAffinity(hwnd, &affinity) || affinity != WDA_NONE) {
    return false;
  }
  return true;
}

PrintWindowWorkerStatus ValidatePrintWindowPixels(uint8_t* bytes,
                                                  size_t buffer_size,
                                                  UINT width, UINT height) {
  size_t untouched_pixels = 0;
  bool has_non_black_rgb = false;
  bool has_nonzero_alpha = false;
  for (size_t i = 0; i < buffer_size; i += 4) {
    const bool unchanged =
        bytes[i] == static_cast<uint8_t>(0xA5u ^ (i & 0x3Fu)) &&
        bytes[i + 1] == static_cast<uint8_t>(0xA5u ^ ((i + 1) & 0x3Fu)) &&
        bytes[i + 2] == static_cast<uint8_t>(0xA5u ^ ((i + 2) & 0x3Fu)) &&
        bytes[i + 3] == static_cast<uint8_t>(0xA5u ^ ((i + 3) & 0x3Fu));
    if (unchanged) {
      ++untouched_pixels;
    }
    if (bytes[i] != 0 || bytes[i + 1] != 0 || bytes[i + 2] != 0) {
      has_non_black_rgb = true;
    }
    if (bytes[i + 3] != 0) {
      has_nonzero_alpha = true;
    }
    // A 32bpp BI_RGB DIB does not promise meaningful alpha. A captured game
    // client is opaque, so normalize it before handing pixels to WIC.
    bytes[i + 3] = 0xFF;
  }
  const size_t pixel_count = static_cast<size_t>(width) * height;
  if (untouched_pixels == pixel_count) {
    return PrintWindowWorkerStatus::kNoPixels;
  }
  if (untouched_pixels != 0) {
    return PrintWindowWorkerStatus::kPartialPixels;
  }
  if (!has_non_black_rgb) {
    // A BI_RGB DIB may leave alpha at zero even after a visible WM_PRINT.
    // Treat an all-black RGB frame as unusable; distinguish an explicitly
    // zero-alpha black frame from a non-transparent black frame in logs.
    return has_nonzero_alpha ? PrintWindowWorkerStatus::kBlackPixels
                             : PrintWindowWorkerStatus::kTransparentPixels;
  }
  return PrintWindowWorkerStatus::kComplete;
}

bool ParsePointerArgument(const wchar_t* value, ULONG_PTR* parsed) {
  if (value == nullptr || parsed == nullptr || value[0] == L'\0') {
    return false;
  }
  errno = 0;
  wchar_t* end = nullptr;
  const unsigned long long number = std::wcstoull(value, &end, 10);
  if (errno == ERANGE || end == value || end == nullptr || *end != L'\0') {
    return false;
  }
  const unsigned long long maximum = static_cast<unsigned long long>(
      (std::numeric_limits<ULONG_PTR>::max)());
  if (number == 0 || number > maximum) {
    return false;
  }
  *parsed = static_cast<ULONG_PTR>(number);
  return true;
}

std::wstring PointerArgument(ULONG_PTR value) {
  return std::to_wstring(static_cast<unsigned long long>(value));
}

int RunPrintWindowHelperFromCommandLine() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return -1;
  }
  const bool helper_mode = argc > 1 &&
                           wcscmp(argv[1], kPrintWindowHelperSwitch) == 0;
  if (!helper_mode) {
    LocalFree(argv);
    return -1;
  }
  ULONG_PTR target_value = 0;
  ULONG_PTR mapping_value = 0;
  ULONG_PTR event_value = 0;
  const bool valid_arguments =
      argc == 5 && ParsePointerArgument(argv[2], &target_value) &&
      ParsePointerArgument(argv[3], &mapping_value) &&
      ParsePointerArgument(argv[4], &event_value);
  LocalFree(argv);
  if (!valid_arguments) {
    return EXIT_FAILURE;
  }

  const HWND hwnd = reinterpret_cast<HWND>(target_value);
  ScopedWinHandle mapping(reinterpret_cast<HANDLE>(mapping_value));
  ScopedWinHandle completed(reinterpret_cast<HANDLE>(event_value));
  ScopedMappedView shared_view(MapViewOfFile(mapping.get(),
                                             FILE_MAP_READ | FILE_MAP_WRITE, 0,
                                             0, 0));
  if (!shared_view) {
    SetEvent(completed.get());
    return EXIT_FAILURE;
  }
  auto* state = static_cast<PrintWindowHelperSharedState*>(shared_view.get());
  if (state->magic != kPrintWindowHelperMagic ||
      state->version != kPrintWindowHelperVersion || state->width == 0 ||
      state->height == 0 ||
      !CaptureSizeWithinBudget(state->width, state->height) ||
      state->stride != state->width * 4u ||
      state->pixel_bytes != static_cast<uint64_t>(state->stride) *
                                state->height) {
    SignalPrintWindowHelper(state, PrintWindowWorkerStatus::kHelperProtocolFailed,
                             E_INVALIDARG, completed.get());
    return EXIT_FAILURE;
  }
  if (!VerifyPrintWindowTarget(hwnd)) {
    SignalPrintWindowHelper(state, PrintWindowWorkerStatus::kClientChanged,
                             S_OK, completed.get());
    return EXIT_FAILURE;
  }
  WindowCaptureMetadata current_client;
  if (!ReadCaptureClient(hwnd, &current_client) ||
      !SameCaptureClient(state->initial_client, current_client)) {
    SignalPrintWindowHelper(state, PrintWindowWorkerStatus::kClientChanged,
                             S_OK, completed.get());
    return EXIT_FAILURE;
  }

  const UINT width = state->width;
  const UINT height = state->height;
  const size_t buffer_size = static_cast<size_t>(state->pixel_bytes);
  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = static_cast<LONG>(width);
  bitmap_info.bmiHeader.biHeight = -static_cast<LONG>(height);
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  PrintWindowGdiResources resources;
  auto finish = [&](PrintWindowWorkerStatus status, HRESULT hr) {
    resources.ReleaseGdiOnOwnerThread();
    SignalPrintWindowHelper(state, status, hr, completed.get());
  };
  resources.dc = CreateCompatibleDC(nullptr);
  if (resources.dc == nullptr) {
    finish(PrintWindowWorkerStatus::kDcCreateFailed,
           LastWin32ErrorAsHresult());
    return EXIT_FAILURE;
  }
  resources.dib = CreateDIBSection(resources.dc, &bitmap_info, DIB_RGB_COLORS,
                                   &resources.bits, nullptr, 0);
  if (resources.dib == nullptr || resources.bits == nullptr) {
    finish(PrintWindowWorkerStatus::kDibCreateFailed,
           LastWin32ErrorAsHresult());
    return EXIT_FAILURE;
  }
  resources.previous = SelectObject(resources.dc, resources.dib);
  if (resources.previous == nullptr || resources.previous == HGDI_ERROR) {
    finish(PrintWindowWorkerStatus::kDibSelectFailed,
           LastWin32ErrorAsHresult());
    return EXIT_FAILURE;
  }

  uint8_t* bytes = static_cast<uint8_t*>(resources.bits);
  for (size_t i = 0; i < buffer_size; ++i) {
    bytes[i] = static_cast<uint8_t>(0xA5u ^ (i & 0x3Fu));
  }
  SetLastError(ERROR_SUCCESS);
  if (!PrintWindow(hwnd, resources.dc, PW_CLIENTONLY | PW_RENDERFULLCONTENT)) {
    finish(PrintWindowWorkerStatus::kPrintFailed, LastWin32ErrorAsHresult());
    return EXIT_FAILURE;
  }
  GdiFlush();
  uint8_t* shared_pixels = reinterpret_cast<uint8_t*>(state) +
                           sizeof(PrintWindowHelperSharedState);
  std::memcpy(shared_pixels, bytes, buffer_size);
  WindowCaptureMetadata final_client;
  if (!ReadCaptureClient(hwnd, &final_client) ||
      !SameCaptureClient(state->initial_client, final_client)) {
    finish(PrintWindowWorkerStatus::kClientChanged, S_OK);
    return EXIT_FAILURE;
  }
  state->final_client = final_client;
  finish(PrintWindowWorkerStatus::kComplete, S_OK);
  return EXIT_SUCCESS;
}

void TerminatePrintWindowHelper(HANDLE job, HANDLE process) {
  if (job != nullptr && job != INVALID_HANDLE_VALUE) {
    TerminateJobObject(job, ERROR_TIMEOUT);
  }
  if (process != nullptr && process != INVALID_HANDLE_VALUE &&
      WaitForSingleObject(process, 0) != WAIT_OBJECT_0) {
    TerminateProcess(process, ERROR_TIMEOUT);
  }
  if (process != nullptr && process != INVALID_HANDLE_VALUE) {
    WaitForSingleObject(process, kPrintWindowHelperExitGraceMs);
  }
}

bool TryCapturePrintWindow(HWND hwnd, WindowCaptureResult* out) {
  if (out == nullptr) {
    return false;
  }
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    AppendDiagnostic(out, "PrintWindow target invalid", E_HANDLE);
    return false;
  }
  if (!IsWindowVisible(hwnd)) {
    AppendDiagnostic(out, "PrintWindow rejected: window not visible", S_OK);
    return false;
  }
  if (IsIconic(hwnd)) {
    AppendDiagnostic(out, "PrintWindow rejected: window minimized", S_OK);
    return false;
  }

  BOOL cloaked = FALSE;
  const HRESULT cloaked_hr =
      DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  if (FAILED(cloaked_hr)) {
    AppendDiagnostic(out, "PrintWindow rejected: cloaked state unavailable",
                     cloaked_hr);
    return false;
  }
  if (cloaked) {
    AppendDiagnostic(out, "PrintWindow rejected: window cloaked", S_OK);
    return false;
  }

  DWORD affinity = WDA_NONE;
  SetLastError(ERROR_SUCCESS);
  if (!GetWindowDisplayAffinity(hwnd, &affinity)) {
    AppendDiagnostic(out, "PrintWindow rejected: display affinity unavailable",
                     LastWin32ErrorAsHresult());
    return false;
  }
  if (affinity != WDA_NONE) {
    AppendDiagnostic(out,
                     "PrintWindow rejected: display affinity protected",
                     S_OK);
    return false;
  }

  WindowCaptureMetadata initial_client;
  if (!ReadCaptureClient(hwnd, &initial_client)) {
    AppendDiagnostic(out, "PrintWindow rejected: client geometry unavailable",
                     S_OK);
    return false;
  }
  if (!CaptureSizeWithinBudget(
          static_cast<uint64_t>(initial_client.client_width_px),
          static_cast<uint64_t>(initial_client.client_height_px)) ||
      initial_client.client_width_px > std::numeric_limits<LONG>::max() ||
      initial_client.client_height_px > std::numeric_limits<LONG>::max()) {
    AppendDiagnostic(out, "PrintWindow rejected: client size exceeds budget",
                     S_OK);
    return false;
  }

  const UINT width = static_cast<UINT>(initial_client.client_width_px);
  const UINT height = static_cast<UINT>(initial_client.client_height_px);
  const UINT stride = width * 4u;
  const size_t buffer_size = static_cast<size_t>(stride) * height;
  const size_t mapping_size = sizeof(PrintWindowHelperSharedState) + buffer_size;
  if (mapping_size < buffer_size) {
    AppendDiagnostic(out, "PrintWindow shared buffer size overflow", E_INVALIDARG);
    return false;
  }

  bool expected_idle = false;
  if (!g_print_window_worker_busy.compare_exchange_strong(
          expected_idle, true, std::memory_order_acq_rel)) {
    AppendDiagnostic(out,
                     "PrintWindow fallback busy while another helper is running",
                     S_OK);
    return false;
  }
  PrintWindowBusyGuard busy_guard;

  SECURITY_ATTRIBUTES inheritable{};
  inheritable.nLength = sizeof(inheritable);
  inheritable.bInheritHandle = TRUE;
  const DWORD mapping_size_high = static_cast<DWORD>(
      (static_cast<ULONGLONG>(mapping_size) >> 32) & 0xFFFFFFFFULL);
  const DWORD mapping_size_low = static_cast<DWORD>(
      static_cast<ULONGLONG>(mapping_size) & 0xFFFFFFFFULL);
  ScopedWinHandle mapping(CreateFileMappingW(
      INVALID_HANDLE_VALUE, &inheritable, PAGE_READWRITE, mapping_size_high,
      mapping_size_low, nullptr));
  if (!mapping) {
    AppendDiagnostic(out, "PrintWindow shared buffer creation failed",
                     LastWin32ErrorAsHresult());
    return false;
  }
  ScopedMappedView shared_view(MapViewOfFile(mapping.get(),
                                             FILE_MAP_READ | FILE_MAP_WRITE, 0,
                                             0, 0));
  if (!shared_view) {
    AppendDiagnostic(out, "PrintWindow shared buffer mapping failed",
                     LastWin32ErrorAsHresult());
    return false;
  }
  auto* state = static_cast<PrintWindowHelperSharedState*>(shared_view.get());
  std::memset(state, 0, sizeof(*state));
  state->magic = kPrintWindowHelperMagic;
  state->version = kPrintWindowHelperVersion;
  state->width = width;
  state->height = height;
  state->stride = stride;
  state->pixel_bytes = buffer_size;
  state->initial_client = initial_client;
  ::InterlockedExchange(&state->status,
                        static_cast<LONG>(PrintWindowWorkerStatus::kPending));

  ScopedWinHandle completed(CreateEventW(&inheritable, TRUE, FALSE, nullptr));
  if (!completed) {
    AppendDiagnostic(out, "PrintWindow completion event creation failed",
                     LastWin32ErrorAsHresult());
    return false;
  }
  ScopedWinHandle job(CreateJobObjectW(nullptr, nullptr));
  if (!job) {
    AppendDiagnostic(out, "PrintWindow helper job creation failed",
                     LastWin32ErrorAsHresult());
    return false;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_limits{};
  job_limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation,
                               &job_limits, sizeof(job_limits))) {
    AppendDiagnostic(out, "PrintWindow helper job configuration failed",
                     LastWin32ErrorAsHresult());
    return false;
  }

  wchar_t executable_path[32768] = {};
  const DWORD executable_capacity = static_cast<DWORD>(
      sizeof(executable_path) / sizeof(executable_path[0]));
  const DWORD executable_length = GetModuleFileNameW(
      nullptr, executable_path, executable_capacity);
  if (executable_length == 0 || executable_length >= executable_capacity) {
    AppendDiagnostic(out, "PrintWindow helper executable path unavailable",
                     LastWin32ErrorAsHresult());
    return false;
  }
  const std::wstring executable(executable_path, executable_length);
  std::wstring command = L"\"" + executable + L"\" " +
                         kPrintWindowHelperSwitch + L" " +
                         PointerArgument(reinterpret_cast<ULONG_PTR>(hwnd)) +
                         L" " +
                         PointerArgument(reinterpret_cast<ULONG_PTR>(mapping.get())) +
                         L" " +
                         PointerArgument(reinterpret_cast<ULONG_PTR>(completed.get()));
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');

  HANDLE inherited_handles[] = {mapping.get(), completed.get()};
  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
  if (attribute_size == 0) {
    AppendDiagnostic(out, "PrintWindow helper attribute list sizing failed",
                     LastWin32ErrorAsHresult());
    return false;
  }
  std::vector<BYTE> attribute_storage(attribute_size);
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(STARTUPINFOEXW);
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
      attribute_storage.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0,
                                         &attribute_size)) {
    AppendDiagnostic(out, "PrintWindow helper attribute list creation failed",
                     LastWin32ErrorAsHresult());
    return false;
  }
  const BOOL handles_updated = UpdateProcThreadAttribute(
      startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited_handles, sizeof(inherited_handles), nullptr, nullptr);
  if (!handles_updated) {
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    AppendDiagnostic(out, "PrintWindow helper handle list creation failed",
                     LastWin32ErrorAsHresult());
    return false;
  }

  PROCESS_INFORMATION process_info{};
  const BOOL created = CreateProcessW(
      executable.c_str(), mutable_command.data(), nullptr, nullptr, TRUE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_SUSPENDED,
      nullptr, nullptr,
      &startup.StartupInfo, &process_info);
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (!created) {
    AppendDiagnostic(out, "PrintWindow helper process creation failed",
                     LastWin32ErrorAsHresult());
    return false;
  }
  ScopedWinHandle process(process_info.hProcess);
  ScopedWinHandle process_thread(process_info.hThread);
  if (!AssignProcessToJobObject(job.get(), process.get())) {
    const HRESULT assign_hr = LastWin32ErrorAsHresult();
    TerminatePrintWindowHelper(job.get(), process.get());
    AppendDiagnostic(out, "PrintWindow helper job assignment failed", assign_hr);
    return false;
  }
  if (ResumeThread(process_thread.get()) == static_cast<DWORD>(-1)) {
    const HRESULT resume_hr = LastWin32ErrorAsHresult();
    TerminatePrintWindowHelper(job.get(), process.get());
    AppendDiagnostic(out, "PrintWindow helper resume failed", resume_hr);
    return false;
  }

  const DWORD completed_wait =
      WaitForSingleObject(completed.get(), kPrintWindowTimeoutMs);
  if (completed_wait != WAIT_OBJECT_0) {
    const HRESULT wait_hr =
        completed_wait == WAIT_FAILED ? LastWin32ErrorAsHresult()
                                      : HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    TerminatePrintWindowHelper(job.get(), process.get());
    AppendDiagnostic(out, "PrintWindow timed out; helper process terminated",
                     wait_hr);
    return false;
  }
  if (WaitForSingleObject(process.get(), kPrintWindowHelperExitGraceMs) !=
      WAIT_OBJECT_0) {
    TerminatePrintWindowHelper(job.get(), process.get());
    AppendDiagnostic(out, "PrintWindow helper did not exit after completion",
                     HRESULT_FROM_WIN32(ERROR_TIMEOUT));
    return false;
  }

  const uint64_t expected_pixel_bytes =
      static_cast<uint64_t>(stride) * static_cast<uint64_t>(height);
  if (state->magic != kPrintWindowHelperMagic ||
      state->version != kPrintWindowHelperVersion || state->width != width ||
      state->height != height || state->stride != stride ||
      state->pixel_bytes != expected_pixel_bytes ||
      expected_pixel_bytes != static_cast<uint64_t>(buffer_size)) {
    AppendDiagnostic(out, "PrintWindow helper protocol failed", E_INVALIDARG);
    return false;
  }
  const auto status = static_cast<PrintWindowWorkerStatus>(
      ::InterlockedCompareExchange(&state->status, 0, 0));
  const HRESULT failure_hr = static_cast<HRESULT>(state->failure_hr);
  switch (status) {
    case PrintWindowWorkerStatus::kComUnavailable:
      AppendDiagnostic(out, "PrintWindow helper COM unavailable", failure_hr);
      return false;
    case PrintWindowWorkerStatus::kDcCreateFailed:
      AppendDiagnostic(out, "PrintWindow compatible DC creation failed",
                       failure_hr);
      return false;
    case PrintWindowWorkerStatus::kDibCreateFailed:
      AppendDiagnostic(out, "PrintWindow DIB creation failed", failure_hr);
      return false;
    case PrintWindowWorkerStatus::kDibSelectFailed:
      AppendDiagnostic(out, "PrintWindow DIB selection failed", failure_hr);
      return false;
    case PrintWindowWorkerStatus::kPrintFailed:
      AppendDiagnostic(out, "PrintWindow failed", failure_hr);
      return false;
    case PrintWindowWorkerStatus::kClientChanged:
      AppendDiagnostic(out,
                       "PrintWindow rejected: client identity changed during capture",
                       S_OK);
      return false;
    case PrintWindowWorkerStatus::kHelperProtocolFailed:
      AppendDiagnostic(out, "PrintWindow helper protocol failed", failure_hr);
      return false;
    case PrintWindowWorkerStatus::kPngEncodeFailed:
      AppendDiagnostic(out, "PrintWindow PNG encoding failed", S_OK);
      return false;
    case PrintWindowWorkerStatus::kNoPixels:
    case PrintWindowWorkerStatus::kPartialPixels:
    case PrintWindowWorkerStatus::kBlackPixels:
    case PrintWindowWorkerStatus::kTransparentPixels:
      break;
    case PrintWindowWorkerStatus::kComplete:
      break;
    case PrintWindowWorkerStatus::kPending:
      AppendDiagnostic(out, "PrintWindow helper returned without a result",
                       E_UNEXPECTED);
      return false;
  }

  uint8_t* bytes = reinterpret_cast<uint8_t*>(state) +
                   sizeof(PrintWindowHelperSharedState);
  const PrintWindowWorkerStatus pixel_status =
      ValidatePrintWindowPixels(bytes, buffer_size, width, height);
  if (pixel_status != PrintWindowWorkerStatus::kComplete) {
    switch (pixel_status) {
      case PrintWindowWorkerStatus::kNoPixels:
        AppendDiagnostic(out, "PrintWindow produced no pixels", S_OK);
        break;
      case PrintWindowWorkerStatus::kPartialPixels:
        AppendDiagnostic(out, "PrintWindow produced partial client pixels", S_OK);
        break;
      case PrintWindowWorkerStatus::kBlackPixels:
        AppendDiagnostic(out, "PrintWindow produced a black client frame", S_OK);
        break;
      case PrintWindowWorkerStatus::kTransparentPixels:
        AppendDiagnostic(out, "PrintWindow produced a transparent client frame",
                         S_OK);
        break;
      default:
        AppendDiagnostic(out, "PrintWindow helper returned invalid pixels",
                         E_UNEXPECTED);
        break;
    }
    return false;
  }

  WindowCaptureMetadata observed_client;
  if (!ReadCaptureClient(hwnd, &observed_client) ||
      !SameCaptureClient(initial_client, observed_client) ||
      !SameCaptureClient(initial_client, state->final_client)) {
    AppendDiagnostic(out,
                     "PrintWindow rejected: client identity changed during capture",
                     S_OK);
    return false;
  }
  std::string encode_error;
  std::vector<uint8_t> png =
      EncodeBgraToPng(bytes, width, height, stride, &encode_error);
  if (png.empty()) {
    AppendDiagnostic(out, "PrintWindow PNG encoding failed", S_OK);
    return false;
  }
  observed_client.image_width_px = static_cast<int>(width);
  observed_client.image_height_px = static_cast<int>(height);
  observed_client.captured_at_tick_ms = GetTickCount64();
  observed_client.client_area_complete = true;
  SetCaptureProvenance(&observed_client, hwnd, hwnd, nullptr);

  WindowCaptureResult replacement;
  replacement.png = std::move(png);
  replacement.diagnostics = out->diagnostics;
  replacement.has_metadata = true;
  replacement.metadata = observed_client;
  replacement.capture_reason = "printwindow_complete";
  replacement.ok = true;
  AppendDiagnostic(&replacement,
                   "PrintWindow fallback captured the target client area",
                   S_OK);
  *out = std::move(replacement);
  return true;
}

}  // namespace

int RunPrintWindowCaptureHelperIfRequested() {
  return RunPrintWindowHelperFromCommandLine();
}

// D3D11 设备（BGRA 支持），硬件失败回退 WARP。
ComPtr<ID3D11Device> CreateD3DDevice() {
  ComPtr<ID3D11Device> device;
  const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, nullptr, 0, D3D11_SDK_VERSION,
                                 device.GetAddressOf(), nullptr, nullptr);
  if (FAILED(hr)) {
    device.Reset();
    D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, nullptr, 0,
                      D3D11_SDK_VERSION, device.GetAddressOf(), nullptr,
                      nullptr);
  }
  return device;
}

// BUG-1096：Magpie 缩放窗 -> 源窗口。判定契约是**窗口属性** `Magpie.SrcHWND`
// （Magpie 在缩放窗上 SetProp 的公开标记），不是类名——类名里的 GUID 属于实现细节，
// 属性名才是跨版本稳定的那一条。属性缺失 / 指向自身 / 句柄已失效都返回 nullptr，
// 调用方原样保留传入窗口（Never break：没装 Magpie 的用户走的路径与以前逐字相同）。
HWND ResolveScalingSourceWindow(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    return nullptr;
  }
  const HANDLE prop = GetPropW(hwnd, L"Magpie.SrcHWND");
  if (prop == nullptr) {
    return nullptr;
  }
  HWND source = static_cast<HWND>(prop);
  if (source == hwnd || !IsWindow(source)) {
    return nullptr;
  }
  return source;
}

namespace {

struct WindowPropertyLookup {
  const wchar_t* name = nullptr;
  HANDLE value = nullptr;
  bool found = false;
};

BOOL CALLBACK FindWindowPropertyProc(HWND, LPWSTR name, HANDLE value,
                                     ULONG_PTR data) {
  auto* lookup = reinterpret_cast<WindowPropertyLookup*>(data);
  if (lookup == nullptr || name == nullptr || IS_INTRESOURCE(name) ||
      lookup->name == nullptr || lstrcmpW(name, lookup->name) != 0) {
    return TRUE;
  }
  lookup->value = value;
  lookup->found = true;
  return FALSE;
}

bool ReadWindowPropertyInt32(HWND hwnd, const wchar_t* name, LONG* value) {
  if (hwnd == nullptr || name == nullptr || value == nullptr) {
    return false;
  }
  WindowPropertyLookup lookup{name};
  if (EnumPropsExW(hwnd, FindWindowPropertyProc,
                   reinterpret_cast<ULONG_PTR>(&lookup)) == -1 ||
      !lookup.found) {
    return false;
  }
  const INT_PTR raw = reinterpret_cast<INT_PTR>(lookup.value);
  if (raw < static_cast<INT_PTR>(std::numeric_limits<LONG>::min()) ||
      raw > static_cast<INT_PTR>(std::numeric_limits<LONG>::max())) {
    return false;
  }
  *value = static_cast<LONG>(raw);
  return true;
}

bool ReadMagpieRect(HWND hwnd, const wchar_t* left_name,
                    const wchar_t* top_name, const wchar_t* right_name,
                    const wchar_t* bottom_name, RECT* rect) {
  if (rect == nullptr ||
      !ReadWindowPropertyInt32(hwnd, left_name, &rect->left) ||
      !ReadWindowPropertyInt32(hwnd, top_name, &rect->top) ||
      !ReadWindowPropertyInt32(hwnd, right_name, &rect->right) ||
      !ReadWindowPropertyInt32(hwnd, bottom_name, &rect->bottom)) {
    return false;
  }
  return rect->right > rect->left && rect->bottom > rect->top;
}

}  // namespace

bool ReadMagpiePresentationMapping(HWND presentation_hwnd,
                                    HWND expected_source_hwnd,
                                    MagpiePresentationMapping* mapping) {
  if (mapping == nullptr || presentation_hwnd == nullptr ||
      expected_source_hwnd == nullptr || !IsWindow(presentation_hwnd) ||
      !IsWindow(expected_source_hwnd)) {
    return false;
  }
  *mapping = MagpiePresentationMapping{};
  const HWND source_hwnd = ResolveScalingSourceWindow(presentation_hwnd);
  if (source_hwnd == nullptr || source_hwnd != expected_source_hwnd) {
    return false;
  }
  RECT source_rect{};
  RECT destination_rect{};
  if (!ReadMagpieRect(presentation_hwnd, L"Magpie.SrcLeft",
                      L"Magpie.SrcTop", L"Magpie.SrcRight",
                      L"Magpie.SrcBottom", &source_rect) ||
      !ReadMagpieRect(presentation_hwnd, L"Magpie.DestLeft",
                      L"Magpie.DestTop", L"Magpie.DestRight",
                      L"Magpie.DestBottom", &destination_rect)) {
    return false;
  }
  mapping->presentation_hwnd = presentation_hwnd;
  mapping->source_hwnd = source_hwnd;
  mapping->source_rect_screen = source_rect;
  mapping->destination_rect_screen = destination_rect;
  return true;
}

namespace {

struct PresentationEnumContext {
  HWND source_hwnd = nullptr;
  std::vector<MagpiePresentationMapping>* mappings = nullptr;
};

BOOL CALLBACK FindMagpiePresentationProc(HWND hwnd, LPARAM lparam) {
  auto* context = reinterpret_cast<PresentationEnumContext*>(lparam);
  if (context == nullptr || context->mappings == nullptr ||
      hwnd == nullptr || hwnd == context->source_hwnd ||
      !IsWindowVisible(hwnd) || IsIconic(hwnd)) {
    return TRUE;
  }
  BOOL cloaked = FALSE;
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                      sizeof(cloaked))) &&
      cloaked) {
    return TRUE;
  }
  MagpiePresentationMapping mapping;
  if (ReadMagpiePresentationMapping(hwnd, context->source_hwnd, &mapping)) {
    context->mappings->push_back(mapping);
  }
  return TRUE;
}

std::vector<MagpiePresentationMapping> EnumerateMagpiePresentations(
    HWND source_hwnd) {
  std::vector<MagpiePresentationMapping> mappings;
  if (source_hwnd == nullptr || !IsWindow(source_hwnd)) {
    return mappings;
  }
  PresentationEnumContext context{source_hwnd, &mappings};
  EnumWindows(&FindMagpiePresentationProc,
              reinterpret_cast<LPARAM>(&context));
  return mappings;
}

}  // namespace

std::vector<ExternalWindow> EnumerateTopLevelWindows(HWND self) {
  std::vector<ExternalWindow> out;
  EnumContext ctx{self, &out};
  EnumWindows(&EnumProc, reinterpret_cast<LPARAM>(&ctx));
  return out;
}

namespace {

// 单帧捕获核心（假定调用线程已 RoInitialize）。任何失败写 out->error 并返回。
// [source_hwnd] is the logical game window. When [presentation_mapping] is
// present, [hwnd] is a verified Magpie output window and the encoded image is
// restricted to its published destination viewport.
void CaptureCore(HWND hwnd, WindowCaptureResult* out,
                 HWND source_hwnd = nullptr,
                 const MagpiePresentationMapping* presentation_mapping =
                     nullptr) {
  const HWND source_identity = source_hwnd != nullptr ? source_hwnd : hwnd;
  WindowCaptureMetadata initial_client;
  const bool initial_client_valid = ReadCaptureClient(hwnd, &initial_client);
  WindowCaptureMetadata initial_source_client;
  const bool initial_source_client_valid =
      source_identity == hwnd
          ? initial_client_valid
          : ReadCaptureClient(source_identity, &initial_source_client);
  if (presentation_mapping != nullptr &&
      (presentation_mapping->presentation_hwnd != hwnd ||
       presentation_mapping->source_hwnd != source_identity ||
       !initial_client_valid || !initial_source_client_valid)) {
    SetCaptureFailure(out, "presentation_viewport_unavailable",
                      "Magpie presentation viewport unavailable");
    return;
  }
  if (presentation_mapping != nullptr) {
    RECT presentation_client{
        initial_client.client_left_px,
        initial_client.client_top_px,
        initial_client.client_left_px + initial_client.client_width_px,
        initial_client.client_top_px + initial_client.client_height_px};
    RECT source_client{
        initial_source_client.client_left_px,
        initial_source_client.client_top_px,
        initial_source_client.client_left_px +
            initial_source_client.client_width_px,
        initial_source_client.client_top_px +
            initial_source_client.client_height_px};
    if (!RectWithin(presentation_mapping->destination_rect_screen,
                    presentation_client) ||
        !RectWithin(presentation_mapping->source_rect_screen, source_client)) {
      SetCaptureFailure(out, "presentation_viewport_invalid",
                        "Magpie presentation viewport is outside its client");
      return;
    }
  }
  if (initial_client_valid) {
    SetCaptureProvenance(&initial_client, hwnd, source_identity,
                         presentation_mapping);
    // Keep the initial geometry even when WGC times out or the final client
    // read fails. It is the only bounded evidence available for those paths.
    out->metadata = initial_client;
    out->has_metadata = true;
  } else {
    SetCaptureReason(out, "initial_client_unavailable");
  }
  ComPtr<WGC::IGraphicsCaptureSessionStatics> session_statics;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
          session_statics.GetAddressOf()))) {
    SetCaptureFailure(out, "wgc_activation_unavailable",
                      "graphics capture unavailable");
    return;
  }
  boolean supported = false;
  session_statics->IsSupported(&supported);
  if (!supported) {
    SetCaptureFailure(out, "wgc_unsupported",
                      "graphics capture not supported (Windows 10 1903+ required)");
    return;
  }

  ComPtr<ID3D11Device> d3d = CreateD3DDevice();
  if (!d3d) {
    SetCaptureFailure(out, "d3d_device_unavailable", "D3D11 device create failed");
    return;
  }
  ComPtr<IDXGIDevice> dxgi;
  if (FAILED(d3d.As(&dxgi))) {
    SetCaptureFailure(out, "dxgi_device_query_failed",
                      "IDXGIDevice query failed");
    return;
  }
  ComPtr<IInspectable> inspectable;
  if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(),
                                                  inspectable.GetAddressOf()))) {
    SetCaptureFailure(out, "d3d_interop_unavailable",
                      "CreateDirect3D11DeviceFromDXGIDevice failed");
    return;
  }
  ComPtr<WGDXD3D::IDirect3DDevice> device;
  if (FAILED(inspectable.As(&device))) {
    SetCaptureFailure(out, "direct3d_device_query_failed",
                      "IDirect3DDevice query failed");
    return;
  }

  ComPtr<IGraphicsCaptureItemInterop> interop;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureItem,
          interop.GetAddressOf()))) {
    SetCaptureFailure(out, "wgc_item_interop_unavailable",
                      "capture item interop unavailable");
    return;
  }
  ComPtr<WGC::IGraphicsCaptureItem> item;
  const HRESULT item_hr = interop->CreateForWindow(
      hwnd, __uuidof(WGC::IGraphicsCaptureItem),
      reinterpret_cast<void**>(item.GetAddressOf()));
  if (FAILED(item_hr) || !item) {
    SetCaptureFailure(out, "wgc_item_create_failed",
                      "CreateForWindow failed (window not capturable)");
    AppendDiagnostic(out, item ? "CreateForWindow failed"
                               : "CreateForWindow returned no item",
                     FAILED(item_hr) ? item_hr : E_POINTER);
    return;
  }
  ABI::Windows::Graphics::SizeInt32 size = {};
  if (FAILED(item->get_Size(&size)) || size.Width <= 0 || size.Height <= 0) {
    SetCaptureFailure(out, "wgc_item_size_invalid", "window has zero size");
    return;
  }
  if (!CaptureSizeWithinBudget(size.Width, size.Height)) {
    SetCaptureFailure(out, "capture_size_limit", "capture exceeds frame budget");
    return;
  }

  ComPtr<WGC::IDirect3D11CaptureFramePoolStatics2> pool_statics;
  if (FAILED(GetActivationFactory(
          RuntimeClass_Windows_Graphics_Capture_Direct3D11CaptureFramePool,
          pool_statics.GetAddressOf()))) {
    SetCaptureFailure(out, "wgc_frame_pool_unavailable",
                      "frame pool statics unavailable");
    return;
  }
  ComPtr<WGC::IDirect3D11CaptureFramePool> frame_pool;
  if (FAILED(pool_statics->CreateFreeThreaded(
          device.Get(), WGDX::DirectXPixelFormat_B8G8R8A8UIntNormalized, 2,
          size, frame_pool.GetAddressOf())) ||
      !frame_pool) {
    SetCaptureFailure(out, "wgc_frame_pool_create_failed",
                      "frame pool create failed");
    return;
  }
  ComPtr<WGC::IGraphicsCaptureSession> session;
  if (FAILED(frame_pool->CreateCaptureSession(item.Get(),
                                              session.GetAddressOf()))) {
    SetCaptureFailure(out, "wgc_session_create_failed",
                      "capture session create failed");
    return;
  }
  // BUG-1096：关闭 WGC 合成光标。IGraphicsCaptureSession2 需要 Win10 build 19041+，
  // 以前 QI 的失败和 put_ 的 HRESULT **两处都被静默丢掉**——「用户机器上到底关掉了
  // 没有」是个彻底的盲区。现在两条路径都写进 diagnostics（经 channel 回到 Dart 日志），
  // 成不成立变成可证的事实，而不是靠推断。注意：游戏**自绘**的光标是画面内容本身，
  // 任何捕获 API 都剥不掉，这里只负责不再由 WGC 额外合成一个。
  ComPtr<WGC::IGraphicsCaptureSession2> session2;
  const HRESULT cursor_qi = session.As(&session2);
  if (SUCCEEDED(cursor_qi) && session2) {
    const HRESULT cursor_hr = session2->put_IsCursorCaptureEnabled(false);
    if (FAILED(cursor_hr)) {
      AppendDiagnostic(out, "put_IsCursorCaptureEnabled(false) failed",
                       cursor_hr);
    }
  } else {
    AppendDiagnostic(out,
                     "IGraphicsCaptureSession2 unavailable (needs Windows 10 "
                     "build 19041+); WGC cursor NOT suppressed",
                     SUCCEEDED(cursor_qi) ? E_POINTER : cursor_qi);
  }
  ComPtr<WGC::IGraphicsCaptureSession3> session3;
  if (SUCCEEDED(session.As(&session3))) {
    session3->put_IsBorderRequired(false);
  }

  std::atomic<bool> grabbed{false};
  ComPtr<WGC::IDirect3D11CaptureFrame> frame;
  HANDLE frame_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (frame_event == nullptr) {
    SetCaptureFailure(out, "frame_event_create_failed", "event create failed");
    return;
  }
  // 免线程（agile）委托：FreeThreaded 帧池会在任意线程池线程回调 FrameArrived。
  // 聚合 FtmBase 让委托 agile，避免非 agile 委托被 add_FrameArrived 拒绝
  // （RO_E_MUST_BE_AGILE，见 texture_bridge.cc 对 timer 委托的同款处理）。
  auto handler = Callback<Microsoft::WRL::Implements<
      Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
      ABI::Windows::Foundation::ITypedEventHandler<
          WGC::Direct3D11CaptureFramePool*, IInspectable*>,
      Microsoft::WRL::FtmBase>>(
      [&grabbed, &frame, frame_event](WGC::IDirect3D11CaptureFramePool* pool,
                                      IInspectable*) -> HRESULT {
        bool expected = false;
        if (grabbed.compare_exchange_strong(expected, true)) {
          pool->TryGetNextFrame(frame.GetAddressOf());
          SetEvent(frame_event);
        }
        return S_OK;
      });
  EventRegistrationToken token = {};
  if (FAILED(frame_pool->add_FrameArrived(handler.Get(), &token))) {
    CloseHandle(frame_event);
    SetCaptureFailure(out, "frame_arrived_registration_failed",
                      "add_FrameArrived failed");
    return;
  }
  if (FAILED(session->StartCapture())) {
    frame_pool->remove_FrameArrived(token);
    CloseHandle(frame_event);
    SetCaptureFailure(out, "wgc_start_failed", "StartCapture failed");
    return;
  }

  const DWORD wait = WaitForSingleObject(frame_event, 1500);
  frame_pool->remove_FrameArrived(token);
  CloseHandle(frame_event);

  if (wait != WAIT_OBJECT_0 || !frame) {
    CloseIfClosable(session);
    CloseIfClosable(frame_pool);
    SetCaptureFailure(
        out, "no_frame",
        "capture timed out (no frame; DRM-protected windows yield no frame)");
    return;
  }

  ComPtr<WGDXD3D::IDirect3DSurface> surface;
  ComPtr<IDxgiInterfaceAccessLocal> access;
  ComPtr<ID3D11Texture2D> texture;
  if (SUCCEEDED(frame->get_Surface(surface.GetAddressOf())) &&
      SUCCEEDED(surface.As(&access))) {
    access->GetInterface(__uuidof(ID3D11Texture2D),
                         reinterpret_cast<void**>(texture.GetAddressOf()));
  }
  if (!texture) {
    CloseIfClosable(frame);
    CloseIfClosable(session);
    CloseIfClosable(frame_pool);
    SetCaptureFailure(out, "frame_surface_unavailable",
                      "frame surface unavailable");
    return;
  }
  const uint64_t captured_at_tick_ms = GetTickCount64();
  ABI::Windows::Graphics::SizeInt32 content_size{};
  const bool content_size_valid =
      SUCCEEDED(frame->get_ContentSize(&content_size)) &&
      content_size.Width > 0 && content_size.Height > 0;

  D3D11_TEXTURE2D_DESC desc = {};
  texture->GetDesc(&desc);
  if (!CaptureSizeWithinBudget(desc.Width, desc.Height)) {
    CloseIfClosable(frame);
    CloseIfClosable(session);
    CloseIfClosable(frame_pool);
    SetCaptureFailure(out, "capture_size_limit", "texture exceeds frame budget");
    return;
  }
  if (out->has_metadata) {
    out->metadata.content_width_px =
        content_size_valid ? content_size.Width : 0;
    out->metadata.content_height_px =
        content_size_valid ? content_size.Height : 0;
    out->metadata.texture_width_px = static_cast<int>(desc.Width);
    out->metadata.texture_height_px = static_cast<int>(desc.Height);
  }
  D3D11_TEXTURE2D_DESC staging_desc = desc;
  staging_desc.Usage = D3D11_USAGE_STAGING;
  staging_desc.BindFlags = 0;
  staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  staging_desc.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> staging;
  if (FAILED(d3d->CreateTexture2D(&staging_desc, nullptr,
                                  staging.GetAddressOf()))) {
    CloseIfClosable(frame);
    CloseIfClosable(session);
    CloseIfClosable(frame_pool);
    SetCaptureFailure(out, "staging_texture_create_failed",
                      "staging texture create failed");
    return;
  }
  ComPtr<ID3D11DeviceContext> context;
  d3d->GetImmediateContext(context.GetAddressOf());
  context->CopyResource(staging.Get(), texture.Get());
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  if (SUCCEEDED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
    // BUG-1854：直接捕获时只编码客户区子矩形（标题栏 / 菜单栏 / 边框不进卡片）。
    // Magpie fallback 则只能编码已验证的 DestRect；未知 viewport 时 fail closed，
    // 绝不能把整个 presentation client 当作游戏图像。
    RECT crop{};
    const uint8_t* pixels = static_cast<const uint8_t*>(mapped.pData);
    UINT encode_w = 0;
    UINT encode_h = 0;
    const bool using_presentation = presentation_mapping != nullptr;
    const bool crop_valid = using_presentation
                                ? ComputeScreenCropBox(
                                      hwnd,
                                      presentation_mapping->destination_rect_screen,
                                      desc.Width, desc.Height, &crop)
                                : ComputeClientCropBox(hwnd, desc.Width,
                                                       desc.Height, &crop);
    const int requested_destination_width =
        using_presentation
            ? RectWidth(presentation_mapping->destination_rect_screen)
            : 0;
    const int requested_destination_height =
        using_presentation
            ? RectHeight(presentation_mapping->destination_rect_screen)
            : 0;
    const bool crop_matches_destination =
        using_presentation && crop_valid &&
        static_cast<int>(crop.right - crop.left) ==
            requested_destination_width &&
        static_cast<int>(crop.bottom - crop.top) ==
            requested_destination_height;
    const bool crop_inside_content =
        crop_valid && content_size_valid && crop.left >= 0 && crop.top >= 0 &&
        crop.right <= content_size.Width && crop.bottom <= content_size.Height;
    const bool encode_allowed =
        crop_valid && (!using_presentation ||
                       (crop_matches_destination && crop_inside_content));
    if (encode_allowed) {
      pixels += static_cast<size_t>(crop.top) * mapped.RowPitch +
                static_cast<size_t>(crop.left) * 4;
      encode_w = static_cast<UINT>(crop.right - crop.left);
      encode_h = static_cast<UINT>(crop.bottom - crop.top);
    } else if (using_presentation) {
      SetCaptureFailure(out, "presentation_viewport_unavailable",
                        "Magpie destination viewport could not be captured");
    } else {
      // If the regular client crop is unavailable, preserve the historical
      // fail-open behavior for ordinary windows. This branch is deliberately
      // unreachable for a presentation fallback.
      encode_w = desc.Width;
      encode_h = desc.Height;
      AppendDiagnostic(out,
                       "client-area crop unavailable; encoded the whole "
                       "window (title bar included)",
                       S_OK);
    }
    if (encode_w > 0 && encode_h > 0) {
      out->png = EncodeBgraToPng(pixels, encode_w, encode_h, mapped.RowPitch,
                                 &out->error);
    }
    if (out->png.empty()) {
      SetCaptureReason(out, "png_encode_failed");
    }
    WindowCaptureMetadata final_client;
    if (ReadCaptureClient(hwnd, &final_client)) {
      final_client.image_width_px = static_cast<int>(encode_w);
      final_client.image_height_px = static_cast<int>(encode_h);
      final_client.captured_at_tick_ms = captured_at_tick_ms;
      final_client.content_width_px =
          content_size_valid ? content_size.Width : 0;
      final_client.content_height_px =
          content_size_valid ? content_size.Height : 0;
      final_client.texture_width_px = static_cast<int>(desc.Width);
      final_client.texture_height_px = static_cast<int>(desc.Height);
      final_client.client_area_complete =
          !using_presentation && initial_client_valid &&
          SameCaptureClient(initial_client, final_client) && content_size_valid &&
          crop.right <= content_size.Width && crop.bottom <= content_size.Height &&
          crop.right > crop.left && crop.bottom > crop.top &&
          static_cast<int>(encode_w) == final_client.client_width_px &&
          static_cast<int>(encode_h) == final_client.client_height_px;
      SetCaptureProvenance(&final_client, hwnd, source_identity,
                           presentation_mapping);
      if (using_presentation) {
        WindowCaptureMetadata final_source_client;
        const bool final_source_client_valid =
            ReadCaptureClient(source_identity, &final_source_client);
        MagpiePresentationMapping final_mapping;
        const bool final_mapping_valid = ReadMagpiePresentationMapping(
            hwnd, source_identity, &final_mapping);
        const RECT presentation_client{
            final_client.client_left_px,
            final_client.client_top_px,
            final_client.client_left_px + final_client.client_width_px,
            final_client.client_top_px + final_client.client_height_px};
        const bool destination_still_inside =
            final_mapping_valid &&
            RectWithin(final_mapping.destination_rect_screen,
                       presentation_client);
        const bool source_still_inside =
            final_mapping_valid && final_source_client_valid &&
            RectWithin(
                final_mapping.source_rect_screen,
                RECT{final_source_client.client_left_px,
                     final_source_client.client_top_px,
                     final_source_client.client_left_px +
                         final_source_client.client_width_px,
                     final_source_client.client_top_px +
                         final_source_client.client_height_px});
        const bool mapping_stable =
            final_mapping_valid &&
            SameRect(final_mapping.source_rect_screen,
                     presentation_mapping->source_rect_screen) &&
            SameRect(final_mapping.destination_rect_screen,
                     presentation_mapping->destination_rect_screen);
        if (final_source_client_valid) {
          // Keep the serialized source client geometry tied to the same final
          // identity/size/DPI read used by the presentation completeness gate.
          final_client.source_client_left_px =
              final_source_client.client_left_px;
          final_client.source_client_top_px =
              final_source_client.client_top_px;
          final_client.source_client_width_px =
              final_source_client.client_width_px;
          final_client.source_client_height_px =
              final_source_client.client_height_px;
          final_client.source_client_dpi =
              static_cast<int>(final_source_client.dpi);
        }
        final_client.presentation_viewport_complete =
            !out->png.empty() && initial_client_valid &&
            initial_source_client_valid && final_source_client_valid &&
            SameCaptureClient(initial_client, final_client) &&
            SameCaptureClient(initial_source_client, final_source_client) &&
            content_size_valid && crop_inside_content &&
            crop_matches_destination && destination_still_inside &&
            source_still_inside && mapping_stable &&
            static_cast<int>(encode_w) ==
                RectWidth(presentation_mapping->destination_rect_screen) &&
            static_cast<int>(encode_h) ==
                RectHeight(presentation_mapping->destination_rect_screen);
      }
      out->metadata = final_client;
      out->has_metadata = true;
      if (out->png.empty()) {
        SetCaptureReason(out, "png_encode_failed");
      } else if (using_presentation && !content_size_valid) {
        SetCaptureReason(out, "presentation_content_size_invalid");
      } else if (using_presentation && !crop_matches_destination) {
        SetCaptureReason(out, "presentation_destination_size_mismatch");
      } else if (using_presentation && !crop_inside_content) {
        SetCaptureReason(out, "presentation_viewport_outside_content");
      } else if (using_presentation) {
        SetCaptureReason(out, final_client.presentation_viewport_complete
                                ? "presentation_complete"
                                : "presentation_viewport_incomplete");
      } else if (!initial_client_valid) {
        SetCaptureReason(out, "initial_client_unavailable");
      } else if (!content_size_valid) {
        SetCaptureReason(out, "content_size_invalid");
      } else if (!crop_valid) {
        SetCaptureReason(out, "client_crop_unavailable");
      } else if (crop.right > content_size.Width ||
                 crop.bottom > content_size.Height) {
        SetCaptureReason(out, "client_crop_outside_content");
      } else if (!SameCaptureClient(initial_client, final_client)) {
        SetCaptureReason(out, "client_changed_during_capture");
      } else if (static_cast<int>(encode_w) != final_client.client_width_px ||
                 static_cast<int>(encode_h) != final_client.client_height_px) {
        SetCaptureReason(out, "client_image_size_mismatch");
      } else if (!final_client.client_area_complete) {
        SetCaptureReason(out, "client_area_incomplete");
      } else {
        SetCaptureReason(out, "complete");
      }
    } else if (!out->png.empty()) {
      SetCaptureReason(out, "final_client_unavailable");
    }
    context->Unmap(staging.Get(), 0);
  } else {
    SetCaptureFailure(out, "staging_map_failed", "map staging texture failed");
  }

  CloseIfClosable(frame);
  CloseIfClosable(session);
  CloseIfClosable(frame_pool);
  if (presentation_mapping != nullptr && out->has_metadata &&
      !out->metadata.presentation_viewport_complete) {
    out->png.clear();
    SetCaptureFailure(out, "presentation_viewport_incomplete",
                      "Magpie presentation viewport changed during capture");
  }
  out->ok = out->error.empty() && !out->png.empty();
  if (!out->ok && out->error.empty()) {
    SetCaptureFailure(out, "capture_failed", "capture produced no pixels");
  } else if (out->ok && out->capture_reason.empty()) {
    SetCaptureReason(out, "complete");
  }
}

}  // namespace

WindowCaptureResult CaptureWindowPng(HWND hwnd) {
  if (hwnd == nullptr || !IsWindow(hwnd)) {
    WindowCaptureResult out;
    SetCaptureFailure(&out, "invalid_window_handle", "window handle invalid");
    return out;
  }
  const HWND requested_hwnd = hwnd;
  const HRESULT ro = RoInitialize(RO_INIT_MULTITHREADED);
  // RPC_E_CHANGED_MODE = 本线程已按其它套间初始化；照常用、但不由我们反初始化。
  if (FAILED(ro) && ro != RPC_E_CHANGED_MODE) {
    WindowCaptureResult out;
    SetCaptureFailure(&out, "ro_initialize_failed", "RoInitialize failed");
    return out;
  }
  WindowCaptureResult out;
  WindowCaptureResult candidate;
  HWND source_hwnd = requested_hwnd;
  // Resolve the logical source once for this request. A failed WGC item is a
  // backend decision, not evidence that a second immediate CreateForWindow
  // call can change the result.
  if (const HWND source = ResolveScalingSourceWindow(source_hwnd)) {
    AppendDiagnostic(&candidate,
                     "capture target redirected: Magpie scaling window -> "
                     "source window (Magpie.SrcHWND)",
                     S_OK);
    source_hwnd = source;
  }
  CaptureCore(source_hwnd, &candidate);

  // A source HWND can be visible and valid while WGC refuses to create an
  // item. First try the narrow composition-only compatibility path. If it is
  // unavailable, retain the source failure and then try only verified Magpie
  // presentations whose published viewport can be checked end to end.
  if (candidate.capture_reason == "wgc_item_create_failed") {
    const bool print_window_captured =
        TryCapturePrintWindow(source_hwnd, &candidate);
    if (!print_window_captured &&
        candidate.capture_reason == "wgc_item_create_failed") {
      const std::string source_diagnostics = candidate.diagnostics;
      std::vector<MagpiePresentationMapping> mappings;
      MagpiePresentationMapping requested_mapping;
      if (requested_hwnd != source_hwnd &&
          ReadMagpiePresentationMapping(requested_hwnd, source_hwnd,
                                         &requested_mapping)) {
        mappings.push_back(requested_mapping);
      }
      std::vector<MagpiePresentationMapping> discovered =
          EnumerateMagpiePresentations(source_hwnd);
      for (const MagpiePresentationMapping& discovered_mapping : discovered) {
        bool duplicate = false;
        for (const MagpiePresentationMapping& existing : mappings) {
          if (existing.presentation_hwnd ==
              discovered_mapping.presentation_hwnd) {
            duplicate = true;
            break;
          }
        }
        if (!duplicate) {
          mappings.push_back(discovered_mapping);
        }
      }
      constexpr size_t kMaximumPresentationAttempts = 2;
      WindowCaptureResult fallback_failure;
      bool attempted_presentation = false;
      for (size_t i = 0;
           i < mappings.size() && i < kMaximumPresentationAttempts; ++i) {
        const MagpiePresentationMapping& mapping = mappings[i];
        WindowCaptureResult presentation_candidate;
        presentation_candidate.diagnostics = source_diagnostics;
        AppendDiagnostic(
            &presentation_candidate,
            "source WGC item unavailable; tried verified Magpie presentation",
            S_OK);
        CaptureCore(mapping.presentation_hwnd, &presentation_candidate,
                    source_hwnd, &mapping);
        attempted_presentation = true;
        if (presentation_candidate.ok &&
            presentation_candidate.has_metadata &&
            presentation_candidate.metadata.presentation_viewport_complete) {
          AppendDiagnostic(&presentation_candidate,
                           "captured Magpie DestRect viewport", S_OK);
          candidate = std::move(presentation_candidate);
          break;
        }
        if (!fallback_failure.has_metadata ||
            fallback_failure.capture_reason.empty()) {
          fallback_failure = std::move(presentation_candidate);
        }
      }
      if (attempted_presentation &&
          candidate.capture_reason == "wgc_item_create_failed" &&
          !fallback_failure.capture_reason.empty()) {
        candidate = std::move(fallback_failure);
      }
      if (!attempted_presentation &&
          candidate.capture_reason == "wgc_item_create_failed") {
        AppendDiagnostic(&candidate,
                         "source WGC item rejected and no verified Magpie "
                         "presentation mapping was found",
                         S_OK);
      }
    }
  }
  out = std::move(candidate);
  if (SUCCEEDED(ro)) {
    RoUninitialize();
  }
  return out;
}

}  // namespace fushi
