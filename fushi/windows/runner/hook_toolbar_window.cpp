#include "hook_toolbar_window.h"

#include <d2d1helper.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")

namespace {

constexpr wchar_t kWindowClassName[] = L"FushiHookToolbarWindow";

// A press must travel this far (physical px at 96 DPI, scaled by the owner via
// Layout::button_px staying proportional) before it becomes an owner drag
// rather than a button-miss. Same idea as the body window's kDragThresholdDip.
constexpr float kDragThresholdPx = 6.0f;

// Opacity of the toolbar while the cursor is elsewhere. Unlike the in-body
// toolbar (which is invisible until hovered, because the body itself is a
// visible bar the user can aim at), this window is the ONLY way out of
// pass-through: an invisible escape hatch over a fully transparent overlay is
// an escape hatch the user cannot find. So it stays dimly visible at rest.
constexpr float kRestOpacity = 0.42f;
constexpr float kHoverOpacity = 1.0f;

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

bool SameLayout(const hook_toolbar::Layout& a, const hook_toolbar::Layout& b) {
  return a.rect.left == b.rect.left && a.rect.top == b.rect.top &&
         a.rect.right == b.rect.right && a.rect.bottom == b.rect.bottom &&
         a.owner_origin.x == b.owner_origin.x &&
         a.owner_origin.y == b.owner_origin.y &&
         a.button_px == b.button_px && a.gap_px == b.gap_px &&
         a.margin_px == b.margin_px;
}

bool SameStyle(const hook_toolbar::Style& a, const hook_toolbar::Style& b) {
  return a.button_text_color == b.button_text_color &&
         a.button_bg_color == b.button_bg_color &&
         a.active_color == b.active_color && a.bg_color == b.bg_color;
}

bool SameStates(const hook_toolbar::States& a, const hook_toolbar::States& b) {
  return a.replaying == b.replaying && a.recapturing == b.recapturing &&
         a.playing == b.playing && a.pass_through == b.pass_through &&
         a.locked == b.locked && a.topmost == b.topmost;
}

}  // namespace

namespace hook_toolbar {

const wchar_t* SlotGlyph(int slot, const States& states) {
  switch (slot) {
    case 0:
      return L"↺";  // ↺ replay voice
    case 1:
      return L"⏺";  // ⏺ recapture
    case 2:
      return states.playing ? L"⏸" : L"▶";  // ⏸ / ▶ follow
    case 3:
      return L"↗";  // ↗ pass-through
    case 4:
      return L"◐";  // ◐ transparency
    case 5:
      return states.locked ? L"\U0001F512" : L"\U0001F513";  // 🔒 / 🔓
    case 6:
      return L"▣";  // ▣ workbench
    case 7:
      return L"\U0001F4CC";  // 📌 always-on-top pin
    case 8:
      return L"✕";  // ✕ close
    default:
      return L"";
  }
}

bool SlotActive(int slot, const States& states) {
  switch (slot) {
    case 0:
      return states.replaying;
    case 1:
      return states.recapturing;
    case 2:
      return !states.playing;
    case 3:
      return states.pass_through;
    case 5:
      return states.locked;
    case 7:
      return states.topmost;
    default:
      return false;
  }
}

}  // namespace hook_toolbar

HookToolbarWindow::HookToolbarWindow() = default;

HookToolbarWindow::~HookToolbarWindow() {
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  if (class_registered_) {
    UnregisterClassW(kWindowClassName, GetModuleHandle(nullptr));
  }
}

void HookToolbarWindow::EnsureWindowClass() {
  if (class_registered_) {
    return;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = HookToolbarWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kWindowClassName;
  RegisterClassExW(&wc);
  class_registered_ = true;
}

bool HookToolbarWindow::EnsureDeviceResources() {
  if (d2d_factory_ == nullptr) {
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                 d2d_factory_.GetAddressOf()))) {
      return false;
    }
  }
  if (dwrite_factory_ == nullptr) {
    if (FAILED(DWriteCreateFactory(
            DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
            reinterpret_cast<IUnknown**>(dwrite_factory_.GetAddressOf())))) {
      return false;
    }
  }
  if (render_target_ == nullptr) {
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_PREMULTIPLIED),
        0, 0, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);
    if (FAILED(d2d_factory_->CreateDCRenderTarget(
            &props, render_target_.GetAddressOf()))) {
      render_target_.Reset();
      return false;
    }
  }
  return true;
}

bool HookToolbarWindow::Show(const hook_toolbar::Layout& layout,
                             const hook_toolbar::Style& style,
                             const hook_toolbar::States& states) {
  const int width = layout.rect.right - layout.rect.left;
  const int height = layout.rect.bottom - layout.rect.top;
  if (width <= 0 || height <= 0) {
    return false;
  }
  EnsureWindowClass();
  if (!EnsureDeviceResources()) {
    return false;
  }
  if (hwnd_ == nullptr) {
    // Deliberately WITHOUT WS_EX_TRANSPARENT: this window is the escape hatch
    // out of pass-through and must be clickable at every instant. WS_EX_LAYERED
    // for per-pixel alpha (rounded pill over the game), WS_EX_TOPMOST to float
    // above both the game and the overlay body, WS_EX_NOACTIVATE so clicking a
    // button never steals keyboard focus from the game, WS_EX_TOOLWINDOW to
    // stay out of the taskbar / Alt+Tab.
    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kWindowClassName, L"Fushi Hook Toolbar", WS_POPUP, layout.rect.left,
        layout.rect.top, width, height, nullptr, nullptr,
        GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
  }
  layout_ = layout;
  style_ = style;
  states_ = states;
  has_layout_ = true;
  SetWindowPos(hwnd_, HWND_TOPMOST, layout.rect.left, layout.rect.top, width,
               height, SWP_NOACTIVATE);
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  visible_ = true;
  Render();
  return true;
}

void HookToolbarWindow::Hide() {
  visible_ = false;
  hovered_ = false;
  tracking_mouse_leave_ = false;
  pressed_ = false;
  dragging_ = false;
  if (hwnd_ != nullptr) {
    if (GetCapture() == hwnd_) {
      ReleaseCapture();
    }
    ShowWindow(hwnd_, SW_HIDE);
  }
}

bool HookToolbarWindow::IsShowing() const {
  return visible_ && hwnd_ != nullptr && IsWindowVisible(hwnd_);
}

void HookToolbarWindow::Sync(const hook_toolbar::Layout& layout,
                             const hook_toolbar::Style& style,
                             const hook_toolbar::States& states) {
  if (hwnd_ == nullptr || !visible_) {
    return;
  }
  const bool moved = !has_layout_ || !SameLayout(layout, layout_);
  const bool repaint =
      moved || !SameStyle(style, style_) || !SameStates(states, states_);
  if (!repaint) {
    // Still re-assert Z: the body window raises itself to HWND_TOPMOST on show
    // / clamp / DPI change, which would otherwise tint this pill from above.
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    return;
  }
  layout_ = layout;
  style_ = style;
  states_ = states;
  has_layout_ = true;
  if (moved) {
    SetWindowPos(hwnd_, HWND_TOPMOST, layout.rect.left, layout.rect.top,
                 layout.rect.right - layout.rect.left,
                 layout.rect.bottom - layout.rect.top, SWP_NOACTIVATE);
  } else {
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
  Render();
}

int HookToolbarWindow::SlotAt(float x, float y) const {
  if (!has_layout_ || layout_.button_px <= 0.0f) {
    return -1;
  }
  const float top = layout_.margin_px;
  if (y < top || y > top + layout_.button_px) {
    return -1;
  }
  for (int slot = 0; slot < hook_toolbar::kSlotCount; ++slot) {
    const float bx =
        layout_.margin_px + slot * (layout_.button_px + layout_.gap_px);
    if (x >= bx && x <= bx + layout_.button_px) {
      return slot;
    }
  }
  return -1;
}

LRESULT CALLBACK HookToolbarWindow::WndProc(HWND hwnd, UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    auto* self = static_cast<HookToolbarWindow*>(create->lpCreateParams);
    self->hwnd_ = hwnd;
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self =
      reinterpret_cast<HookToolbarWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMessage(message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT HookToolbarWindow::HandleMessage(UINT message, WPARAM wparam,
                                         LPARAM lparam) noexcept {
  switch (message) {
    case WM_MOUSEMOVE: {
      if (!hovered_) {
        hovered_ = true;
        Render();
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
        if (on_drag_) {
          on_drag_(cursor.x - owner_drag_anchor_.x,
                   cursor.y - owner_drag_anchor_.y);
        }
        return 0;
      }
      if (pressed_) {
        POINT cursor;
        GetCursorPos(&cursor);
        const int dx = cursor.x - press_origin_.x;
        const int dy = cursor.y - press_origin_.y;
        if (dx * dx + dy * dy >=
            static_cast<int>(kDragThresholdPx * kDragThresholdPx)) {
          dragging_ = true;
        }
      }
      return 0;
    }
    case WM_MOUSELEAVE: {
      tracking_mouse_leave_ = false;
      if (hovered_ && !dragging_) {
        hovered_ = false;
        Render();
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const float x = static_cast<float>(GET_X_LPARAM(lparam));
      const float y = static_cast<float>(GET_Y_LPARAM(lparam));
      const int slot = SlotAt(x, y);
      if (slot >= 0) {
        // Buttons fire on press, exactly like the in-body toolbar, so the
        // escape hatch responds to the same gesture the user already knows.
        if (on_action_) {
          on_action_(hook_toolbar::kSlotActions[slot]);
        }
        return 0;
      }
      // A press on the pill background starts a move of the OWNER window: while
      // pass-through is on the body takes no mouse input at all, so this is the
      // only remaining way to reposition the overlay.
      POINT cursor;
      GetCursorPos(&cursor);
      pressed_ = true;
      dragging_ = false;
      press_origin_ = cursor;
      // Anchor on the OWNER's top-left, which the owner pushes down with the
      // layout. Anchoring on the toolbar rect instead would make the first drag
      // move jump the body by the (centred-row) toolbar offset — several
      // hundred px — which also yanks the pill out from under the cursor and
      // kills the drag, since a WS_EX_NOACTIVATE window only gets background
      // capture while the cursor is over it.
      owner_drag_anchor_.x = cursor.x - layout_.owner_origin.x;
      owner_drag_anchor_.y = cursor.y - layout_.owner_origin.y;
      SetCapture(hwnd_);
      return 0;
    }
    case WM_LBUTTONUP: {
      const bool was_dragging = dragging_;
      pressed_ = false;
      dragging_ = false;
      if (GetCapture() == hwnd_) {
        ReleaseCapture();
      }
      if (was_dragging && on_drag_end_) {
        on_drag_end_();
      }
      return 0;
    }
    case WM_NCHITTEST:
      // Everything is client area: this window has no resize grip and never
      // hands anything to the system loops. It also never returns
      // HTTRANSPARENT — that is precisely the cross-process no-op this whole
      // window exists to replace.
      return HTCLIENT;
    default:
      return DefWindowProc(hwnd_, message, wparam, lparam);
  }
}

void HookToolbarWindow::Render() {
  if (hwnd_ == nullptr || !has_layout_ || !EnsureDeviceResources()) {
    return;
  }
  RECT rc;
  GetClientRect(hwnd_, &rc);
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  if (width <= 0 || height <= 0) {
    return;
  }

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
  HBITMAP dib =
      CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HBITMAP old_bmp = static_cast<HBITMAP>(SelectObject(mem_dc, dib));

  RECT bind_rect = {0, 0, width, height};
  if (FAILED(render_target_->BindDC(mem_dc, &bind_rect))) {
    SelectObject(mem_dc, old_bmp);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return;
  }

  const float opacity = hovered_ ? kHoverOpacity : kRestOpacity;
  const float corner = std::max(2.0f, layout_.margin_px * 1.5f);

  render_target_->BeginDraw();
  render_target_->Clear(D2D1::ColorF(0, 0, 0, 0));

  // Pill background. The alpha comes from the overlay's own background colour
  // so the escape hatch matches the caption bar the user configured; it is
  // floored to a visible value because a fully transparent escape hatch over a
  // fully transparent overlay cannot be found.
  uint32_t pill = style_.bg_color;
  if ((pill >> 24) < 0x99) {
    pill = 0x99000000u | (pill & 0x00FFFFFFu);
  }
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> pill_brush;
  render_target_->CreateSolidColorBrush(ColorFromArgb(pill),
                                        pill_brush.GetAddressOf());
  if (pill_brush != nullptr) {
    pill_brush->SetOpacity(opacity);
    render_target_->FillRoundedRectangle(
        D2D1::RoundedRect(D2D1::RectF(0, 0, static_cast<float>(width),
                                      static_cast<float>(height)),
                          corner, corner),
        pill_brush.Get());
  }

  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_bg;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_fg;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_active;
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_bg_color),
                                        btn_bg.GetAddressOf());
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_text_color),
                                        btn_fg.GetAddressOf());
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.active_color),
                                        btn_active.GetAddressOf());
  if (btn_bg != nullptr) btn_bg->SetOpacity(opacity);
  if (btn_fg != nullptr) btn_fg->SetOpacity(opacity);
  if (btn_active != nullptr) btn_active->SetOpacity(opacity);

  const float btn = layout_.button_px;
  Microsoft::WRL::ComPtr<IDWriteTextFormat> glyph_fmt;
  dwrite_factory_->CreateTextFormat(
      L"Segoe UI Symbol", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
      std::max(1.0f, btn * 0.5f), L"", glyph_fmt.GetAddressOf());
  if (glyph_fmt != nullptr) {
    glyph_fmt->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    glyph_fmt->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
  }

  for (int slot = 0; slot < hook_toolbar::kSlotCount; ++slot) {
    const float bx = layout_.margin_px + slot * (btn + layout_.gap_px);
    const float by = layout_.margin_px;
    const D2D1_RECT_F cell = D2D1::RectF(bx, by, bx + btn, by + btn);
    if (btn_bg != nullptr) {
      render_target_->FillRoundedRectangle(
          D2D1::RoundedRect(cell, corner * 0.5f, corner * 0.5f), btn_bg.Get());
    }
    if (glyph_fmt == nullptr) {
      continue;
    }
    const wchar_t* glyph = hook_toolbar::SlotGlyph(slot, states_);
    ID2D1SolidColorBrush* brush = hook_toolbar::SlotActive(slot, states_)
                                      ? btn_active.Get()
                                      : btn_fg.Get();
    if (brush != nullptr) {
      // Full UTF-16 length: the padlock glyphs are surrogate pairs and would be
      // truncated to a lone high surrogate by a hard-coded length of 1.
      render_target_->DrawTextW(glyph, GlyphLength(glyph), glyph_fmt.Get(),
                                cell, brush);
    }
  }

  render_target_->EndDraw();

  POINT dst = {layout_.rect.left, layout_.rect.top};
  POINT src = {0, 0};
  SIZE size = {width, height};
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
