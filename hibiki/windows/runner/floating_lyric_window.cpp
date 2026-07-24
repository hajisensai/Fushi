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
// Hook mode draws a centred 8-slot toolbar (8 * 30 + 7 * 10 = 310dip). The
// generic 280dip floor would let the user drag the window narrower than its own
// controls, clipping the leading voice buttons; hook mode therefore floors at
// the toolbar width plus a small margin.
constexpr float kHookTextMinStripWidthDip = 330.0f;
constexpr float kMinStripHeightDip = 64.0f;
constexpr float kMaxStripWidthDip = 2400.0f;
constexpr float kMaxStripHeightDip = 480.0f;
// A press must travel this far (logical px) before it becomes a drag rather
// than a word-lookup tap — lets the bar be dragged from anywhere on the text.
constexpr float kDragThresholdDip = 6.0f;
// Base logical font size the lyric text was authored at; the rendered font
// scales with the bar height so growing the bar enlarges the text too.
constexpr float kBaseStripHeightForFontDip = 96.0f;
// Hook mode authors its font against its own default window height (140dip) and
// scales with the live height, so dragging the overlay taller enlarges the
// caption instead of leaving it stranded at the authored size. Clamped so a
// deliberately short, wide overlay (hugging the game's text box) never shrinks
// the text below readability.
constexpr float kHookTextBaseHeightForFontDip = 140.0f;
constexpr float kHookTextFontScaleMin = 0.9f;
constexpr float kHookTextFontScaleMax = 2.5f;
// Control row slots, in draw / hit-test order: previous, play-pause, next,
// lock, close. The lock button (slot 3) is the TODO-136 addition; both Render()
// and ControlActionAt() derive their geometry from this single count so the
// hit areas can never drift from what is drawn.
constexpr int kControlSlotCount = 5;
// Hook text toolbar slots, in draw / hit-test order: replay voice, replay +
// recapture, follow, click-through, transparency, lock, workbench, close. The
// two leading slots are the voice controls (replay the line's captured audio;
// open a recapture window so the user can replay the line inside the game and
// have it recorded onto that line).
constexpr int kHookTextControlSlotCount = 8;

// Text-only clipboard window (Luna-style hover toolbar). A thin top strip is
// ALWAYS a mouse catch (drawn at ~2% alpha across the full width) so the fully
// transparent window can always be grabbed to move + can reveal its toolbar,
// while the body below stays truly transparent (click-through to the game). At
// rest only a small centre grip pill hints the handle; on hover the strip
// brightens and the lock + one-click-transparency buttons appear. Text-only
// hit-testing / drawing derive geometry from these so the hit areas can never
// drift from what is drawn.
constexpr float kTextGripWidthDip = 40.0f;
constexpr float kTextGripHeightDip = 4.0f;
constexpr float kTextGripTopDip = 9.0f;
constexpr float kTextStripRestAlpha = 0.02f;   // near-invisible, still catchable
constexpr float kTextStripHoverAlpha = 0.55f;  // visible toolbar band on hover

// BUG-1046: hook-text overlay body alpha floor. UpdateLayeredWindow windows are
// hit-tested per PIXEL — alpha-0 pixels pass clicks through to the window
// below no matter what WM_NCHITTEST returns. With the background hidden
// (opacity 0) the whole body painted at alpha 0 made the caption text
// unclickable (only the thin glyph pixels ever hit). Clamp the body fill to a
// near-invisible minimum while the window is interactive; an explicit
// pass-through toggle keeps true alpha 0 (clicks are MEANT to fall through).
constexpr uint32_t kHookTextMinCatchAlpha = 5;  // ~2%, invisible but hittable

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
    SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, clamped.x, clamped.y, 0, 0,
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
                                        MinStripWidthDip(), kMaxStripWidthDip)
                           : kStripWidthDip;
    strip_height_dip_ = style_.window_height > 0.0
                            ? std::clamp(
                                  static_cast<float>(style_.window_height),
                                  kMinStripHeightDip, kMaxStripHeightDip)
                            : kStripHeightDip;
    const int width = static_cast<int>(ScaleForDpi(strip_width_dip_));
    const int height = static_cast<int>(ScaleForDpi(strip_height_dip_));
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int x = mi.rcWork.left + (work_w - width) / 2;
    const int y = mi.rcWork.bottom - height - static_cast<int>(ScaleForDpi(48));

    // The strip must be mouse-interactive immediately so the first click after
    // entering the bar cannot fall through to the app below. WS_EX_NOACTIVATE
    // keeps that click from stealing keyboard focus. The text-only clipboard
    // window uses WS_EX_APPWINDOW so it shows in the taskbar / Alt+Tab as a
    // selectable window (the transparent overlay is otherwise easy to lose); the
    // lyric strip keeps WS_EX_TOOLWINDOW to stay off the taskbar.
    const DWORD taskbar_ex =
        (text_only_ && !hook_text_mode_) ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW;
    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | taskbar_ex | WS_EX_NOACTIVATE,
        kWindowClassName,
        hook_text_mode_ ? L"Hibiki Hook Text" : window_title_.c_str(),
        WS_POPUP, x, y, width, height,
        nullptr, nullptr, GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
    if (has_initial_bounds_) {
      const int restored_width = initial_bounds_.right - initial_bounds_.left;
      const int restored_height = initial_bounds_.bottom - initial_bounds_.top;
      if (restored_width > 0 && restored_height > 0) {
        SetWindowPos(hwnd_, HWND_TOPMOST, initial_bounds_.left,
                     initial_bounds_.top, restored_width, restored_height,
                     SWP_NOACTIVATE);
        SyncStripSizeFromWindow();
        ClampCurrentPositionToWindowMonitor();
      }
    }
  }

  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
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

void FloatingLyricWindow::UpdateText(const std::wstring& text,
                                    int current_line_start,
                                    int current_line_length,
                                    const std::string& context_id) {
  text_ = text;
  context_id_ = context_id;
  current_line_start_ = current_line_start;
  current_line_length_ = current_line_length;
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
      std::clamp(static_cast<float>(style_.window_width), MinStripWidthDip(),
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
  SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0,
               target_px, rc.bottom - rc.top,
               SWP_NOMOVE | SWP_NOACTIVATE);
  ClampCurrentPositionToWindowMonitor();
}

void FloatingLyricWindow::SetWindowTitle(const std::wstring& title) {
  if (title.empty()) {
    return;
  }
  window_title_ = title;
  if (hwnd_ != nullptr) {
    SetWindowTextW(hwnd_, window_title_.c_str());
  }
}

void FloatingLyricWindow::UpdateLabels(const Labels& labels) {
  labels_ = labels;
  RequestRender();
}

void FloatingLyricWindow::SetPlaybackState(bool playing) {
  playing_ = playing;
  RequestRender();
}

float FloatingLyricWindow::MinStripWidthDip() const {
  return hook_text_mode_ ? kHookTextMinStripWidthDip : kMinStripWidthDip;
}

void FloatingLyricWindow::SetVoiceState(bool replaying, bool recapturing) {
  if (replaying_ == replaying && recapturing_ == recapturing) {
    return;
  }
  replaying_ = replaying;
  recapturing_ = recapturing;
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

void FloatingLyricWindow::SetPassThrough(bool enabled) {
  if (pass_through_ == enabled) {
    return;
  }
  pass_through_ = enabled;
  pressed_ = false;
  dragging_ = false;
  if (GetCapture() == hwnd_) {
    ReleaseCapture();
  }
  RequestRender();
}

void FloatingLyricWindow::SetInitialBounds(int left, int top, int width,
                                           int height) {
  if (width <= 0 || height <= 0) {
    has_initial_bounds_ = false;
    return;
  }
  initial_bounds_ = {left, top, left + width, top + height};
  has_initial_bounds_ = true;
  if (hwnd_ != nullptr) {
    SetWindowPos(hwnd_, HWND_TOPMOST, left, top, width, height,
                 SWP_NOACTIVATE);
    SyncStripSizeFromWindow();
    ClampCurrentPositionToWindowMonitor();
    RequestRender();
  }
}

void FloatingLyricWindow::NotifyBoundsChanged() {
  if (hwnd_ == nullptr || !on_bounds_) {
    return;
  }
  RECT rect;
  if (!GetWindowRect(hwnd_, &rect)) {
    return;
  }
  on_bounds_(rect.left, rect.top, rect.right - rect.left,
             rect.bottom - rect.top);
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
        SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, new_x, new_y, 0, 0,
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
      if (action == "topmost") {
        // The text-only Luna toolbar pin button: toggle always-on-top locally
        // (LunaTranslator #36). Handled natively — no Dart round-trip — and every
        // window-Z SetWindowPos reads topmost_ so the new state sticks.
        topmost_ = !topmost_;
        SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
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
      press_was_text_ = click_lookup_enabled_ && CharIndexAt(x, y) >= 0 &&
                        (on_lookup_ || on_context_lookup_);
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
      if (!was_dragging && was_pressed && was_text &&
          (on_lookup_ || on_context_lookup_)) {
        D2D1_RECT_F char_rect = {};
        const int index = CharIndexAt(static_cast<float>(lookup_pt.x),
                                      static_cast<float>(lookup_pt.y),
                                      &char_rect);
        if (index >= 0) {
          int utf8_len = WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                                             static_cast<int>(text_.size()),
                                             nullptr, 0, nullptr, nullptr);
          std::string utf8(utf8_len, '\0');
          WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                              static_cast<int>(text_.size()), utf8.data(),
                              utf8_len, nullptr, nullptr);
          if (on_context_lookup_) {
            // Client-area physical px -> screen logical px: the lookup card
            // anchors to the tapped word, so it must be in the same unit
            // system Dart uses for screen rects.
            const float scale = std::max(0.01f, static_cast<float>(dpi_) / 96.0f);
            RECT wr = {};
            GetWindowRect(hwnd_, &wr);
            const D2D1_RECT_F screen_rect = D2D1::RectF(
                (wr.left + char_rect.left) / scale,
                (wr.top + char_rect.top) / scale,
                (wr.left + char_rect.right) / scale,
                (wr.top + char_rect.bottom) / scale);
            on_context_lookup_(context_id_, utf8, index, screen_rect);
          } else if (on_lookup_) {
            on_lookup_(utf8, index);
          }
        }
      }
      if (was_dragging) {
        NotifyBoundsChanged();
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
      if (hook_text_mode_ && pass_through_) {
        const float recovery_height =
            ScaleForDpi(kControlsTopDip + kButtonSizeDip);
        if (static_cast<float>(client.y) > recovery_height) {
          return HTTRANSPARENT;
        }
      }
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
    case WM_EXITSIZEMOVE: {
      SyncStripSizeFromWindow();
      ClampCurrentPositionToWindowMonitor();
      NotifyBoundsChanged();
      return 0;
    }
    case WM_GETMINMAXINFO: {
      // Clamp the system resize to the same sane bounds the bar is authored
      // for, so the user cannot drag it to an unusable size.
      auto* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
      mmi->ptMinTrackSize.x = static_cast<LONG>(ScaleForDpi(MinStripWidthDip()));
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

  // BUG-1046: keep the interactive hook-text body hit-testable when the user
  // hides the background — floor the fill alpha (see kHookTextMinCatchAlpha).
  uint32_t body_bg = style_.bg_color;
  if (hook_text_mode_ && !pass_through_ &&
      (body_bg >> 24) < kHookTextMinCatchAlpha) {
    body_bg = (kHookTextMinCatchAlpha << 24) | (body_bg & 0x00FFFFFF);
  }
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush;
  render_target_->CreateSolidColorBrush(ColorFromArgb(body_bg),
                                        brush.GetAddressOf());
  render_target_->FillRoundedRectangle(bg_rect, brush.Get());

  // Text format / layout. The authored font size assumes the default bar
  // height; the live font scales with strip_height_dip_ so dragging the resize
  // grip larger enlarges the lyric text too.
  if (text_format_ == nullptr) {
    const float height_scale =
        hook_text_mode_
            ? std::clamp(strip_height_dip_ / kHookTextBaseHeightForFontDip,
                         kHookTextFontScaleMin, kHookTextFontScaleMax)
            : strip_height_dip_ / kBaseStripHeightForFontDip;
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
      text_format_->SetWordWrapping(
          hook_text_mode_ ? DWRITE_WORD_WRAPPING_WRAP
                          : DWRITE_WORD_WRAPPING_NO_WRAP);
    }
    text_layout_.Reset();
  }

  const float pad = ScaleForDpi(kHorizontalPaddingDip);
  const float controls_h =
      ScaleForDpi(kButtonSizeDip) + ScaleForDpi(kControlsTopDip);
  // Both modes reserve controls_h at the top: the lyric strip for its transport
  // row, the text-only clipboard window for its thin Luna-style hover toolbar
  // (the text sits below the strip so the toolbar never overlaps it).
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
      // TODO-708 P4: 多行上下文——当前行满 text_color，其余行降 alpha(~55%)。用
      // per-range SetDrawingEffect 挂 dim 画刷（D2D DrawTextLayout 会以此覆盖该 range
      // 的前景色）。current_line_start_<0（N=0 单行/无标记）时不设 dim，整块满色 =
      // 今天观感（never-break userspace）。与 word 级 highlight 背景框正交。
      Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> dim_brush;
      const int text_len = static_cast<int>(text_.size());
      if (current_line_start_ >= 0 && current_line_length_ > 0 &&
          text_len > 0) {
        const uint32_t base = style_.text_color;
        const uint32_t base_alpha = (base >> 24) & 0xFF;
        const uint32_t dim_alpha =
            static_cast<uint32_t>(base_alpha * 0.55f) & 0xFF;
        const uint32_t dim_argb = (dim_alpha << 24) | (base & 0x00FFFFFF);
        render_target_->CreateSolidColorBrush(ColorFromArgb(dim_argb),
                                              dim_brush.GetAddressOf());
        if (dim_brush != nullptr) {
          const int cur_start =
              std::clamp(current_line_start_, 0, text_len);
          const int cur_end = std::clamp(
              current_line_start_ + current_line_length_, cur_start, text_len);
          if (cur_start > 0) {
            DWRITE_TEXT_RANGE pre = {0, static_cast<UINT32>(cur_start)};
            text_layout_->SetDrawingEffect(dim_brush.Get(), pre);
          }
          if (cur_end < text_len) {
            DWRITE_TEXT_RANGE post = {
                static_cast<UINT32>(cur_end),
                static_cast<UINT32>(text_len - cur_end)};
            text_layout_->SetDrawingEffect(dim_brush.Get(), post);
          }
        }
      }
      render_target_->DrawTextLayout(
          D2D1::Point2F(text_rect_.left, text_rect_.top), text_layout_.Get(),
          brush.Get(), D2D1_DRAW_TEXT_OPTIONS_NONE);
    }
  }

  if (text_only_) {
    // Luna-style hover toolbar for the transparent clipboard window: a thin top
    // strip that is ALWAYS a mouse catch (so the transparent window can be
    // grabbed to move + can reveal its controls), showing only a grip hint at
    // rest and the lock + one-click-transparency buttons on hover. Geometry
    // mirrors ControlActionAt(text_only_) exactly.
    const float t_btn = ScaleForDpi(kButtonSizeDip);
    const float t_pad = ScaleForDpi(kHorizontalPaddingDip);
    const float t_gap = ScaleForDpi(kButtonGapDip);
    const float t_top = ScaleForDpi(kControlsTopDip);
    const float strip_h = t_top + t_btn;

    // Full-width strip background: near-invisible at rest (still catches the
    // mouse so the top edge is always grabbable), a visible band on hover so the
    // whole strip stays catchable while sliding across to the buttons.
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> strip_bg;
    render_target_->CreateSolidColorBrush(ColorFromArgb(style_.bg_color | 0xFF000000),
                                          strip_bg.GetAddressOf());
    strip_bg->SetOpacity(hovered_ ? kTextStripHoverAlpha : kTextStripRestAlpha);
    D2D1_ROUNDED_RECT strip_rect = D2D1::RoundedRect(
        D2D1::RectF(0, 0, static_cast<float>(width), strip_h),
        ScaleForDpi(6), ScaleForDpi(6));
    render_target_->FillRoundedRectangle(strip_rect, strip_bg.Get());

    // Centre grip pill — the visible move handle (brighter on hover).
    const float grip_w = ScaleForDpi(kTextGripWidthDip);
    const float grip_h = ScaleForDpi(kTextGripHeightDip);
    const float grip_x = (width - grip_w) / 2.0f;
    const float grip_y = ScaleForDpi(kTextGripTopDip);
    Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> grip_brush;
    render_target_->CreateSolidColorBrush(ColorFromArgb(style_.text_color),
                                          grip_brush.GetAddressOf());
    grip_brush->SetOpacity(hovered_ ? 0.9f : 0.28f);
    D2D1_ROUNDED_RECT grip_rect = D2D1::RoundedRect(
        D2D1::RectF(grip_x, grip_y, grip_x + grip_w, grip_y + grip_h),
        grip_h / 2.0f, grip_h / 2.0f);
    render_target_->FillRoundedRectangle(grip_rect, grip_brush.Get());

    // Controls appear only on hover. Clipboard mode keeps its historical
    // right-aligned buttons (transparency, pin/topmost, lock); Hook mode uses a
    // centred six-button core toolbar. Their hit areas in ControlActionAt() are
    // gated on hovered_ too, so a click can never hit an invisible button.
    if (hovered_) {
      Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> tb_bg;
      Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> tb_fg;
      Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> tb_active;
      render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_bg_color),
                                            tb_bg.GetAddressOf());
      render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_text_color),
                                            tb_fg.GetAddressOf());
      render_target_->CreateSolidColorBrush(ColorFromArgb(style_.active_color),
                                            tb_active.GetAddressOf());
      auto draw_tbtn = [&](float bx, const wchar_t* glyph, bool active) {
        D2D1_ROUNDED_RECT br = D2D1::RoundedRect(
            D2D1::RectF(bx, t_top, bx + t_btn, t_top + t_btn), ScaleForDpi(6),
            ScaleForDpi(6));
        render_target_->FillRoundedRectangle(br, tb_bg.Get());
        Microsoft::WRL::ComPtr<IDWriteTextFormat> glyph_fmt;
        dwrite_factory_->CreateTextFormat(
            L"Segoe UI Symbol", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, t_btn * 0.5f,
            L"", glyph_fmt.GetAddressOf());
        if (glyph_fmt != nullptr) {
          glyph_fmt->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
          glyph_fmt->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
          render_target_->DrawTextW(glyph, GlyphLength(glyph), glyph_fmt.Get(),
                                    D2D1::RectF(bx, t_top, bx + t_btn, t_top + t_btn),
                                    active ? tb_active.Get() : tb_fg.Get());
        }
      };
      if (hook_text_mode_) {
        const float controls_total =
            t_btn * kHookTextControlSlotCount +
            t_gap * (kHookTextControlSlotCount - 1);
        const float left = (width - controls_total) / 2.0f;
        auto hook_button = [&](int slot, const wchar_t* glyph, bool active) {
          draw_tbtn(left + slot * (t_btn + t_gap), glyph, active);
        };
        hook_button(0, L"↺", replaying_);
        hook_button(1, L"⏺", recapturing_);
        hook_button(2, playing_ ? L"⏸" : L"▶", !playing_);
        hook_button(3, L"↗", pass_through_);
        hook_button(4, L"◐", false);
        hook_button(5, locked_ ? L"\U0001F512" : L"\U0001F513", locked_);
        hook_button(6, L"▣", false);
        hook_button(7, L"✕", false);
      } else {
        const float lock_x = width - t_pad - t_btn;
        const float top_x = lock_x - t_gap - t_btn;
        const float trans_x = top_x - t_gap - t_btn;
        draw_tbtn(trans_x, L"◐", false);  // one-click background transparency
        draw_tbtn(top_x, L"📌", topmost_);  // pin: always-on-top
        draw_tbtn(lock_x, locked_ ? L"\U0001F512" : L"\U0001F513", locked_);
      }
    }

    // Hook text is a real resizable text box. The clipboard text destination
    // remains intentionally grip-less for compatibility.
    if (hook_text_mode_ && !locked_) {
      const float resize = ScaleForDpi(kResizeGripDip);
      Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> resize_brush;
      render_target_->CreateSolidColorBrush(
          ColorFromArgb(style_.button_text_color),
          resize_brush.GetAddressOf());
      resize_brush->SetOpacity(hovered_ ? 0.7f : 0.2f);
      const float stroke = std::max(1.0f, ScaleForDpi(1.5f));
      for (int i = 1; i <= 3; ++i) {
        const float off = resize * (i / 4.0f);
        render_target_->DrawLine(
            D2D1::Point2F(width - off, height - 2.0f),
            D2D1::Point2F(width - 2.0f, height - off), resize_brush.Get(),
            stroke);
      }
    }
  } else {
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
  }  // else (lyric transport controls)

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
  if (text_only_) {
    // Text-only Luna toolbar: only the lock + one-click-transparency buttons are
    // control hits, and only while hovered (they are invisible otherwise, so a
    // click must never land on a phantom button). The grip / empty strip returns
    // empty so a press there becomes a window drag — geometry mirrors Render().
    if (!hovered_) {
      return std::string();
    }
    RECT rc;
    GetClientRect(hwnd_, &rc);
    const float width = static_cast<float>(rc.right - rc.left);
    const float btn = ScaleForDpi(kButtonSizeDip);
    const float gap = ScaleForDpi(kButtonGapDip);
    const float pad = ScaleForDpi(kHorizontalPaddingDip);
    const float ctrl_top = ScaleForDpi(kControlsTopDip);
    if (y < ctrl_top || y > ctrl_top + btn) {
      return std::string();
    }
    if (hook_text_mode_) {
      const float controls_total =
          btn * kHookTextControlSlotCount +
          gap * (kHookTextControlSlotCount - 1);
      const float left = (width - controls_total) / 2.0f;
      for (int slot = 0; slot < kHookTextControlSlotCount; ++slot) {
        const float bx = left + slot * (btn + gap);
        if (x < bx || x > bx + btn) continue;
        switch (slot) {
          case 0:
            return "replayVoice";
          case 1:
            return "recaptureVoice";
          case 2:
            return "toggleFollow";
          case 3:
            return "togglePassThrough";
          case 4:
            return "toggleTransparency";
          case 5:
            return "lock";
          case 6:
            return "openWorkbench";
          case 7:
            return "close";
          default:
            return std::string();
        }
      }
      return std::string();
    }
    const float lock_x = width - pad - btn;
    const float top_x = lock_x - gap - btn;
    const float trans_x = top_x - gap - btn;
    if (x >= lock_x && x <= lock_x + btn) {
      return "lock";
    }
    if (x >= top_x && x <= top_x + btn) {
      return "topmost";
    }
    if (x >= trans_x && x <= trans_x + btn) {
      return "toggleTransparency";
    }
    return std::string();
  }
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
  // Text-only clipboard window has no resize grip — WM_NCHITTEST stays HTCLIENT
  // everywhere so the whole surface keeps driving drag / lookup, never a system
  // resize loop.
  if ((text_only_ && !hook_text_mode_) || locked_ || hwnd_ == nullptr) {
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

int FloatingLyricWindow::CharIndexAt(float x, float y,
                                     D2D1_RECT_F* out_char_rect) {
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
  if (out_char_rect != nullptr) {
    // Hit-test metrics are layout-local; lift them back into client-area px.
    out_char_rect->left = text_rect_.left + metrics.left;
    out_char_rect->top = text_rect_.top + metrics.top;
    out_char_rect->right = out_char_rect->left + metrics.width;
    out_char_rect->bottom = out_char_rect->top + metrics.height;
  }
  return static_cast<int>(metrics.textPosition);
}
