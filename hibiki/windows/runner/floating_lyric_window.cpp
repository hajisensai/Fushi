#include "floating_lyric_window.h"

#include <d2d1helper.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "dwmapi.lib")

namespace {

constexpr wchar_t kWindowClassName[] = L"HibikiFloatingLyricWindow";

// Logical (96-DPI) strip metrics; scaled per-monitor in Render(). The width /
// height defaults seed the initial window; the live size lives in
// strip_width_dip_ / strip_height_dip_ so the resize grip can change it.
constexpr float kStripWidthDip = 720.0f;
constexpr float kStripHeightDip = 96.0f;
constexpr float kCornerRadiusDip = 14.0f;
constexpr float kHorizontalPaddingDip = 20.0f;
constexpr float kButtonSizeDip = 30.0f;
constexpr float kButtonGapDip = 10.0f;
constexpr float kControlsTopDip = 8.0f;
// Bottom-right resize grip and the min / max the user may drag the bar to.
constexpr float kResizeGripDip = 18.0f;
constexpr float kMinStripWidthDip = 280.0f;
constexpr float kMinStripHeightDip = 64.0f;
constexpr float kMaxStripWidthDip = 2400.0f;
constexpr float kMaxStripHeightDip = 480.0f;
// A press must travel this far (logical px) before it becomes a drag rather
// than a word-lookup tap — lets the bar be dragged from anywhere on the text.
constexpr float kDragThresholdDip = 6.0f;
// Base logical font size the lyric text was authored at; the rendered font
// scales with the bar height so growing the bar enlarges the text too.
constexpr float kBaseStripHeightForFontDip = 96.0f;
// Control row slots, in draw / hit-test order: previous, play-pause, next,
// lock, close. The lock button (slot 3) is the TODO-136 addition; both Render()
// and ControlActionAt() derive their geometry from this single count so the
// hit areas can never drift from what is drawn.
constexpr int kControlSlotCount = 5;

// ARGB (0xAARRGGBB) -> D2D1_COLOR_F (straight alpha).
D2D1_COLOR_F ColorFromArgb(uint32_t argb) {
  const float a = ((argb >> 24) & 0xFF) / 255.0f;
  const float r = ((argb >> 16) & 0xFF) / 255.0f;
  const float g = ((argb >> 8) & 0xFF) / 255.0f;
  const float b = (argb & 0xFF) / 255.0f;
  return D2D1::ColorF(r, g, b, a);
}

UINT32 GlyphLength(const wchar_t* glyph) {
  if (glyph == nullptr) {
    return 0;
  }
  return static_cast<UINT32>(std::char_traits<wchar_t>::length(glyph));
}

}  // namespace

FloatingLyricWindow::FloatingLyricWindow() = default;

FloatingLyricWindow::~FloatingLyricWindow() {
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  if (class_registered_) {
    UnregisterClassW(kWindowClassName, GetModuleHandle(nullptr));
  }
}

void FloatingLyricWindow::EnsureWindowClass() {
  if (class_registered_) {
    return;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = FloatingLyricWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kWindowClassName;
  RegisterClassExW(&wc);
  class_registered_ = true;
}

bool FloatingLyricWindow::EnsureDeviceResources() {
  if (d2d_factory_ == nullptr) {
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                   d2d_factory_.GetAddressOf());
    if (FAILED(hr)) {
      return false;
    }
  }
  if (render_target_ == nullptr) {
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        0, 0, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);
    HRESULT hr = d2d_factory_->CreateDCRenderTarget(
        &props, render_target_.GetAddressOf());
    if (FAILED(hr)) {
      render_target_.Reset();
      return false;
    }
  }
  return EnsureTextResources();
}

void FloatingLyricWindow::DiscardDeviceResources() {
  render_target_.Reset();
}

bool FloatingLyricWindow::EnsureTextResources() {
  if (dwrite_factory_ == nullptr) {
    HRESULT hr = DWriteCreateFactory(
        DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
        reinterpret_cast<IUnknown**>(dwrite_factory_.GetAddressOf()));
    if (FAILED(hr)) {
      return false;
    }
  }
  return true;
}

float FloatingLyricWindow::ScaleForDpi(float value) const {
  return value * (static_cast<float>(dpi_) / 96.0f);
}

POINT FloatingLyricWindow::ClampOriginToWorkArea(int x, int y, int width,
                                                 int height,
                                                 const RECT& work) const {
  // TODO-832: keep at least |margin| px of the strip inside the work area on
  // every edge so it can never be dragged / restored fully off-screen. All
  // quantities here are screen physical px (margin already DPI-scaled), the
  // same unit system as Dart clampFloatingWindowOrigin.
  const int margin_x =
      static_cast<int>(ScaleForDpi(kMinVisibleMarginDip));
  // A strip narrower than the margin can at most show its whole width.
  const int margin = margin_x < width ? margin_x : width;
  const int margin_v = margin_x < height ? margin_x : height;

  const int min_x = work.left - (width - margin);
  const int max_x = work.right - margin;
  const int min_y = work.top - (height - margin_v);
  const int max_y = work.bottom - margin_v;

  // When the strip is bigger than the work area min > max; anchor to the lower
  // bound (top-left) instead of ejecting it.
  int clamped_x = x;
  if (min_x > max_x) {
    clamped_x = min_x;
  } else if (clamped_x < min_x) {
    clamped_x = min_x;
  } else if (clamped_x > max_x) {
    clamped_x = max_x;
  }

  int clamped_y = y;
  if (min_y > max_y) {
    clamped_y = min_y;
  } else if (clamped_y < min_y) {
    clamped_y = min_y;
  } else if (clamped_y > max_y) {
    clamped_y = max_y;
  }

  return POINT{clamped_x, clamped_y};
}

void FloatingLyricWindow::ClampCurrentPositionToWindowMonitor() {
  if (hwnd_ == nullptr) {
    return;
  }
  RECT rc;
  if (!GetWindowRect(hwnd_, &rc)) {
    return;
  }
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  HMONITOR monitor = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfo(monitor, &mi)) {
    return;
  }
  const POINT clamped =
      ClampOriginToWorkArea(rc.left, rc.top, width, height, mi.rcWork);
  if (clamped.x != rc.left || clamped.y != rc.top) {
    SetWindowPos(hwnd_, HWND_TOPMOST, clamped.x, clamped.y, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

bool FloatingLyricWindow::Show(HWND owner) {
  EnsureWindowClass();
  if (!EnsureDeviceResources()) {
    return false;
  }

  if (hwnd_ == nullptr) {
    // Initial position: bottom-centre of the active monitor, like a desktop
    // lyric bar. WS_EX_LAYERED for per-pixel alpha, WS_EX_TOPMOST to float over
    // other apps, WS_EX_TOOLWINDOW to keep it off the taskbar / Alt+Tab.
    HMONITOR monitor = MonitorFromWindow(
        owner != nullptr ? owner : GetDesktopWindow(), MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    GetMonitorInfo(monitor, &mi);

    dpi_ = GetDpiForSystem();
    // TODO-708 P2: 首次创建即用设置宽度（>0，夹到拖拽边界），否则历史 720dip 起始宽。
    strip_width_dip_ = style_.window_width > 0.0
                           ? std::clamp(static_cast<float>(style_.window_width),
                                        kMinStripWidthDip, kMaxStripWidthDip)
                           : kStripWidthDip;
    strip_height_dip_ = kStripHeightDip;
    const int width = static_cast<int>(ScaleForDpi(strip_width_dip_));
    const int height = static_cast<int>(ScaleForDpi(strip_height_dip_));
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int x = mi.rcWork.left + (work_w - width) / 2;
    const int y = mi.rcWork.bottom - height - static_cast<int>(ScaleForDpi(48));

    // The strip must be mouse-interactive immediately so the first click after
    // entering the bar cannot fall through to the app below. WS_EX_NOACTIVATE
    // keeps that click from stealing keyboard focus.
    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kWindowClassName, L"Hibiki Lyric", WS_POPUP, x, y, width, height,
        nullptr, nullptr, GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
  }

  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  visible_ = true;
  RequestRender();
  return true;
}

void FloatingLyricWindow::Hide() {
  visible_ = false;
  hovered_ = false;
  tracking_mouse_leave_ = false;
  dragging_ = false;
  if (hwnd_ != nullptr) {
    ShowWindow(hwnd_, SW_HIDE);
  }
}

bool FloatingLyricWindow::IsShowing() const {
  return visible_ && hwnd_ != nullptr && IsWindowVisible(hwnd_);
}

void FloatingLyricWindow::UpdateText(const std::wstring& text) {
  text_ = text;
  highlight_start_ = -1;
  highlight_length_ = 0;
  text_layout_.Reset();
  RequestRender();
}

void FloatingLyricWindow::Highlight(int start, int length) {
  highlight_start_ = start;
  highlight_length_ = length;
  RequestRender();
}

void FloatingLyricWindow::UpdateStyle(const Style& style) {
  style_ = style;
  text_format_.Reset();
  text_layout_.Reset();
  ApplyStyleWidth();
  RequestRender();
}

// TODO-708 P2: 悬浮窗宽度可调。style_.window_width > 0 时把窗口调到该逻辑 dp 宽（夹到
// 与拖拽相同的 [kMinStripWidthDip, kMaxStripWidthDip] 边界），保留左上角原点，再夹回工作
// 区；== 0 时保持当前宽度（历史默认 720dip 起始 + 用户拖拽结果）。文本/控件布局随 WM_SIZE
// 自动跟随，无需重复处理。
void FloatingLyricWindow::ApplyStyleWidth() {
  if (hwnd_ == nullptr || style_.window_width <= 0.0) {
    return;
  }
  const float target_dip =
      std::clamp(static_cast<float>(style_.window_width), kMinStripWidthDip,
                 kMaxStripWidthDip);
  RECT rc;
  if (!GetWindowRect(hwnd_, &rc)) {
    return;
  }
  const int target_px = static_cast<int>(ScaleForDpi(target_dip));
  const int current_px = rc.right - rc.left;
  if (target_px == current_px) {
    return;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, target_px, rc.bottom - rc.top,
               SWP_NOMOVE | SWP_NOACTIVATE);
  ClampCurrentPositionToWindowMonitor();
}

void FloatingLyricWindow::UpdateLabels(const Labels& labels) {
  labels_ = labels;
  RequestRender();
}

void FloatingLyricWindow::SetPlaybackState(bool playing) {
  playing_ = playing;
  RequestRender();
}

void FloatingLyricWindow::SetClickLookupEnabled(bool enabled) {
  click_lookup_enabled_ = enabled;
}

void FloatingLyricWindow::SetLocked(bool locked) {
  if (locked_ == locked) {
    return;
  }
  locked_ = locked;
  // A lock taken while a press / drag was pending must not strand the strip in
  // a half-dragging state; drop any in-flight gesture so the next click is
  // interpreted fresh.
  if (locked_ && (pressed_ || dragging_)) {
    pressed_ = false;
    dragging_ = false;
    if (GetCapture() == hwnd_) {
      ReleaseCapture();
    }
  }
  RequestRender();
}

void FloatingLyricWindow::RequestRender() {
  if (hwnd_ != nullptr && visible_) {
    Render();
  }
}

LRESULT CALLBACK FloatingLyricWindow::WndProc(HWND hwnd, UINT message,
                                              WPARAM wparam,
                                              LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    auto* self = static_cast<FloatingLyricWindow*>(create->lpCreateParams);
    self->hwnd_ = hwnd;
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<FloatingLyricWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMessage(message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT FloatingLyricWindow::HandleMessage(UINT message, WPARAM wparam,
                                           LPARAM lparam) noexcept {
  switch (message) {
    case WM_MOUSEMOVE: {
      // Mouse messages arrive immediately because the strip is not born
      // transparent. Here we drive hover affordances, drag, and the press->drag
      // promotion.
      if (!hovered_) {
        hovered_ = true;
        RequestRender();
      }
      if (!tracking_mouse_leave_) {
        TRACKMOUSEEVENT tme = {};
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE;
        tme.hwndTrack = hwnd_;
        if (TrackMouseEvent(&tme)) {
          tracking_mouse_leave_ = true;
        }
      }
      if (dragging_) {
        POINT cursor;
        GetCursorPos(&cursor);
        int new_x = cursor.x - drag_anchor_.x;
        int new_y = cursor.y - drag_anchor_.y;
        // TODO-832: clamp against the work area of the monitor under the
        // cursor (not the window's old monitor) so the strip can never be
        // dragged off-screen yet still slides freely across displays.
        RECT rc;
        GetWindowRect(hwnd_, &rc);
        const int width = rc.right - rc.left;
        const int height = rc.bottom - rc.top;
        HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi = {};
        mi.cbSize = sizeof(mi);
        if (GetMonitorInfo(monitor, &mi)) {
          const POINT clamped =
              ClampOriginToWorkArea(new_x, new_y, width, height, mi.rcWork);
          new_x = clamped.x;
          new_y = clamped.y;
        }
        SetWindowPos(hwnd_, HWND_TOPMOST, new_x, new_y, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE);
        return 0;
      }
      // A pending press becomes a drag once the cursor travels past the
      // threshold — but only when the strip is not position-locked. This is the
      // fix for BUG-205: the bar is now draggable from anywhere on the text,
      // while a press that does NOT move is still treated as a word-lookup tap.
      if (pressed_ && !locked_) {
        POINT cursor;
        GetCursorPos(&cursor);
        const int dx = cursor.x - press_origin_.x;
        const int dy = cursor.y - press_origin_.y;
        const int threshold = static_cast<int>(ScaleForDpi(kDragThresholdDip));
        if (dx * dx + dy * dy >= threshold * threshold) {
          RECT rc;
          GetWindowRect(hwnd_, &rc);
          drag_anchor_.x = cursor.x - rc.left;
          drag_anchor_.y = cursor.y - rc.top;
          dragging_ = true;
        }
      }
      return 0;
    }
    case WM_MOUSELEAVE: {
      tracking_mouse_leave_ = false;
      if (hovered_ && !dragging_) {
        hovered_ = false;
        RequestRender();
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const float x = static_cast<float>(GET_X_LPARAM(lparam));
      const float y = static_cast<float>(GET_Y_LPARAM(lparam));

      // 1. Control buttons (prev / play-pause / next / lock / close) win first.
      const std::string action = ControlActionAt(x, y);
      if (action == "lock") {
        // The lock button toggles the position lock locally and reports the new
        // state to Dart; it is never a no-op (unlike the old desktop strip).
        locked_ = !locked_;
        if (locked_ && (pressed_ || dragging_)) {
          pressed_ = false;
          dragging_ = false;
        }
        if (on_lock_) {
          on_lock_(locked_);
        }
        RequestRender();
        return 0;
      }
      if (!action.empty()) {
        if (on_control_) {
          on_control_(action);
        }
        return 0;
      }

      // 2. Otherwise this is a pending press over the body of the strip. We do
      // NOT decide lookup-vs-drag yet: a still press is a lookup on button-up,
      // a moving press is promoted to a drag in WM_MOUSEMOVE.
      POINT cursor;
      GetCursorPos(&cursor);
      pressed_ = true;
      dragging_ = false;
      press_origin_ = cursor;
      press_client_.x = static_cast<LONG>(x);
      press_client_.y = static_cast<LONG>(y);
      press_was_text_ =
          click_lookup_enabled_ && CharIndexAt(x, y) >= 0 && on_lookup_;
      SetCapture(hwnd_);
      return 0;
    }
    case WM_LBUTTONUP: {
      const bool was_dragging = dragging_;
      const bool was_pressed = pressed_;
      const bool was_text = press_was_text_;
      const POINT lookup_pt = press_client_;
      dragging_ = false;
      pressed_ = false;
      press_was_text_ = false;
      if (GetCapture() == hwnd_) {
        ReleaseCapture();
      }
      POINT cursor;
      if (GetCursorPos(&cursor)) {
        RECT rc;
        if (GetWindowRect(hwnd_, &rc) && !PtInRect(&rc, cursor) && hovered_) {
          hovered_ = false;
          tracking_mouse_leave_ = false;
          RequestRender();
        }
      }
      // A press that never moved into a drag over the lyric text fires the word
      // lookup now — single-tap lookup preserved.
      if (!was_dragging && was_pressed && was_text && on_lookup_) {
        const int index = CharIndexAt(static_cast<float>(lookup_pt.x),
                                      static_cast<float>(lookup_pt.y));
        if (index >= 0) {
          int utf8_len = WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                                             static_cast<int>(text_.size()),
                                             nullptr, 0, nullptr, nullptr);
          std::string utf8(utf8_len, '\0');
          WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                              static_cast<int>(text_.size()), utf8.data(),
                              utf8_len, nullptr, nullptr);
          on_lookup_(utf8, index);
        }
      }
      return 0;
    }
    case WM_NCHITTEST: {
      // Hand the bottom-right grip to the system resize loop so the user can
      // drag the corner to grow / shrink the bar (QQ-Music style). Everywhere
      // else stays HTCLIENT so our own mouse handlers (lookup / drag / control
      // buttons) keep receiving WM_LBUTTON*.
      POINT screen = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      POINT client = screen;
      ScreenToClient(hwnd_, &client);
      if (ResizeGripContains(static_cast<float>(client.x),
                             static_cast<float>(client.y))) {
        return HTBOTTOMRIGHT;
      }
      return HTCLIENT;
    }
    case WM_SIZE: {
      // A system resize (corner drag) changed the window rect; recompute the
      // logical strip size and re-render so the text + controls follow.
      SyncStripSizeFromWindow();
      text_format_.Reset();
      text_layout_.Reset();
      RequestRender();
      return 0;
    }
    case WM_GETMINMAXINFO: {
      // Clamp the system resize to the same sane bounds the bar is authored
      // for, so the user cannot drag it to an unusable size.
      auto* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
      mmi->ptMinTrackSize.x = static_cast<LONG>(ScaleForDpi(kMinStripWidthDip));
      mmi->ptMinTrackSize.y = static_cast<LONG>(ScaleForDpi(kMinStripHeightDip));
      mmi->ptMaxTrackSize.x = static_cast<LONG>(ScaleForDpi(kMaxStripWidthDip));
      mmi->ptMaxTrackSize.y = static_cast<LONG>(ScaleForDpi(kMaxStripHeightDip));
      return 0;
    }
    case WM_DPICHANGED: {
      dpi_ = HIWORD(wparam);
      DiscardDeviceResources();
      EnsureDeviceResources();
      // TODO-832: a DPI change (e.g. dragged to a different-scale monitor, or
      // the user changed scaling) can leave the strip partly off the new work
      // area. The cursor isn't necessarily over the window here, so clamp
      // against the window's own monitor work area, not the cursor's.
      ClampCurrentPositionToWindowMonitor();
      RequestRender();
      return 0;
    }
    case WM_DISPLAYCHANGE: {
      // TODO-832: resolution / monitor hot-plug can shrink or remove the work
      // area the strip was sitting in; pull it back so ≥ kMinVisibleMarginDip
      // stays grabbable. Use the window's monitor (cursor may be elsewhere).
      ClampCurrentPositionToWindowMonitor();
      RequestRender();
      return 0;
    }
    default:
      return DefWindowProc(hwnd_, message, wparam, lparam);
  }
}

void FloatingLyricWindow::Render() {
  if (hwnd_ == nullptr || !EnsureDeviceResources()) {
    return;
  }

  RECT rc;
  GetClientRect(hwnd_, &rc);
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  if (width <= 0 || height <= 0) {
    return;
  }

  // Render into a 32-bpp top-down DIB, then push it to the layered window for
  // true per-pixel alpha (translucent rounded strip over the desktop).
  HDC screen_dc = GetDC(nullptr);
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HBITMAP old_bmp = static_cast<HBITMAP>(SelectObject(mem_dc, dib));

  RECT bind_rect = {0, 0, width, height};
  if (FAILED(render_target_->BindDC(mem_dc, &bind_rect))) {
    SelectObject(mem_dc, old_bmp);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return;
  }

  render_target_->BeginDraw();
  render_target_->Clear(D2D1::ColorF(0, 0, 0, 0));

  // TODO-708 P2: 圆角半径可调。style_.corner_radius > 0 时用设置值，否则回退历史 14dp。
  const float corner_dip = style_.corner_radius > 0.0
                               ? static_cast<float>(style_.corner_radius)
                               : kCornerRadiusDip;
  const float corner = ScaleForDpi(corner_dip);
  D2D1_ROUNDED_RECT bg_rect = D2D1::RoundedRect(
      D2D1::RectF(0, 0, static_cast<float>(width), static_cast<float>(height)),
      corner, corner);

  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush;
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.bg_color),
                                        brush.GetAddressOf());
  render_target_->FillRoundedRectangle(bg_rect, brush.Get());

  // Text format / layout. The authored font size assumes the default bar
  // height; the live font scales with strip_height_dip_ so dragging the resize
  // grip larger enlarges the lyric text too.
  if (text_format_ == nullptr) {
    const float height_scale =
        strip_height_dip_ / kBaseStripHeightForFontDip;
    const float scaled_font = static_cast<float>(style_.font_size) *
                              std::max(0.5f, height_scale);
    dwrite_factory_->CreateTextFormat(
        L"Yu Gothic UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
        static_cast<float>(ScaleForDpi(scaled_font)),
        L"", text_format_.GetAddressOf());
    if (text_format_ != nullptr) {
      text_format_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
      text_format_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
      text_format_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    text_layout_.Reset();
  }

  const float pad = ScaleForDpi(kHorizontalPaddingDip);
  const float controls_h =
      ScaleForDpi(kButtonSizeDip) + ScaleForDpi(kControlsTopDip);
  text_rect_.left = pad;
  text_rect_.top = controls_h;
  text_rect_.width = std::max(1.0f, width - pad * 2);
  text_rect_.height = std::max(1.0f, height - controls_h - pad * 0.5f);

  if (text_format_ != nullptr && !text_.empty()) {
    if (text_layout_ == nullptr) {
      dwrite_factory_->CreateTextLayout(text_.c_str(),
                                        static_cast<UINT32>(text_.size()),
                                        text_format_.Get(), text_rect_.width,
                                        text_rect_.height,
                                        text_layout_.GetAddressOf());
    }
    if (text_layout_ != nullptr) {
      // Highlight range background.
      if (highlight_start_ >= 0 && highlight_length_ > 0) {
        DWRITE_TEXT_RANGE range = {static_cast<UINT32>(highlight_start_),
                                   static_cast<UINT32>(highlight_length_)};
        UINT32 hit_count = 0;
        text_layout_->HitTestTextRange(range.startPosition, range.length, 0, 0,
                                       nullptr, 0, &hit_count);
        if (hit_count > 0) {
          std::vector<DWRITE_HIT_TEST_METRICS> metrics(hit_count);
          text_layout_->HitTestTextRange(range.startPosition, range.length, 0,
                                         0, metrics.data(), hit_count,
                                         &hit_count);
          Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> hl;
          render_target_->CreateSolidColorBrush(
              ColorFromArgb(style_.highlight_color), hl.GetAddressOf());
          for (const auto& m : metrics) {
            D2D1_ROUNDED_RECT hr = D2D1::RoundedRect(
                D2D1::RectF(text_rect_.left + m.left, text_rect_.top + m.top,
                            text_rect_.left + m.left + m.width,
                            text_rect_.top + m.top + m.height),
                ScaleForDpi(4), ScaleForDpi(4));
            render_target_->FillRoundedRectangle(hr, hl.Get());
          }
        }
      }
      brush->SetColor(ColorFromArgb(style_.text_color));
      render_target_->DrawTextLayout(
          D2D1::Point2F(text_rect_.left, text_rect_.top), text_layout_.Get(),
          brush.Get(), D2D1_DRAW_TEXT_OPTIONS_NONE);
    }
  }

  // Controls row (only fully visible while hovered, like QQ Music). The hit
  // areas in ControlActionAt() stay live regardless so a deliberate click on a
  // half-faded button still works.
  const float btn = ScaleForDpi(kButtonSizeDip);
  const float gap = ScaleForDpi(kButtonGapDip);
  const float ctrl_top = ScaleForDpi(kControlsTopDip);
  const float controls_total =
      btn * kControlSlotCount + gap * (kControlSlotCount - 1);
  const float ctrl_left = (width - controls_total) / 2.0f;
  const float control_alpha = hovered_ ? 1.0f : 0.35f;

  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_bg;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_fg;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_active;
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_bg_color),
                                        btn_bg.GetAddressOf());
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_text_color),
                                        btn_fg.GetAddressOf());
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.active_color),
                                        btn_active.GetAddressOf());
  btn_bg->SetOpacity(control_alpha);
  btn_fg->SetOpacity(control_alpha);
  btn_active->SetOpacity(control_alpha);

  auto draw_glyph = [&](int slot, const wchar_t* glyph, bool active) {
    const float bx = ctrl_left + slot * (btn + gap);
    D2D1_ROUNDED_RECT br = D2D1::RoundedRect(
        D2D1::RectF(bx, ctrl_top, bx + btn, ctrl_top + btn),
        ScaleForDpi(6), ScaleForDpi(6));
    render_target_->FillRoundedRectangle(br, btn_bg.Get());
    Microsoft::WRL::ComPtr<IDWriteTextFormat> glyph_fmt;
    dwrite_factory_->CreateTextFormat(
        L"Segoe UI Symbol", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, btn * 0.5f, L"",
        glyph_fmt.GetAddressOf());
    if (glyph_fmt != nullptr) {
      glyph_fmt->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
      glyph_fmt->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
      render_target_->DrawTextW(
          glyph, GlyphLength(glyph), glyph_fmt.Get(),
          D2D1::RectF(bx, ctrl_top, bx + btn, ctrl_top + btn),
          active ? btn_active.Get() : btn_fg.Get());
    }
  };

  draw_glyph(0, L"⏮", false);                       // previous
  draw_glyph(1, playing_ ? L"⏸" : L"▶", false);  // pause / play
  draw_glyph(2, L"⏭", false);                       // next
  // Lock: padlock glyph, tinted with the active colour while locked so the
  // state is visible at a glance (mirrors the Android lock button).
  draw_glyph(3, locked_ ? L"\U0001F512" : L"\U0001F513", locked_);  // lock
  draw_glyph(4, L"✕", false);                        // close

  // Bottom-right resize grip: three short diagonal ticks hinting the corner can
  // be dragged to size the bar.
  {
    const float grip = ScaleForDpi(kResizeGripDip);
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> grip_brush;
    render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_text_color),
                                          grip_brush.GetAddressOf());
    grip_brush->SetOpacity(control_alpha * 0.7f);
    const float stroke = std::max(1.0f, ScaleForDpi(1.5f));
    for (int i = 1; i <= 3; ++i) {
      const float off = grip * (i / 4.0f);
      render_target_->DrawLine(
          D2D1::Point2F(width - off, height - 2.0f),
          D2D1::Point2F(width - 2.0f, height - off), grip_brush.Get(), stroke);
    }
  }

  HRESULT hr = render_target_->EndDraw();
  if (hr == D2DERR_RECREATE_TARGET) {
    DiscardDeviceResources();
  }

  // Push the rendered DIB to the layered window.
  POINT src = {0, 0};
  SIZE size = {width, height};
  RECT wr;
  GetWindowRect(hwnd_, &wr);
  POINT dst = {wr.left, wr.top};
  BLENDFUNCTION blend = {};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(hwnd_, screen_dc, &dst, &size, mem_dc, &src, 0, &blend,
                      ULW_ALPHA);

  SelectObject(mem_dc, old_bmp);
  DeleteObject(dib);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
}

std::string FloatingLyricWindow::ControlActionAt(float x, float y) {
  RECT rc;
  GetClientRect(hwnd_, &rc);
  const float width = static_cast<float>(rc.right - rc.left);
  const float btn = ScaleForDpi(kButtonSizeDip);
  const float gap = ScaleForDpi(kButtonGapDip);
  const float ctrl_top = ScaleForDpi(kControlsTopDip);
  const float controls_total =
      btn * kControlSlotCount + gap * (kControlSlotCount - 1);
  const float ctrl_left = (width - controls_total) / 2.0f;
  if (y < ctrl_top || y > ctrl_top + btn) {
    return std::string();
  }
  for (int slot = 0; slot < kControlSlotCount; ++slot) {
    const float bx = ctrl_left + slot * (btn + gap);
    if (x >= bx && x <= bx + btn) {
      switch (slot) {
        case 0:
          return "previousCue";
        case 1:
          return "playPause";
        case 2:
          return "nextCue";
        case 3:
          return "lock";
        case 4:
          return "close";
        default:
          return std::string();
      }
    }
  }
  return std::string();
}

bool FloatingLyricWindow::ResizeGripContains(float x, float y) const {
  if (hwnd_ == nullptr) {
    return false;
  }
  RECT rc;
  GetClientRect(hwnd_, &rc);
  const float width = static_cast<float>(rc.right - rc.left);
  const float height = static_cast<float>(rc.bottom - rc.top);
  const float grip = ScaleForDpi(kResizeGripDip);
  return x >= width - grip && x <= width && y >= height - grip && y <= height;
}

void FloatingLyricWindow::SyncStripSizeFromWindow() {
  if (hwnd_ == nullptr) {
    return;
  }
  RECT rc;
  GetWindowRect(hwnd_, &rc);
  const float scale = static_cast<float>(dpi_) / 96.0f;
  if (scale <= 0.0f) {
    return;
  }
  strip_width_dip_ = static_cast<float>(rc.right - rc.left) / scale;
  strip_height_dip_ = static_cast<float>(rc.bottom - rc.top) / scale;
}

int FloatingLyricWindow::CharIndexAt(float x, float y) {
  if (text_.empty() || text_layout_ == nullptr) {
    return -1;
  }
  const float local_x = x - text_rect_.left;
  const float local_y = y - text_rect_.top;
  if (local_x < 0 || local_x > text_rect_.width || local_y < 0 ||
      local_y > text_rect_.height) {
    return -1;
  }
  BOOL is_trailing = FALSE;
  BOOL is_inside = FALSE;
  DWRITE_HIT_TEST_METRICS metrics = {};
  if (FAILED(text_layout_->HitTestPoint(local_x, local_y, &is_trailing,
                                        &is_inside, &metrics))) {
    return -1;
  }
  if (!is_inside) {
    return -1;
  }
  return static_cast<int>(metrics.textPosition);
}
