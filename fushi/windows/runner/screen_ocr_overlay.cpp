#include "screen_ocr_overlay.h"

#include <commctrl.h>
#include <d2d1helper.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#include "window_activation_policy.h"

#pragma comment(lib, "comctl32.lib")

namespace so = fushi::screen_ocr;
using Microsoft::WRL::ComPtr;

namespace {

// 类名是契约（spec「冻结层窗口」）；标题**不能**是 "Fushi"：main.cpp 按标题 FindWindow
// 找主窗（单实例转发）。
constexpr wchar_t kClassName[] = L"FushiScreenOcrWindow";
constexpr wchar_t kTitle[] = L"Fushi Screen OCR";

D2D1_COLOR_F ColorFromArgb(uint32_t argb, float opacity = 1.0f) {
  const float a = ((argb >> 24) & 0xFF) / 255.0f;
  const float r = ((argb >> 16) & 0xFF) / 255.0f;
  const float g = ((argb >> 8) & 0xFF) / 255.0f;
  const float b = (argb & 0xFF) / 255.0f;
  return D2D1::ColorF(r, g, b, a * opacity);
}

D2D1_RECT_F ToD2D(const so::RectD& r) {
  return D2D1::RectF(static_cast<float>(r.left), static_cast<float>(r.top),
                     static_cast<float>(r.right), static_cast<float>(r.bottom));
}

}  // namespace

ScreenOcrOverlay::ScreenOcrOverlay() = default;

ScreenOcrOverlay::~ScreenOcrOverlay() {
  Close();
  if (class_registered_) {
    UnregisterClassW(kClassName, GetModuleHandle(nullptr));
  }
}

// ── 截屏 ────────────────────────────────────────────────────────────────────

bool ScreenOcrOverlay::CaptureMonitor(HMONITOR monitor, Capture* out) {
  if (out == nullptr || monitor == nullptr) {
    return false;
  }
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfo(monitor, &mi)) {
    return false;
  }
  const RECT screen = mi.rcMonitor;
  const int width = screen.right - screen.left;
  const int height = screen.bottom - screen.top;
  // 上限同 window_capture 的 128 MiB 帧预算（8K 显示器约 127 MiB）。
  if (width <= 0 || height <= 0 ||
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height) * 4 >
          128ull * 1024 * 1024) {
    return false;
  }
  HDC screen_dc = GetDC(nullptr);
  if (screen_dc == nullptr) {
    return false;
  }
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib = mem_dc == nullptr ? nullptr
                                  : CreateDIBSection(mem_dc, &bmi,
                                                     DIB_RGB_COLORS, &bits,
                                                     nullptr, 0);
  bool ok = false;
  if (dib != nullptr && bits != nullptr) {
    HGDIOBJ old = SelectObject(mem_dc, dib);
    // CAPTUREBLT：把分层窗（别的程序的浮窗）也截进来——用户看到什么就截什么。
    ok = BitBlt(mem_dc, 0, 0, width, height, screen_dc, screen.left,
                screen.top, SRCCOPY | CAPTUREBLT) != FALSE;
    GdiFlush();
    if (ok) {
      const size_t size = static_cast<size_t>(width) * height * 4;
      out->bgra.resize(size);
      std::memcpy(out->bgra.data(), bits, size);
      // BitBlt 不定义 alpha 通道（通常是 0）：PNG 与冻结层都要不透明。
      for (size_t i = 3; i < size; i += 4) {
        out->bgra[i] = 0xFF;
      }
    }
    SelectObject(mem_dc, old);
  }
  if (dib != nullptr) DeleteObject(dib);
  if (mem_dc != nullptr) DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  if (!ok) {
    out->bgra.clear();
    return false;
  }
  out->monitor = monitor;
  out->screen = screen;
  out->width = width;
  out->height = height;
  return true;
}

// ── 生命周期 ────────────────────────────────────────────────────────────────

void ScreenOcrOverlay::EnsureWindowClass() {
  if (class_registered_) {
    return;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpfnWndProc = ScreenOcrOverlay::WndProc;
  wc.lpszClassName = kClassName;
  // 不给背景刷：首帧直接由 D2D 画截图（WM_ERASEBKGND 回 1），不闪白 / 黑。
  wc.hbrBackground = nullptr;
  class_registered_ = RegisterClassExW(&wc) != 0 ||
                      GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

bool ScreenOcrOverlay::EnsureFactories() {
  if (d2d_factory_ == nullptr &&
      FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                               d2d_factory_.GetAddressOf()))) {
    return false;
  }
  if (dwrite_factory_ == nullptr &&
      FAILED(DWriteCreateFactory(
          DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
          reinterpret_cast<IUnknown**>(dwrite_factory_.GetAddressOf())))) {
    return false;
  }
  return true;
}

bool ScreenOcrOverlay::Show(Capture capture, const Style& style) {
  Close();
  if (capture.width <= 0 || capture.height <= 0 ||
      capture.bgra.size() !=
          static_cast<size_t>(capture.width) * capture.height * 4) {
    return false;
  }
  EnsureWindowClass();
  if (!class_registered_ || !EnsureFactories()) {
    return false;
  }
  capture_ = std::move(capture);
  style_ = style;
  const UINT dpi = FlutterDesktopGetDpiForMonitor(capture_.monitor);
  scale_ = dpi > 0 ? dpi / 96.0 : 1.0;
  recognized_ = false;
  message_.reset();
  lines_.clear();
  close_hovered_ = false;
  tracking_leave_ = false;

  // 盖满整块显示器（含任务栏）。不是 NOACTIVATE：要取一次前台才收得到 Esc。
  hwnd_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kClassName, kTitle,
                          WS_POPUP, capture_.screen.left, capture_.screen.top,
                          capture_.width, capture_.height, nullptr, nullptr,
                          GetModuleHandle(nullptr), this);
  if (hwnd_ == nullptr) {
    capture_ = Capture();
    return false;
  }
  Relayout();
  if (!EnsureRenderTarget()) {
    Close();
    return false;
  }
  SetWindowPos(hwnd_, HWND_TOPMOST, capture_.screen.left, capture_.screen.top,
               capture_.width, capture_.height, SWP_SHOWWINDOW);
  // 同步画首帧：显示与第一张截图之间不留空白帧。
  UpdateWindow(hwnd_);
  // 点球是本进程收到的最后一次输入，SetForegroundWindow 被允许；拿到前台才收得到
  // Esc。之后的点击都回 MA_NOACTIVATE / PA_NOACTIVATE，不再改 Z 序。
  SetForegroundWindow(hwnd_);
  return true;
}

void ScreenOcrOverlay::Update(std::vector<so::RectD> lines,
                              std::optional<std::wstring> message) {
  if (hwnd_ == nullptr) {
    return;
  }
  lines_ = std::move(lines);
  message_ = std::move(message);
  if (message_ && message_->empty()) {
    message_.reset();
  }
  recognized_ = true;
  Relayout();
  InvalidateRect(hwnd_, nullptr, FALSE);
}

void ScreenOcrOverlay::Close() {
  if (tooltip_hwnd_ != nullptr) {
    HWND tooltip = tooltip_hwnd_;
    tooltip_hwnd_ = nullptr;
    DestroyWindow(tooltip);
  }
  if (hwnd_ != nullptr) {
    HWND hwnd = hwnd_;
    hwnd_ = nullptr;
    DestroyWindow(hwnd);
  }
  DiscardRenderTarget();
  banner_text_.Reset();
  capture_ = Capture();
  lines_.clear();
  message_.reset();
  recognized_ = false;
}

bool ScreenOcrOverlay::IsShowing() const {
  return hwnd_ != nullptr && IsWindow(hwnd_);
}

void ScreenOcrOverlay::Dismiss() {
  if (hwnd_ == nullptr) {
    return;
  }
  // 可能正跑在本窗口自己的 WndProc 里：Close 之后不再碰任何窗口成员。
  Close();
  if (on_dismiss_) on_dismiss_();
}

// ── 绘制 ────────────────────────────────────────────────────────────────────

const std::wstring& ScreenOcrOverlay::BannerText() const {
  if (message_) return *message_;
  return recognized_ ? style_.hint : style_.recognizing;
}

void ScreenOcrOverlay::Relayout() {
  banner_text_.Reset();
  if (dwrite_factory_ == nullptr) {
    return;
  }
  if (text_format_ == nullptr || text_format_scale_ != scale_) {
    text_format_.Reset();
    wchar_t locale[LOCALE_NAME_MAX_LENGTH] = L"";
    if (GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH) == 0) {
      wcscpy_s(locale, L"en-us");
    }
    if (FAILED(dwrite_factory_->CreateTextFormat(
            L"Segoe UI", nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
            static_cast<float>(so::kBannerFontDip * scale_), locale,
            text_format_.GetAddressOf()))) {
      return;
    }
    text_format_scale_ = scale_;
  }
  const std::wstring& text = BannerText();
  const double max_w = so::MaxBannerTextWidth(capture_.width, scale_);
  double text_w = 0;
  double text_h = so::kBannerFontDip * scale_ * 1.4;
  if (SUCCEEDED(dwrite_factory_->CreateTextLayout(
          text.c_str(), static_cast<UINT32>(text.size()), text_format_.Get(),
          static_cast<float>(max_w), static_cast<float>(capture_.height),
          banner_text_.GetAddressOf()))) {
    DWRITE_TEXT_METRICS metrics = {};
    if (SUCCEEDED(banner_text_->GetMetrics(&metrics))) {
      text_w = std::ceil(metrics.widthIncludingTrailingWhitespace);
      text_h = std::ceil(metrics.height);
    }
  }
  banner_ = so::LayoutBanner(capture_.width, scale_, text_w, text_h);
  UpdateCloseTooltip();
}

void ScreenOcrOverlay::UpdateCloseTooltip() {
  if (hwnd_ == nullptr || style_.close.empty()) {
    return;
  }
  TOOLINFOW tool = {};
  tool.cbSize = sizeof(tool);
  tool.uFlags = TTF_SUBCLASS;
  tool.hwnd = hwnd_;
  tool.uId = 1;
  tool.rect = RECT{static_cast<LONG>(banner_.close.left),
                   static_cast<LONG>(banner_.close.top),
                   static_cast<LONG>(std::ceil(banner_.close.right)),
                   static_cast<LONG>(std::ceil(banner_.close.bottom))};
  if (tooltip_hwnd_ == nullptr) {
    static const bool common_controls_ready = [] {
      INITCOMMONCONTROLSEX icc = {sizeof(INITCOMMONCONTROLSEX),
                                  ICC_TAB_CLASSES};
      return InitCommonControlsEx(&icc) != FALSE;
    }();
    if (!common_controls_ready) {
      return;
    }
    tooltip_hwnd_ = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_NOACTIVATE, TOOLTIPS_CLASSW, nullptr,
        WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT,
        CW_USEDEFAULT, CW_USEDEFAULT, hwnd_, nullptr, GetModuleHandleW(nullptr),
        nullptr);
    if (tooltip_hwnd_ == nullptr) {
      return;
    }
    // lpszText 是裸指针，comctl32 在提示生命周期内会回读：指向自持的 style_。
    tool.lpszText = style_.close.data();
    SendMessageW(tooltip_hwnd_, TTM_ADDTOOLW, 0,
                 reinterpret_cast<LPARAM>(&tool));
    return;
  }
  SendMessageW(tooltip_hwnd_, TTM_NEWTOOLRECTW, 0,
               reinterpret_cast<LPARAM>(&tool));
}

bool ScreenOcrOverlay::EnsureRenderTarget() {
  if (render_target_ != nullptr) {
    return true;
  }
  if (hwnd_ == nullptr || d2d_factory_ == nullptr) {
    return false;
  }
  RECT client = {};
  GetClientRect(hwnd_, &client);
  const D2D1_SIZE_U size = D2D1::SizeU(
      static_cast<UINT32>(std::max<LONG>(1, client.right - client.left)),
      static_cast<UINT32>(std::max<LONG>(1, client.bottom - client.top)));
  if (FAILED(d2d_factory_->CreateHwndRenderTarget(
          D2D1::RenderTargetProperties(),
          D2D1::HwndRenderTargetProperties(hwnd_, size),
          render_target_.GetAddressOf()))) {
    render_target_.Reset();
    return false;
  }
  // 1 DIP = 1 物理像素：几何全在截图像素里算。
  render_target_->SetDpi(96.0f, 96.0f);
  const D2D1_BITMAP_PROPERTIES props = D2D1::BitmapProperties(
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
  if (FAILED(render_target_->CreateBitmap(
          D2D1::SizeU(static_cast<UINT32>(capture_.width),
                      static_cast<UINT32>(capture_.height)),
          capture_.bgra.data(), static_cast<UINT32>(capture_.width) * 4, props,
          screenshot_.GetAddressOf()))) {
    // 截图贴不上就不能「定格」——宁可不显示冻结层也不给一块纯黑。
    DiscardRenderTarget();
    return false;
  }
  return true;
}

void ScreenOcrOverlay::DiscardRenderTarget() {
  screenshot_.Reset();
  render_target_.Reset();
}

void ScreenOcrOverlay::Render() {
  for (int attempt = 0; attempt < 2; ++attempt) {
    if (!EnsureRenderTarget()) {
      return;
    }
    ID2D1HwndRenderTarget* rt = render_target_.Get();
    const D2D1_SIZE_F target = rt->GetSize();
    rt->BeginDraw();
    // 客户区与截图同尺寸（PerMonitorV2 + 窗口矩形 = 显示器矩形）；万一不等也按比例
    // 画满，坐标换算与 WM_LBUTTONDOWN 同一个比例。
    const float sx = capture_.width > 0
                         ? target.width / static_cast<float>(capture_.width)
                         : 1.0f;
    const float sy = capture_.height > 0
                         ? target.height / static_cast<float>(capture_.height)
                         : 1.0f;
    rt->SetTransform(D2D1::Matrix3x2F::Scale(sx, sy));
    rt->Clear(D2D1::ColorF(0, 0, 0, 1));
    const D2D1_RECT_F full =
        D2D1::RectF(0, 0, static_cast<float>(capture_.width),
                    static_cast<float>(capture_.height));
    rt->DrawBitmap(screenshot_.Get(), full, 1.0f,
                   D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR);

    ComPtr<ID2D1SolidColorBrush> brush;
    if (SUCCEEDED(rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1),
                                            brush.GetAddressOf()))) {
      // 轻微压暗：让行框与提示条显得出来，同时提示「画面已定格」。
      brush->SetColor(D2D1::ColorF(0, 0, 0, static_cast<float>(so::kDimAlpha)));
      rt->FillRectangle(full, brush.Get());

      const float stroke = static_cast<float>(so::kLineStrokeDip * scale_);
      const double outset = so::kLineOutsetDip * scale_;
      const float radius = static_cast<float>(3.0 * scale_);
      for (const so::RectD& line : lines_) {
        if (!line.HasArea()) continue;
        const so::RectD box{line.left - outset, line.top - outset,
                            line.right + outset, line.bottom + outset};
        const D2D1_ROUNDED_RECT rounded =
            D2D1::RoundedRect(ToD2D(box), radius, radius);
        brush->SetColor(ColorFromArgb(style_.primary,
                                      static_cast<float>(so::kLineFillAlpha)));
        rt->FillRoundedRectangle(rounded, brush.Get());
        brush->SetColor(ColorFromArgb(style_.primary));
        rt->DrawRoundedRectangle(rounded, brush.Get(), stroke);
      }

      // 顶部提示条：surface 底 + onSurface 字 + 关闭钮。
      const D2D1_RECT_F banner = ToD2D(banner_.banner);
      const float banner_radius = (banner.bottom - banner.top) / 2;
      const float shadow = static_cast<float>(2.0 * scale_);
      brush->SetColor(D2D1::ColorF(0, 0, 0, 0.22f));
      rt->FillRoundedRectangle(
          D2D1::RoundedRect(D2D1::RectF(banner.left, banner.top + shadow,
                                        banner.right, banner.bottom + shadow),
                            banner_radius, banner_radius),
          brush.Get());
      brush->SetColor(ColorFromArgb(style_.surface));
      rt->FillRoundedRectangle(
          D2D1::RoundedRect(banner, banner_radius, banner_radius), brush.Get());
      if (banner_text_ != nullptr) {
        brush->SetColor(ColorFromArgb(style_.on_surface));
        rt->DrawTextLayout(
            D2D1::Point2F(static_cast<float>(banner_.text.left),
                          static_cast<float>(banner_.text.top)),
            banner_text_.Get(), brush.Get(),
            D2D1_DRAW_TEXT_OPTIONS_CLIP);
      }
      const float cx =
          static_cast<float>((banner_.close.left + banner_.close.right) / 2);
      const float cy =
          static_cast<float>((banner_.close.top + banner_.close.bottom) / 2);
      const float cr = static_cast<float>(banner_.close.Width() / 2);
      brush->SetColor(
          ColorFromArgb(style_.on_surface, close_hovered_ ? 0.14f : 0.06f));
      rt->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), cr, cr),
                      brush.Get());
      const float arm = cr * 0.42f;
      brush->SetColor(ColorFromArgb(style_.on_surface));
      const float cross = static_cast<float>(1.6 * scale_);
      rt->DrawLine(D2D1::Point2F(cx - arm, cy - arm),
                   D2D1::Point2F(cx + arm, cy + arm), brush.Get(), cross);
      rt->DrawLine(D2D1::Point2F(cx - arm, cy + arm),
                   D2D1::Point2F(cx + arm, cy - arm), brush.Get(), cross);
    }
    const HRESULT hr = rt->EndDraw();
    if (hr != D2DERR_RECREATE_TARGET) {
      return;
    }
    DiscardRenderTarget();
  }
}

// ── 窗口过程 ────────────────────────────────────────────────────────────────

LRESULT CALLBACK ScreenOcrOverlay::WndProc(HWND hwnd, UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self =
      reinterpret_cast<ScreenOcrOverlay*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT ScreenOcrOverlay::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam) noexcept {
  // 客户区 px → 截图 px（两者通常相等，见 Render）。
  auto to_image = [this, hwnd](LPARAM lp, double* x, double* y) {
    RECT client = {};
    GetClientRect(hwnd, &client);
    const double cw = std::max<LONG>(1, client.right - client.left);
    const double ch = std::max<LONG>(1, client.bottom - client.top);
    *x = GET_X_LPARAM(lp) * (capture_.width / cw);
    *y = GET_Y_LPARAM(lp) * (capture_.height / ch);
  };
  switch (message) {
    // 显示时已取过一次前台；之后点冻结层不激活、不改 Z 序（查词卡在它上面），
    // 触摸 / 触控笔按下同样回「不激活」（BUG-2788 同一策略）。
    case WM_POINTERACTIVATE:
    case WM_MOUSEACTIVATE:
      return OverlayNoActivateReply(message);
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT ps;
      BeginPaint(hwnd, &ps);
      EndPaint(hwnd, &ps);
      if (hwnd == hwnd_) {
        Render();
      }
      return 0;
    }
    case WM_SIZE:
      if (render_target_ != nullptr) {
        render_target_->Resize(D2D1::SizeU(LOWORD(lparam), HIWORD(lparam)));
      }
      return 0;
    case WM_LBUTTONDOWN: {
      double x = 0;
      double y = 0;
      to_image(lparam, &x, &y);
      switch (so::ClassifyLeftClick(banner_, x, y)) {
        case so::OverlayClick::kDismiss:
          Dismiss();
          return 0;
        case so::OverlayClick::kIgnore:
          return 0;
        case so::OverlayClick::kTap:
          // 层不自动关：Dart 命中测试后决定弹卡还是 stopScreenOcr。
          if (on_tap_) {
            on_tap_(static_cast<int>(std::floor(x)),
                    static_cast<int>(std::floor(y)));
          }
          return 0;
      }
      return 0;
    }
    case WM_RBUTTONDOWN:
      Dismiss();
      return 0;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      return 0;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        Dismiss();
        return 0;
      }
      break;
    case WM_CLOSE:
      // Alt+F4：与 Esc 同义（不能让 DefWindowProc 直接销毁、跳过回调）。
      Dismiss();
      return 0;
    case WM_MOUSEMOVE: {
      if (!tracking_leave_) {
        TRACKMOUSEEVENT tme = {sizeof(tme), TME_LEAVE, hwnd, 0};
        tracking_leave_ = TrackMouseEvent(&tme) != FALSE;
      }
      double x = 0;
      double y = 0;
      to_image(lparam, &x, &y);
      const bool hovered = banner_.close.Contains(x, y);
      if (hovered != close_hovered_) {
        close_hovered_ = hovered;
        InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      tracking_leave_ = false;
      if (close_hovered_) {
        close_hovered_ = false;
        InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    case WM_SETCURSOR:
      if (LOWORD(lparam) == HTCLIENT) {
        SetCursor(LoadCursor(nullptr, close_hovered_ ? IDC_HAND : IDC_ARROW));
        return TRUE;
      }
      break;
    case WM_DPICHANGED:
      // 几何按截图像素固定，不采用系统建议矩形。
      return 0;
    case WM_DISPLAYCHANGE:
      // 显示器布局 / 分辨率变了：定格的截图与屏幕已对不上，坐标没法再换算——关层。
      Dismiss();
      return 0;
    case WM_NCDESTROY:
      SetWindowLongPtr(hwnd, GWLP_USERDATA, 0);
      if (hwnd_ == hwnd) {
        // 被外部销毁（不是 Close()）：状态清掉，不回调（宿主的 Dart 侧照常能
        // stopScreenOcr / 再开一次）。
        hwnd_ = nullptr;
        tooltip_hwnd_ = nullptr;
        DiscardRenderTarget();
      }
      break;
    default:
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
