#include "hdr_video_host_window.h"

#include <dwmapi.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

namespace fushi {

namespace {

constexpr wchar_t kHostClassName[] = L"FushiHdrVideoHost";

bool RegisterHostClass() {
  static bool registered = false;
  if (registered) {
    return true;
  }
  WNDCLASSW wc = {};
  wc.lpfnWndProc = HdrVideoHostWindow::WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kHostClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  // Letterbox colour before mpv paints its first frame.
  wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  registered = RegisterClassW(&wc) != 0;
  return registered;
}

BOOL CALLBACK ResizeChildProc(HWND child, LPARAM lparam) {
  const RECT* rc = reinterpret_cast<const RECT*>(lparam);
  SetWindowPos(child, nullptr, 0, 0, rc->right - rc->left,
               rc->bottom - rc->top, SWP_NOZORDER | SWP_NOACTIVATE);
  return TRUE;
}

}  // namespace

HdrVideoHostWindow::HdrVideoHostWindow(HWND main) : main_(main) {}

HdrVideoHostWindow::~HdrVideoHostWindow() { Destroy(); }

LRESULT CALLBACK HdrVideoHostWindow::WndProc(HWND hwnd, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE:
      // Never take activation: the main window above owns focus and input.
      return MA_NOACTIVATE;
    case WM_ERASEBKGND: {
      RECT rc;
      GetClientRect(hwnd, &rc);
      FillRect(reinterpret_cast<HDC>(wparam), &rc,
               static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
      return 1;
    }
    default:
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

HWND HdrVideoHostWindow::Create() {
  if (hwnd_ != nullptr) {
    return hwnd_;
  }
  if (main_ == nullptr || !RegisterHostClass()) {
    return nullptr;
  }
  // Tool window: no taskbar button; NOACTIVATE: never steals foreground. Not
  // owned by the main window on purpose: owned windows always sit *above*
  // their owner, and this one must sit below.
  hwnd_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kHostClassName,
                          L"", WS_POPUP, 0, 0, 16, 16, nullptr, nullptr,
                          GetModuleHandleW(nullptr), nullptr);
  if (hwnd_ == nullptr) {
    return nullptr;
  }
  SetMainTransparency(true);
  SyncPlacement();
  return hwnd_;
}

void HdrVideoHostWindow::SetClientRect(int x, int y, int width, int height) {
  client_rect_ = {x, y, x + width, y + height};
  has_rect_ = width > 0 && height > 0;
  SyncPlacement();
}

void HdrVideoHostWindow::SyncPlacement() {
  if (hwnd_ == nullptr) {
    return;
  }
  if (!has_rect_ || main_ == nullptr || IsIconic(main_) ||
      !IsWindowVisible(main_)) {
    ShowWindow(hwnd_, SW_HIDE);
    return;
  }
  POINT origin = {client_rect_.left, client_rect_.top};
  ClientToScreen(main_, &origin);
  const int width = client_rect_.right - client_rect_.left;
  const int height = client_rect_.bottom - client_rect_.top;
  // hWndInsertAfter = main: immediately below the main window, whatever band
  // (normal / TOPMOST fullscreen) the main window currently lives in. Never
  // touches the main window's own z-order.
  SetWindowPos(hwnd_, main_, origin.x, origin.y, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ResizeChildren();
}

void HdrVideoHostWindow::ResizeChildren() {
  // libmpv (`--wid`) creates its own child window inside the host and only
  // polls the parent size; push the new size explicitly so the picture never
  // lags a resize by a poll interval.
  RECT rc;
  if (GetClientRect(hwnd_, &rc)) {
    EnumChildWindows(hwnd_, ResizeChildProc, reinterpret_cast<LPARAM>(&rc));
  }
}

void HdrVideoHostWindow::SetMainTransparency(bool enable) {
  if (main_ == nullptr) {
    return;
  }
  DWM_BLURBEHIND bb = {};
  bb.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
  bb.fEnable = enable ? TRUE : FALSE;
  HRGN empty = enable ? CreateRectRgn(0, 0, -1, -1) : nullptr;
  bb.hRgnBlur = empty;
  DwmEnableBlurBehindWindow(main_, &bb);
  if (empty != nullptr) {
    DeleteObject(empty);
  }
}

void HdrVideoHostWindow::Destroy() {
  if (hwnd_ == nullptr) {
    return;
  }
  DestroyWindow(hwnd_);
  hwnd_ = nullptr;
  has_rect_ = false;
  SetMainTransparency(false);
}

HdrDisplayInfo QueryHdrDisplayInfo(HWND main) {
  using Microsoft::WRL::ComPtr;
  HdrDisplayInfo info;
  if (main == nullptr) {
    return info;
  }
  const HMONITOR monitor = MonitorFromWindow(main, MONITOR_DEFAULTTONEAREST);
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return info;
  }
  ComPtr<IDXGIAdapter1> adapter;
  for (UINT a = 0; factory->EnumAdapters1(a, &adapter) != DXGI_ERROR_NOT_FOUND;
       ++a) {
    ComPtr<IDXGIOutput> output;
    for (UINT o = 0; adapter->EnumOutputs(o, &output) != DXGI_ERROR_NOT_FOUND;
         ++o) {
      ComPtr<IDXGIOutput6> output6;
      if (FAILED(output.As(&output6))) {
        continue;
      }
      DXGI_OUTPUT_DESC1 desc;
      if (FAILED(output6->GetDesc1(&desc)) || desc.Monitor != monitor) {
        continue;
      }
      info.valid = true;
      info.color_space = static_cast<int>(desc.ColorSpace);
      info.max_luminance = desc.MaxLuminance;
      info.bits_per_color = desc.BitsPerColor;
      return info;
    }
  }
  return info;
}

}  // namespace fushi
