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

// Logical (96-DPI) strip metrics; scaled per-monitor in Render().
constexpr float kStripWidthDip = 720.0f;
constexpr float kStripHeightDip = 96.0f;
constexpr float kCornerRadiusDip = 14.0f;
constexpr float kHorizontalPaddingDip = 20.0f;
constexpr float kButtonSizeDip = 30.0f;
constexpr float kButtonGapDip = 10.0f;
constexpr float kControlsTopDip = 8.0f;

// ARGB (0xAARRGGBB) -> D2D1_COLOR_F (straight alpha).
D2D1_COLOR_F ColorFromArgb(uint32_t argb) {
  const float a = ((argb >> 24) & 0xFF) / 255.0f;
  const float r = ((argb >> 16) & 0xFF) / 255.0f;
  const float g = ((argb >> 8) & 0xFF) / 255.0f;
  const float b = (argb & 0xFF) / 255.0f;
  return D2D1::ColorF(r, g, b, a);
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
    const int width = static_cast<int>(ScaleForDpi(kStripWidthDip));
    const int height = static_cast<int>(ScaleForDpi(kStripHeightDip));
    const int work_w = mi.rcWork.right - mi.rcWork.left;
    const int x = mi.rcWork.left + (work_w - width) / 2;
    const int y = mi.rcWork.bottom - height - static_cast<int>(ScaleForDpi(48));

    // WS_EX_TRANSPARENT: born click-through so the apps underneath stay fully
    // usable. WS_EX_NOACTIVATE keeps clicks from stealing keyboard focus.
    // The cursor-poll timer below restores interactivity only while the cursor
    // is over the strip, so words remain tappable for lookup.
    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
            WS_EX_TRANSPARENT,
        kWindowClassName, L"Hibiki Lyric", WS_POPUP, x, y, width, height,
        nullptr, nullptr, GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
    interactive_ = false;
  }

  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  visible_ = true;
  StartCursorPoll();
  RequestRender();
  return true;
}

void FloatingLyricWindow::Hide() {
  visible_ = false;
  StopCursorPoll();
  hovered_ = false;
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
  RequestRender();
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

void FloatingLyricWindow::RequestRender() {
  if (hwnd_ != nullptr && visible_) {
    Render();
  }
}

void FloatingLyricWindow::StartCursorPoll() {
  if (hwnd_ != nullptr) {
    SetTimer(hwnd_, kCursorPollTimerId, kCursorPollIntervalMs, nullptr);
  }
}

void FloatingLyricWindow::StopCursorPoll() {
  if (hwnd_ != nullptr) {
    KillTimer(hwnd_, kCursorPollTimerId);
  }
  ApplyInteractive(false);
}

bool FloatingLyricWindow::CursorOverStrip() const {
  if (hwnd_ == nullptr) {
    return false;
  }
  POINT cursor;
  if (!GetCursorPos(&cursor)) {
    return false;
  }
  RECT rc;
  if (!GetWindowRect(hwnd_, &rc)) {
    return false;
  }
  // The topmost window directly under the cursor must be us; otherwise another
  // window is overlapping the strip and should keep the click.
  if (!PtInRect(&rc, cursor)) {
    return false;
  }
  HWND top = WindowFromPoint(cursor);
  return top == hwnd_;
}

void FloatingLyricWindow::ApplyInteractive(bool interactive) {
  if (hwnd_ == nullptr || interactive_ == interactive) {
    return;
  }
  interactive_ = interactive;
  LONG_PTR ex = GetWindowLongPtr(hwnd_, GWL_EXSTYLE);
  if (interactive) {
    ex &= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
  } else {
    ex |= static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
  }
  SetWindowLongPtr(hwnd_, GWL_EXSTYLE, ex);
  // The controls fade in only while interactive, mirroring QQ Music: the row is
  // dim when the cursor is away and crisp when the strip is hot.
  if (hovered_ != interactive) {
    hovered_ = interactive;
    RequestRender();
  }
}

void FloatingLyricWindow::PollCursorInteractivity() {
  if (!visible_) {
    return;
  }
  // Never drop interactivity mid-drag: SetCapture keeps the messages flowing,
  // and flipping WS_EX_TRANSPARENT here would abort the move.
  if (dragging_) {
    ApplyInteractive(true);
    return;
  }
  ApplyInteractive(CursorOverStrip());
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
    case WM_TIMER: {
      if (wparam == kCursorPollTimerId) {
        PollCursorInteractivity();
      }
      return 0;
    }
    case WM_MOUSEMOVE: {
      // The strip only receives mouse messages while interactive (the poll
      // dropped WS_EX_TRANSPARENT because the cursor is over us); the fade state
      // is owned by PollCursorInteractivity(), so here we only drag.
      if (dragging_) {
        POINT cursor;
        GetCursorPos(&cursor);
        RECT rc;
        GetWindowRect(hwnd_, &rc);
        const int new_x = cursor.x - drag_anchor_.x;
        const int new_y = cursor.y - drag_anchor_.y;
        SetWindowPos(hwnd_, HWND_TOPMOST, new_x, new_y, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const float x = static_cast<float>(GET_X_LPARAM(lparam));
      const float y = static_cast<float>(GET_Y_LPARAM(lparam));
      const std::string action = ControlActionAt(x, y);
      if (!action.empty()) {
        if (on_control_) {
          on_control_(action);
        }
        return 0;
      }
      if (click_lookup_enabled_) {
        const int index = CharIndexAt(x, y);
        if (index >= 0 && on_lookup_) {
          // UTF-16 -> UTF-8 for the channel.
          int utf8_len = WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                                             static_cast<int>(text_.size()),
                                             nullptr, 0, nullptr, nullptr);
          std::string utf8(utf8_len, '\0');
          WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                              static_cast<int>(text_.size()), utf8.data(),
                              utf8_len, nullptr, nullptr);
          on_lookup_(utf8, index);
          return 0;
        }
      }
      // Otherwise begin dragging the strip.
      POINT cursor;
      GetCursorPos(&cursor);
      RECT rc;
      GetWindowRect(hwnd_, &rc);
      drag_anchor_.x = cursor.x - rc.left;
      drag_anchor_.y = cursor.y - rc.top;
      dragging_ = true;
      SetCapture(hwnd_);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (dragging_) {
        dragging_ = false;
        ReleaseCapture();
      }
      return 0;
    }
    case WM_DPICHANGED: {
      dpi_ = HIWORD(wparam);
      DiscardDeviceResources();
      EnsureDeviceResources();
      RequestRender();
      return 0;
    }
    case WM_DISPLAYCHANGE: {
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

  const float corner = ScaleForDpi(kCornerRadiusDip);
  D2D1_ROUNDED_RECT bg_rect = D2D1::RoundedRect(
      D2D1::RectF(0, 0, static_cast<float>(width), static_cast<float>(height)),
      corner, corner);

  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush;
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.bg_color),
                                        brush.GetAddressOf());
  render_target_->FillRoundedRectangle(bg_rect, brush.Get());

  // Text format / layout.
  if (text_format_ == nullptr) {
    dwrite_factory_->CreateTextFormat(
        L"Yu Gothic UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
        static_cast<float>(ScaleForDpi(static_cast<float>(style_.font_size))),
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
  const float controls_total = btn * 4 + gap * 3;
  const float ctrl_left = (width - controls_total) / 2.0f;
  const float control_alpha = hovered_ ? 1.0f : 0.35f;

  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_bg;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_fg;
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_bg_color),
                                        btn_bg.GetAddressOf());
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_text_color),
                                        btn_fg.GetAddressOf());
  btn_bg->SetOpacity(control_alpha);
  btn_fg->SetOpacity(control_alpha);

  auto draw_glyph = [&](int slot, const wchar_t* glyph) {
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
      render_target_->DrawTextW(glyph, 1, glyph_fmt.Get(),
                                D2D1::RectF(bx, ctrl_top, bx + btn,
                                            ctrl_top + btn),
                                btn_fg.Get());
    }
  };

  draw_glyph(0, L"⏮");                       // previous
  draw_glyph(1, playing_ ? L"⏸" : L"▶");  // pause / play
  draw_glyph(2, L"⏭");                       // next
  draw_glyph(3, L"✕");                        // close

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
  const float controls_total = btn * 4 + gap * 3;
  const float ctrl_left = (width - controls_total) / 2.0f;
  if (y < ctrl_top || y > ctrl_top + btn) {
    return std::string();
  }
  for (int slot = 0; slot < 4; ++slot) {
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
          return "close";
        default:
          return std::string();
      }
    }
  }
  return std::string();
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
