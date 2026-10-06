#include "floating_ball_window.h"

#include <commctrl.h>
#include <d2d1helper.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>

#include "window_activation_policy.h"

// TOOLTIPS_CLASS / InitCommonControlsEx / TTM_* —— 按钮悬停提示（labels）。
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "windowscodecs.lib")

namespace fb = fushi::floating_ball;
using Microsoft::WRL::ComPtr;

namespace {

// 球窗类名是契约（docs/specs/2026-09-30-desktop-system-floating-ball.md）；按钮窗另起一类，
// 各自的窗口过程分开，免得一个 WndProc 里靠 HWND 比较分流。
constexpr wchar_t kBallClassName[] = L"FushiFloatingBallWindow";
constexpr wchar_t kMenuClassName[] = L"FushiFloatingBallMenuWindow";
// 标题**不能**是 "Fushi"：main.cpp 按标题 FindWindow 找主窗（单实例转发）。
constexpr wchar_t kBallTitle[] = L"Fushi Floating Ball";
constexpr wchar_t kMenuTitle[] = L"Fushi Floating Ball Menu";

constexpr UINT_PTR kAnimationTimerId = 1;
// USER_TIMER_MINIMUM。SetTimer 的周期会被向上取整到系统时钟节拍（默认 15.6ms）：
// 填 16 会被取整成两拍 = 31ms（约 32fps），填 10 取整成一拍 ≈ 64fps。动画进度
// 按 QPC 实际经过时间算，节拍抖动不影响时长。
constexpr UINT kAnimationTimerMs = 10;

constexpr char kActionOpenApp[] = "open_app";
constexpr char kActionClose[] = "close";

double NowMs() {
  static const double frequency = [] {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return static_cast<double>(f.QuadPart);
  }();
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  return static_cast<double>(now.QuadPart) * 1000.0 / frequency;
}

D2D1_COLOR_F ColorFromArgb(uint32_t argb, float opacity = 1.0f) {
  const float a = ((argb >> 24) & 0xFF) / 255.0f;
  const float r = ((argb >> 16) & 0xFF) / 255.0f;
  const float g = ((argb >> 8) & 0xFF) / 255.0f;
  const float b = (argb & 0xFF) / 255.0f;
  return D2D1::ColorF(r, g, b, a * opacity);
}

uint32_t WithAlpha(uint32_t argb, double alpha) {
  const uint32_t a = static_cast<uint32_t>(
      std::lround(((argb >> 24) & 0xFF) * std::clamp(alpha, 0.0, 1.0)));
  return (argb & 0x00FFFFFF) | (a << 24);
}

// Color.alphaBlend(fg, bg)：fg 按自身 alpha 叠在 bg 上（Android blend 同式）。
uint32_t AlphaBlend(uint32_t fg, uint32_t bg) {
  const double a = ((fg >> 24) & 0xFF) / 255.0;
  auto channel = [&](int shift) {
    const double f = (fg >> shift) & 0xFF;
    const double b = (bg >> shift) & 0xFF;
    return static_cast<uint32_t>(std::lround(f * a + b * (1 - a))) & 0xFF;
  };
  return (bg & 0xFF000000) | (channel(16) << 16) | (channel(8) << 8) |
         channel(0);
}

double EaseOutBackPeakCached() {
  static const double peak = fb::EaseOutBackPeak();
  return peak;
}

}  // namespace

FloatingBallWindow::FloatingBallWindow() = default;

FloatingBallWindow::~FloatingBallWindow() {
  Stop();
  if (classes_registered_) {
    UnregisterClassW(kBallClassName, GetModuleHandle(nullptr));
    UnregisterClassW(kMenuClassName, GetModuleHandle(nullptr));
  }
}

void FloatingBallWindow::EnsureWindowClasses() {
  if (classes_registered_) {
    return;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpfnWndProc = FloatingBallWindow::BallWndProc;
  wc.lpszClassName = kBallClassName;
  RegisterClassExW(&wc);
  wc.lpfnWndProc = FloatingBallWindow::MenuWndProc;
  wc.lpszClassName = kMenuClassName;
  RegisterClassExW(&wc);
  classes_registered_ = true;
}

bool FloatingBallWindow::EnsureDeviceResources() {
  if (d2d_factory_ == nullptr) {
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                 d2d_factory_.GetAddressOf()))) {
      return false;
    }
  }
  if (render_target_ == nullptr) {
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f, 96.0f, D2D1_RENDER_TARGET_USAGE_NONE,
        D2D1_FEATURE_LEVEL_DEFAULT);
    if (FAILED(d2d_factory_->CreateDCRenderTarget(
            &props, render_target_.GetAddressOf()))) {
      render_target_.Reset();
      return false;
    }
    // 1 DIP = 1 物理像素：几何全在 px 里算，DPI 由本类自己乘。
    render_target_->SetDpi(96.0f, 96.0f);
  }
  if (wic_factory_ == nullptr) {
    // 失败不致命：没有 WIC 就画不出图片，球退化成主题色圆、按钮只有底色。
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                     IID_PPV_ARGS(wic_factory_.GetAddressOf()));
  }
  return true;
}

void FloatingBallWindow::DiscardDeviceResources() {
  // D2D 位图绑在 render target 上，target 重建时一起丢。
  bitmaps_.clear();
  render_target_.Reset();
}

void FloatingBallWindow::ClearBitmapCache() { bitmaps_.clear(); }

std::vector<std::string> FloatingBallWindow::ButtonIds() const {
  // 固定的关闭 / 打开 Fushi 在最上（离球最远，防误触），用户勾选的动作在下、
  // 末颗紧贴球顶——与应用内「列表末颗离球最近」同序。
  std::vector<std::string> ids;
  ids.emplace_back(kActionClose);
  ids.emplace_back(kActionOpenApp);
  for (const std::string& id : config_.actions) {
    if (id != kActionClose && id != kActionOpenApp &&
        std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
    }
  }
  return ids;
}

std::wstring FloatingBallWindow::LabelFor(const std::string& id) const {
  const auto it = config_.labels.find(id);
  if (it != config_.labels.end() && !it->second.empty()) {
    return it->second;
  }
  // native 不维护 17 种语言：Dart 没给文案时回退英文（Android labelFor 同表）。
  if (id == "lookup") return L"Look up";
  if (id == "popup_lookup") return L"App-external lookup";
  if (id == "clipboard") return L"Clipboard";
  if (id == "sync") return L"Sync now";
  if (id == kActionOpenApp) return L"Open Fushi";
  if (id == kActionClose) return L"Close";
  if (id == "ball") return L"Floating ball";
  return std::wstring(id.begin(), id.end());
}

// ── 几何 ────────────────────────────────────────────────────────────────────

FloatingBallWindow::Screen FloatingBallWindow::ScreenFor(
    HMONITOR monitor, double probe_y) const {
  Screen screen;
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (monitor == nullptr || !GetMonitorInfo(monitor, &mi)) {
    // 句柄失效（显示器被拔掉）：退回主显示器。
    monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
    mi = {};
    mi.cbSize = sizeof(mi);
    GetMonitorInfo(monitor, &mi);
  }
  screen.monitor = monitor;
  const RECT& work = mi.rcWork;
  screen.viewport = fb::Rect{static_cast<double>(work.left),
                             static_cast<double>(work.top),
                             static_cast<double>(work.right),
                             static_cast<double>(work.bottom)};
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  screen.scale = dpi > 0 ? dpi / 96.0 : 1.0;

  // 停靠边外侧紧挨着另一块显示器时不外缩：否则收起的球有 1/3 画进邻屏，
  // 而且那 1/3 在邻屏上还能被点到。只看工作区外一像素处落在哪块屏上——同一块屏
  // （任务栏占着那条边）照常外缩。
  LONG y = work.top + (work.bottom - work.top) / 2;
  if (std::isfinite(probe_y)) {
    y = std::clamp(static_cast<LONG>(std::lround(probe_y)), work.top,
                   std::max(work.top, work.bottom - 1));
  }
  auto neighbour_at = [&](LONG x) {
    const HMONITOR other =
        MonitorFromPoint(POINT{x, y}, MONITOR_DEFAULTTONULL);
    return other != nullptr && other != monitor;
  };
  screen.tuck_left = !neighbour_at(work.left - 1);
  screen.tuck_right = !neighbour_at(work.right);
  return screen;
}

fb::Geometry FloatingBallWindow::GeometryFor(const Screen& screen,
                                             bool dock_left,
                                             double fraction) const {
  return fb::Geometry(screen.viewport, dock_left, fraction,
                      static_cast<int>(ButtonIds().size()), screen.scale,
                      dock_left ? screen.tuck_left : screen.tuck_right);
}

fb::Geometry FloatingBallWindow::CurrentGeometry() {
  const Screen first =
      ScreenFor(monitor_, std::numeric_limits<double>::quiet_NaN());
  const fb::Geometry rough = GeometryFor(first, dock_left_, fraction_);
  const Screen screen =
      ScreenFor(first.monitor, rough.BallTop() + rough.ball() / 2);
  monitor_ = screen.monitor;
  scale_ = screen.scale;
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfo(monitor_, &mi)) {
    last_work_ = mi.rcWork;
  }
  last_dpi_ = FlutterDesktopGetDpiForMonitor(monitor_);
  return GeometryFor(screen, dock_left_, fraction_);
}

double FloatingBallWindow::BallPx() const { return fb::kBallDip * scale_; }

int FloatingBallWindow::BallWindowSize() const {
  return static_cast<int>(std::ceil(
      (fb::kBallDip + 2 * fb::kBallShadowPadDip) * scale_));
}

RECT FloatingBallWindow::BallScreenRect() const {
  const double ball = BallPx();
  return RECT{static_cast<LONG>(std::lround(ball_left_)),
              static_cast<LONG>(std::lround(ball_top_)),
              static_cast<LONG>(std::lround(ball_left_ + ball)),
              static_cast<LONG>(std::lround(ball_top_ + ball))};
}

// ── 生命周期 ────────────────────────────────────────────────────────────────

bool FloatingBallWindow::Start(const Config& config, bool dock_left,
                               double fraction, HWND monitor_hint) {
  EnsureWindowClasses();
  if (!EnsureDeviceResources()) {
    return false;
  }
  if (IsRunning()) {
    // 原地更新：按钮个数 / 图标 / 配色都可能变——收起（下次展开按新配置建按钮窗），
    // 球按新图重画；位置不动（Dart 这次带来的位置就是它上次从我们这里收到的）。
    config_ = config;
    ClearBitmapCache();
    CollapseImmediately();
    return true;
  }

  config_ = config;
  ClearBitmapCache();
  dock_left_ = dock_left;
  fraction_ = std::isfinite(fraction) ? std::clamp(fraction, 0.0, 1.0) : 0.5;
  monitor_ = MonitorFromWindow(monitor_hint, MONITOR_DEFAULTTOPRIMARY);
  progress_ = 0;
  expand_target_ = false;
  const fb::Geometry g = CurrentGeometry();
  ball_left_ = g.CollapsedBallLeft();
  ball_top_ = g.BallTop();

  const int size = BallWindowSize();
  // owner = nullptr：主窗最小化时球不能跟着藏。
  ball_hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kBallClassName, kBallTitle, WS_POPUP,
      static_cast<int>(std::lround(ball_left_)),
      static_cast<int>(std::lround(ball_top_)), size, size, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  if (ball_hwnd_ == nullptr) {
    return false;
  }
  // 先把像素推上去再显示：分层窗首帧就是完整的球，不会闪一块空白。
  RenderBall();
  SetWindowPos(ball_hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  return true;
}

void FloatingBallWindow::Stop() {
  CancelAnimations();
  // 先落状态再拆窗：DestroyWindow 会同步发 WM_CAPTURECHANGED，拖动中的状态若还在
  // 就会走 EndDrag，给一个正在消失的球起吸附动画、报位置。
  pressing_ball_ = false;
  dragging_ = false;
  DestroyMenuWindow();
  if (ball_hwnd_ != nullptr) {
    HWND hwnd = ball_hwnd_;
    ball_hwnd_ = nullptr;
    DestroyWindow(hwnd);
  }
  timer_running_ = false;
  progress_ = 0;
  expand_target_ = false;
  hidden_for_capture_ = false;
}

bool FloatingBallWindow::IsRunning() const {
  return ball_hwnd_ != nullptr && IsWindow(ball_hwnd_);
}

void FloatingBallWindow::HideForCapture() {
  if (!IsRunning()) {
    return;
  }
  hidden_for_capture_ = true;
  HideTooltip();
  // 只改可见性：分层窗的像素与位置都留着，动画计时器照跑（UpdateLayeredWindow
  // 不会把隐藏的窗口显示出来），恢复时就是那一刻该有的样子。
  ShowWindow(ball_hwnd_, SW_HIDE);
  if (menu_hwnd_ != nullptr) {
    ShowWindow(menu_hwnd_, SW_HIDE);
  }
}

void FloatingBallWindow::RestoreAfterCapture() {
  if (!hidden_for_capture_) {
    return;
  }
  hidden_for_capture_ = false;
  if (!IsRunning()) {
    return;
  }
  SetWindowPos(ball_hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  if (menu_hwnd_ != nullptr) {
    // 与 EnsureMenuWindow 同序：按钮窗紧贴在球窗下面。
    SetWindowPos(menu_hwnd_, ball_hwnd_, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }
}

// ── 展开 / 收起 ─────────────────────────────────────────────────────────────

void FloatingBallWindow::SetExpanded(bool expand) {
  if (expand == expand_target_ || ball_hwnd_ == nullptr) {
    return;
  }
  expand_target_ = expand;
  snap_anim_.active = false;
  if (expand) {
    EnsureMenuWindow();
  }
  AnimateProgress(expand ? 1.0 : 0.0, expand ? fb::kExpandMs : fb::kCollapseMs);
}

void FloatingBallWindow::AnimateProgress(double target, int full_ms) {
  progress_anim_.active = true;
  progress_anim_.from = progress_;
  progress_anim_.to = target;
  progress_anim_.start_ms = NowMs();
  progress_anim_.duration_ms =
      fb::ProgressDurationMs(full_ms, progress_, target);
  EnsureAnimationTimer();
}

void FloatingBallWindow::CollapseImmediately() {
  CancelAnimations();
  expand_target_ = false;
  DestroyMenuWindow();
  SetProgress(0);
}

void FloatingBallWindow::CancelAnimations() {
  progress_anim_.active = false;
  snap_anim_.active = false;
  if (timer_running_ && ball_hwnd_ != nullptr) {
    KillTimer(ball_hwnd_, kAnimationTimerId);
  }
  timer_running_ = false;
}

void FloatingBallWindow::SetProgress(double t) {
  progress_ = t;
  const fb::Geometry g = CurrentGeometry();
  ball_left_ = g.BallLeftAt(t);
  ball_top_ = g.BallTopAt(t);
  RenderBall();
  RenderMenu();
}

void FloatingBallWindow::EnsureAnimationTimer() {
  if (timer_running_ || ball_hwnd_ == nullptr) {
    return;
  }
  timer_running_ =
      SetTimer(ball_hwnd_, kAnimationTimerId, kAnimationTimerMs, nullptr) != 0;
}

void FloatingBallWindow::OnAnimationTick() {
  const double now = NowMs();
  bool more = false;
  if (progress_anim_.active) {
    const double f = std::clamp(
        (now - progress_anim_.start_ms) / progress_anim_.duration_ms, 0.0, 1.0);
    const double target = progress_anim_.to;
    if (f >= 1.0) {
      progress_anim_.active = false;
      SetProgress(target);
      // 收起动画结束才拆按钮窗（Android 同）。
      if (target <= 0.0) {
        DestroyMenuWindow();
      }
    } else {
      SetProgress(fb::Lerp(progress_anim_.from, target, f));
      more = true;
    }
  }
  if (snap_anim_.active) {
    const double f = std::clamp(
        (now - snap_anim_.start_ms) / static_cast<double>(fb::kSnapMs), 0.0,
        1.0);
    const double e = fb::EaseOutCubic(f);
    ball_left_ = fb::Lerp(snap_anim_.from_left, snap_anim_.to_left, e);
    ball_top_ = fb::Lerp(snap_anim_.from_top, snap_anim_.to_top, e);
    RenderBall();
    if (f >= 1.0) {
      snap_anim_.active = false;
    } else {
      more = true;
    }
  }
  if (!more && timer_running_) {
    if (ball_hwnd_ != nullptr) {
      KillTimer(ball_hwnd_, kAnimationTimerId);
    }
    timer_running_ = false;
  }
}

// ── 按钮窗 ──────────────────────────────────────────────────────────────────

void FloatingBallWindow::EnsureMenuWindow() {
  if (menu_hwnd_ != nullptr || ball_hwnd_ == nullptr) {
    return;
  }
  // 按**最终几何**一次算好：展开态球心 + 各按钮落点。窗口包围盒要容得下每颗按钮
  // 从球心飞到落点、再按 easeOutBack 冲过头的整段轨迹（圆心随 k 线性，所以两个
  // 端点 k=0 / k=峰值 的并集就够），外加阴影边。之后只做动画，窗口不再挪、不再改大小。
  const fb::Geometry g = CurrentGeometry();
  menu_ids_ = ButtonIds();
  menu_scale_ = scale_;
  const double ball_cx = g.ExpandedBallLeft() + g.ball() / 2;
  const double ball_cy = g.ExpandedBallTop() + g.ball() / 2;
  const double peak = EaseOutBackPeakCached();
  const double reach_radius = g.button() / 2 * fb::ButtonScale(peak) +
                              fb::kMenuShadowPadDip * menu_scale_ +
                              2.0 * menu_scale_;
  double min_x = ball_cx - reach_radius;
  double max_x = ball_cx + reach_radius;
  double min_y = ball_cy - reach_radius;
  double max_y = ball_cy + reach_radius;
  std::vector<fb::Offset> offsets;
  for (size_t i = 0; i < menu_ids_.size(); ++i) {
    const fb::Offset off = g.ButtonOffset(static_cast<int>(i));
    offsets.push_back(off);
    const double far_x = ball_cx + off.dx * peak;
    const double far_y = ball_cy + off.dy * peak;
    min_x = std::min(min_x, far_x - reach_radius);
    max_x = std::max(max_x, far_x + reach_radius);
    min_y = std::min(min_y, far_y - reach_radius);
    max_y = std::max(max_y, far_y + reach_radius);
  }
  menu_origin_ = POINT{static_cast<LONG>(std::floor(min_x)),
                       static_cast<LONG>(std::floor(min_y))};
  menu_size_ = SIZE{static_cast<LONG>(std::ceil(max_x)) - menu_origin_.x,
                    static_cast<LONG>(std::ceil(max_y)) - menu_origin_.y};
  menu_ball_cx_ = ball_cx - menu_origin_.x;
  menu_ball_cy_ = ball_cy - menu_origin_.y;
  menu_centers_.clear();
  for (const fb::Offset& off : offsets) {
    menu_centers_.push_back(
        fb::Offset{menu_ball_cx_ + off.dx, menu_ball_cy_ + off.dy});
  }
  hovered_ = -1;
  pressed_ = -1;
  tracking_leave_ = false;

  menu_hwnd_ = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kMenuClassName, kMenuTitle, WS_POPUP, menu_origin_.x, menu_origin_.y,
      menu_size_.cx, menu_size_.cy, nullptr, nullptr, GetModuleHandle(nullptr),
      this);
  if (menu_hwnd_ == nullptr) {
    return;
  }
  // 显示前先按当前进度（通常 t=0，按钮全透明）推一帧像素，再插到球窗正下方显示：
  // 按钮从球心「钻出来」，球始终盖在上面；透明像素点击穿透到球窗。
  RenderMenu();
  SetWindowPos(menu_hwnd_, ball_hwnd_, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                   (hidden_for_capture_ ? 0 : SWP_SHOWWINDOW));
}

void FloatingBallWindow::DestroyMenuWindow() {
  HideTooltip();
  hovered_ = -1;
  pressed_ = -1;
  tracking_leave_ = false;
  if (menu_hwnd_ != nullptr) {
    HWND hwnd = menu_hwnd_;
    menu_hwnd_ = nullptr;
    // 提示窗以按钮窗为 owner，随它一起销毁。
    DestroyWindow(hwnd);
  }
  tooltip_hwnd_ = nullptr;
  tooltip_index_ = -1;
}

bool FloatingBallWindow::ButtonCircle(int index, double* cx, double* cy,
                                      double* radius, double* opacity) const {
  const int n = static_cast<int>(menu_centers_.size());
  if (index < 0 || index >= n) {
    return false;
  }
  const double k = fb::ButtonProgress(progress_, index, n);
  const fb::Offset& c = menu_centers_[index];
  *cx = menu_ball_cx_ + (c.dx - menu_ball_cx_) * k;
  *cy = menu_ball_cy_ + (c.dy - menu_ball_cy_) * k;
  *radius = fb::kButtonDip * menu_scale_ / 2 * fb::ButtonScale(k);
  *opacity = fb::ButtonOpacity(k);
  return true;
}

int FloatingBallWindow::ButtonAt(double x, double y) const {
  for (int i = static_cast<int>(menu_centers_.size()) - 1; i >= 0; --i) {
    double cx, cy, r, o;
    if (!ButtonCircle(i, &cx, &cy, &r, &o) || o < 0.05) {
      continue;
    }
    const double dx = x - cx;
    const double dy = y - cy;
    if (dx * dx + dy * dy <= r * r) {
      return i;
    }
  }
  return -1;
}

void FloatingBallWindow::RunButton(int index) {
  if (index < 0 || index >= static_cast<int>(menu_ids_.size()) ||
      !expand_target_) {
    return;
  }
  const std::string id = menu_ids_[index];
  if (id == kActionClose) {
    // 先拆窗再通知：Dart 收到时原生已经没有球了，它只需把「应用外显示」开关关掉。
    // Stop() 可能正跑在按钮窗自己的 WndProc 里——之后不再碰任何窗口。
    Stop();
    if (on_closed_) on_closed_();
    return;
  }
  // 锚点取展开态的球（整颗在屏内），查词卡锚在它旁边；随后原生收起。
  const RECT anchor = BallScreenRect();
  SetExpanded(false);
  if (on_action_) on_action_(id, anchor);
}

void FloatingBallWindow::UpdateTooltip(int index) {
  if (index < 0 || menu_hwnd_ == nullptr ||
      index >= static_cast<int>(menu_ids_.size())) {
    HideTooltip();
    return;
  }
  if (index == tooltip_index_) {
    return;
  }
  const std::wstring text = LabelFor(menu_ids_[index]);
  if (text.empty()) {
    HideTooltip();
    return;
  }
  static const bool common_controls_ready = [] {
    INITCOMMONCONTROLSEX icc = {sizeof(INITCOMMONCONTROLSEX), ICC_TAB_CLASSES};
    return InitCommonControlsEx(&icc) != FALSE;
  }();
  if (!common_controls_ready) {
    return;
  }
  TOOLINFOW tool = {};
  tool.cbSize = sizeof(tool);
  // TTF_TRACK|TTF_ABSOLUTE：宿主是 NOACTIVATE 分层自绘窗，位置由我们决定
  // （hook_toolbar 的 SlotTooltipHost 同一做法）。
  tool.uFlags = TTF_TRACK | TTF_ABSOLUTE;
  tool.hwnd = menu_hwnd_;
  tool.uId = 1;
  if (tooltip_hwnd_ == nullptr || !IsWindow(tooltip_hwnd_)) {
    tooltip_hwnd_ = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_NOACTIVATE, TOOLTIPS_CLASSW, nullptr,
        WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT,
        CW_USEDEFAULT, CW_USEDEFAULT, menu_hwnd_, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (tooltip_hwnd_ == nullptr) {
      return;
    }
    tooltip_text_.clear();
    tool.lpszText = tooltip_text_.data();
    SendMessageW(tooltip_hwnd_, TTM_ADDTOOLW, 0,
                 reinterpret_cast<LPARAM>(&tool));
  }
  tooltip_index_ = index;
  // lpszText 是裸指针，comctl32 在提示生命周期内会回读：指向自持的成员。
  tooltip_text_ = text;
  tool.lpszText = tooltip_text_.data();
  SendMessageW(tooltip_hwnd_, TTM_UPDATETIPTEXTW, 0,
               reinterpret_cast<LPARAM>(&tool));
  const LRESULT bubble = SendMessageW(tooltip_hwnd_, TTM_GETBUBBLESIZE, 0,
                                      reinterpret_cast<LPARAM>(&tool));
  const int bubble_w = LOWORD(bubble);
  const int bubble_h = HIWORD(bubble);
  // 提示贴在按钮朝屏幕中央的一侧，不盖住别的按钮。
  const fb::Offset& c = menu_centers_[index];
  const double half = fb::kButtonDip * menu_scale_ / 2;
  const double gap = fb::kGapDip * menu_scale_;
  const double sx = menu_origin_.x + c.dx;
  const double sy = menu_origin_.y + c.dy;
  const int x = static_cast<int>(std::lround(
      dock_left_ ? sx + half + gap : sx - half - gap - bubble_w));
  const int y = static_cast<int>(std::lround(sy - bubble_h / 2.0));
  // TTM_TRACKPOSITION 的坐标有符号：副屏在主屏左 / 上方时为负，先窄化成 SHORT
  // 保留符号位（SlotTooltipHost 同坑）。
  SendMessageW(tooltip_hwnd_, TTM_TRACKPOSITION, 0,
               MAKELPARAM(static_cast<WORD>(static_cast<SHORT>(x)),
                          static_cast<WORD>(static_cast<SHORT>(y))));
  SendMessageW(tooltip_hwnd_, TTM_TRACKACTIVATE, TRUE,
               reinterpret_cast<LPARAM>(&tool));
}

void FloatingBallWindow::HideTooltip() {
  tooltip_index_ = -1;
  if (tooltip_hwnd_ == nullptr || !IsWindow(tooltip_hwnd_) ||
      menu_hwnd_ == nullptr) {
    return;
  }
  TOOLINFOW tool = {};
  tool.cbSize = sizeof(tool);
  tool.hwnd = menu_hwnd_;
  tool.uId = 1;
  SendMessageW(tooltip_hwnd_, TTM_TRACKACTIVATE, FALSE,
               reinterpret_cast<LPARAM>(&tool));
}

// ── 拖动 ────────────────────────────────────────────────────────────────────

void FloatingBallWindow::BeginDrag() {
  // 先收起（按钮跟着球飞没有意义），球从收起位开始跟手。
  CollapseImmediately();
  dragging_ = true;
  drag_start_left_ = ball_left_;
  drag_start_top_ = ball_top_;
  RenderBall();
}

void FloatingBallWindow::DragTo(POINT cursor) {
  double left = drag_start_left_ + (cursor.x - down_point_.x);
  double top = drag_start_top_ + (cursor.y - down_point_.y);
  // 视口 = 球心所在显示器的工作区：拖到另一块屏就以那块为准（DPI 也跟着换，
  // 球窗尺寸在 RenderBall 里随 UpdateLayeredWindow 一起改）。
  const double ball = BallPx();
  const POINT center{static_cast<LONG>(std::lround(left + ball / 2)),
                     static_cast<LONG>(std::lround(top + ball / 2))};
  const HMONITOR monitor = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
  const Screen screen = ScreenFor(monitor, center.y);
  monitor_ = screen.monitor;
  scale_ = screen.scale;
  const fb::Geometry as_left = GeometryFor(screen, true, fraction_);
  const fb::Geometry as_right = GeometryFor(screen, false, fraction_);
  left = std::clamp(left, as_left.CollapsedBallLeft(),
                    std::max(as_left.CollapsedBallLeft(),
                             as_right.CollapsedBallLeft()));
  top = std::clamp(top, as_left.MinTop(), as_left.MaxTop());
  ball_left_ = left;
  ball_top_ = top;
  RenderBall();
}

void FloatingBallWindow::EndDrag() {
  dragging_ = false;
  // 松手：按球心落在视口左右哪一半定停靠边、比例按落点，easeOutCubic 吸附到收起位。
  const Screen screen = ScreenFor(monitor_, ball_top_ + BallPx() / 2);
  const fb::Geometry g = GeometryFor(screen, dock_left_, fraction_);
  dock_left_ = g.DockLeftForBallLeft(ball_left_);
  fraction_ = g.FractionForTop(ball_top_);
  const fb::Geometry settled = CurrentGeometry();
  snap_anim_.active = true;
  snap_anim_.from_left = ball_left_;
  snap_anim_.from_top = ball_top_;
  snap_anim_.to_left = settled.CollapsedBallLeft();
  snap_anim_.to_top = settled.BallTop();
  snap_anim_.start_ms = NowMs();
  RenderBall();
  EnsureAnimationTimer();
  if (on_position_) on_position_(dock_left_, fraction_);
}

void FloatingBallWindow::OnDisplayEnvironmentChanged(bool force) {
  if (ball_hwnd_ == nullptr || dragging_) {
    return;
  }
  const double ball = BallPx();
  const POINT center{static_cast<LONG>(std::lround(ball_left_ + ball / 2)),
                     static_cast<LONG>(std::lround(ball_top_ + ball / 2))};
  const HMONITOR monitor = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi = {};
  mi.cbSize = sizeof(mi);
  GetMonitorInfo(monitor, &mi);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  // WM_SETTINGCHANGE / WM_DISPLAYCHANGE 远不止真变化时才发：视口与 DPI 都没变就
  // 不动，免得刚展开就被收掉（Android relayoutForDisplayChange 同理）。
  if (!force && monitor == monitor_ && EqualRect(&mi.rcWork, &last_work_) &&
      dpi == last_dpi_) {
    return;
  }
  // 位置存的是停靠边 + 比例：在新视口里重算，永远落在屏内。
  monitor_ = monitor;
  CollapseImmediately();
}

// ── 绘制 ────────────────────────────────────────────────────────────────────

template <typename DrawFn>
bool FloatingBallWindow::RenderLayered(HWND hwnd, int x, int y, int w, int h,
                                       BYTE alpha, DrawFn draw) {
  if (hwnd == nullptr || w <= 0 || h <= 0) {
    return false;
  }
  // D2DERR_RECREATE_TARGET 时重建一次再画，别把半截帧推上去。
  for (int attempt = 0; attempt < 2; ++attempt) {
    if (!EnsureDeviceResources()) {
      return false;
    }
    HDC screen_dc = GetDC(nullptr);
    HDC mem_dc = CreateCompatibleDC(screen_dc);
    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;  // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP dib =
        CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (dib == nullptr) {
      DeleteDC(mem_dc);
      ReleaseDC(nullptr, screen_dc);
      return false;
    }
    HBITMAP old_bmp = static_cast<HBITMAP>(SelectObject(mem_dc, dib));
    bool drawn = false;
    bool recreate = false;
    RECT bind_rect = {0, 0, w, h};
    if (SUCCEEDED(render_target_->BindDC(mem_dc, &bind_rect))) {
      render_target_->BeginDraw();
      render_target_->SetTransform(D2D1::Matrix3x2F::Identity());
      render_target_->Clear(D2D1::ColorF(0, 0, 0, 0));
      draw();
      const HRESULT hr = render_target_->EndDraw();
      if (hr == D2DERR_RECREATE_TARGET) {
        recreate = true;
      } else {
        drawn = SUCCEEDED(hr);
      }
    }
    if (drawn) {
      POINT src = {0, 0};
      POINT dst = {x, y};
      SIZE size = {w, h};
      BLENDFUNCTION blend = {};
      blend.BlendOp = AC_SRC_OVER;
      blend.SourceConstantAlpha = alpha;
      blend.AlphaFormat = AC_SRC_ALPHA;
      UpdateLayeredWindow(hwnd, screen_dc, &dst, &size, mem_dc, &src, 0,
                          &blend, ULW_ALPHA);
    }
    SelectObject(mem_dc, old_bmp);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    if (!recreate) {
      return drawn;
    }
    DiscardDeviceResources();
  }
  return false;
}

void FloatingBallWindow::DrawSoftShadow(float cx, float cy, float radius,
                                        float blur, float alpha) {
  if (alpha <= 0.0f || radius <= 0.0f) {
    return;
  }
  // 径向渐变近似 Material 投影：圆内（扣掉半个模糊）实色，往外到 radius + blur
  // 线性衰减到 0。
  const float outer = radius + std::max(blur, 0.5f);
  const float solid = std::clamp((radius - blur * 0.5f) / outer, 0.0f, 1.0f);
  D2D1_GRADIENT_STOP stops[] = {
      {0.0f, D2D1::ColorF(0, 0, 0, alpha)},
      {solid, D2D1::ColorF(0, 0, 0, alpha)},
      {1.0f, D2D1::ColorF(0, 0, 0, 0)},
  };
  ComPtr<ID2D1GradientStopCollection> collection;
  if (FAILED(render_target_->CreateGradientStopCollection(
          stops, 3, collection.GetAddressOf()))) {
    return;
  }
  ComPtr<ID2D1RadialGradientBrush> brush;
  if (FAILED(render_target_->CreateRadialGradientBrush(
          D2D1::RadialGradientBrushProperties(D2D1::Point2F(cx, cy),
                                              D2D1::Point2F(0, 0), outer,
                                              outer),
          collection.Get(), brush.GetAddressOf()))) {
    return;
  }
  render_target_->FillEllipse(
      D2D1::Ellipse(D2D1::Point2F(cx, cy), outer, outer), brush.Get());
}

void FloatingBallWindow::RenderBall() {
  if (ball_hwnd_ == nullptr) {
    return;
  }
  const int size = BallWindowSize();
  const double ball = BallPx();
  const int x = static_cast<int>(std::lround(ball_left_ + ball / 2 - size / 2.0));
  const int y = static_cast<int>(std::lround(ball_top_ + ball / 2 - size / 2.0));
  // 球左上角在窗口内的位置（窗口位置取整带来的亚像素差也补回来）。
  const float bx = static_cast<float>(ball_left_ - x);
  const float by = static_cast<float>(ball_top_ - y);
  const float r = static_cast<float>(ball / 2);
  const float cx = bx + r;
  const float cy = by + r;
  const double t = std::clamp(progress_, 0.0, 1.0);
  const float scale = static_cast<float>(scale_);
  const BYTE alpha = static_cast<BYTE>(
      std::lround(255.0 * fb::BallOpacity(t, dragging_)));
  const UINT image_px = static_cast<UINT>(std::ceil(ball));

  RenderLayered(ball_hwnd_, x, y, size, size, alpha, [&]() {
    ID2D1RenderTarget* rt = render_target_.Get();
    // 阴影随展开加深（应用内 elevation 1 → 6）；模糊不超过窗口留的阴影边。
    const float pad = static_cast<float>(fb::kBallShadowPadDip) * scale;
    const float blur = std::min(pad, (1.5f + 3.5f * static_cast<float>(t)) * scale);
    DrawSoftShadow(cx, cy + (0.5f + static_cast<float>(t)) * scale, r, blur,
                   0.18f + 0.14f * static_cast<float>(t));

    // 球面：Dart 合成的 M3E FAB 球面（主题 primaryContainer + 吉祥物），按圆
    // 裁切（cover：取中心正方形，已在 WIC 里缩到球径）。
    const D2D1_ELLIPSE disc = D2D1::Ellipse(D2D1::Point2F(cx, cy), r, r);
    ID2D1Bitmap* image =
        BitmapFor("ball", config_.ball_image, image_px, /*crop_square=*/true);
    bool painted = false;
    if (image != nullptr) {
      ComPtr<ID2D1BitmapBrush> brush;
      if (SUCCEEDED(rt->CreateBitmapBrush(image, brush.GetAddressOf()))) {
        const D2D1_SIZE_F image_size = image->GetSize();
        const float s = image_size.width > 0 ? 2 * r / image_size.width : 1.0f;
        brush->SetInterpolationMode(D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        brush->SetTransform(D2D1::Matrix3x2F::Scale(s, s) *
                            D2D1::Matrix3x2F::Translation(bx, by));
        rt->FillEllipse(disc, brush.Get());
        painted = true;
      }
    }
    if (!painted) {
      ComPtr<ID2D1SolidColorBrush> fill;
      if (SUCCEEDED(rt->CreateSolidColorBrush(
              ColorFromArgb(config_.ball_container), fill.GetAddressOf()))) {
        rt->FillEllipse(disc, fill.Get());
      }
    }

    // 描边环：M3E FAB 无环，只有墨水屏（outline 不透明）画 1.5dp 描边。
    if (((config_.outline >> 24) & 0xFF) != 0) {
      const float stroke = 1.5f * scale;
      ComPtr<ID2D1SolidColorBrush> ring_brush;
      if (SUCCEEDED(rt->CreateSolidColorBrush(ColorFromArgb(config_.outline),
                                              ring_brush.GetAddressOf()))) {
        const float inset = stroke / 2;
        rt->DrawEllipse(
            D2D1::Ellipse(D2D1::Point2F(cx, cy), r - inset, r - inset),
            ring_brush.Get(), stroke);
      }
    }
  });
}

void FloatingBallWindow::RenderMenu() {
  if (menu_hwnd_ == nullptr) {
    return;
  }
  const float scale = static_cast<float>(menu_scale_);
  // M3E tonal 小圆钮（应用内 _ColumnButton 同一配方）：secondaryContainer 底、
  // onSecondaryContainer 状态层（图标 PNG 已由 Dart 着好色）；墨水屏 surface 底 +
  // 描边、无阴影。Dart 没下发 M3E 键时按旧配方（surface 叠 6% onSurface）兜底。
  const uint32_t base =
      config_.button_container != 0
          ? config_.button_container
          : AlphaBlend(WithAlpha(config_.on_surface, 0.06), config_.surface);
  const uint32_t on_base = config_.on_button_container != 0
                               ? config_.on_button_container
                               : config_.on_surface;
  const bool outlined = ((config_.outline >> 24) & 0xFF) != 0;
  const UINT icon_px =
      static_cast<UINT>(std::ceil(fb::kIconDip * menu_scale_));

  RenderLayered(menu_hwnd_, menu_origin_.x, menu_origin_.y, menu_size_.cx,
                menu_size_.cy, 255, [&]() {
    ID2D1RenderTarget* rt = render_target_.Get();
    ComPtr<ID2D1SolidColorBrush> brush;
    if (FAILED(rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0),
                                         brush.GetAddressOf()))) {
      return;
    }
    for (int i = 0; i < static_cast<int>(menu_ids_.size()); ++i) {
      double dcx, dcy, dr, dop;
      if (!ButtonCircle(i, &dcx, &dcy, &dr, &dop) || dop <= 0.0) {
        continue;
      }
      const float cx = static_cast<float>(dcx);
      const float cy = static_cast<float>(dcy);
      const float r = static_cast<float>(dr);
      const float opacity = static_cast<float>(dop);
      // 轻阴影（M3E elevation level 1）；墨水屏不投影。
      if (!outlined) {
        DrawSoftShadow(cx, cy + 0.5f * scale, r, 2.0f * scale,
                       0.20f * opacity);
      }
      const D2D1_ELLIPSE disc = D2D1::Ellipse(D2D1::Point2F(cx, cy), r, r);
      brush->SetColor(ColorFromArgb(base, opacity));
      rt->FillEllipse(disc, brush.Get());
      // 悬停 / 按下：M3E 状态层 8% / 10%。
      if (i == pressed_ || i == hovered_) {
        const double overlay = i == pressed_ ? 0.10 : 0.08;
        brush->SetColor(ColorFromArgb(WithAlpha(on_base, overlay), opacity));
        rt->FillEllipse(disc, brush.Get());
      }
      if (outlined) {
        const float stroke = 1.5f * scale;
        brush->SetColor(ColorFromArgb(config_.outline, opacity));
        rt->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), r - stroke / 2,
                                      r - stroke / 2),
                        brush.Get(), stroke);
      }
      const auto icon_it = config_.icon_images.find(menu_ids_[i]);
      if (icon_it != config_.icon_images.end()) {
        ID2D1Bitmap* icon =
            BitmapFor("icon:" + menu_ids_[i], icon_it->second, icon_px,
                      /*crop_square=*/false);
        if (icon != nullptr) {
          const float half = static_cast<float>(
              fb::kIconDip * menu_scale_ / 2 *
              (dr / (fb::kButtonDip * menu_scale_ / 2)));
          rt->DrawBitmap(icon,
                         D2D1::RectF(cx - half, cy - half, cx + half,
                                     cy + half),
                         opacity, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        }
      }
    }
  });
}

ID2D1Bitmap* FloatingBallWindow::BitmapFor(const std::string& key,
                                           const std::vector<uint8_t>& png,
                                           UINT px, bool crop_square) {
  if (render_target_ == nullptr || px == 0) {
    return nullptr;
  }
  CachedBitmap& entry = bitmaps_[key];
  if (entry.px == px && (entry.bitmap != nullptr || entry.failed)) {
    return entry.bitmap.Get();
  }
  entry = CachedBitmap{};
  entry.px = px;
  entry.failed = true;
  if (png.empty() || wic_factory_ == nullptr) {
    return nullptr;
  }
  // PNG → WIC 解码 →（球面取中心正方形）→ Fant 缩到目标像素 → 预乘 BGRA。
  // 在 WIC 里一次缩到位：1024² 的球面直接让 D2D 缩到 48px 会严重走样。
  ComPtr<IWICStream> stream;
  if (FAILED(wic_factory_->CreateStream(stream.GetAddressOf())) ||
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()),
                                          static_cast<DWORD>(png.size())))) {
    return nullptr;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(wic_factory_->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad,
          decoder.GetAddressOf()))) {
    return nullptr;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, frame.GetAddressOf()))) {
    return nullptr;
  }
  ComPtr<IWICBitmapSource> source = frame;
  if (crop_square) {
    UINT w = 0;
    UINT h = 0;
    if (SUCCEEDED(frame->GetSize(&w, &h)) && w != h && w > 0 && h > 0) {
      const UINT side = std::min(w, h);
      WICRect rect = {static_cast<INT>((w - side) / 2),
                      static_cast<INT>((h - side) / 2),
                      static_cast<INT>(side), static_cast<INT>(side)};
      ComPtr<IWICBitmapClipper> clipper;
      if (SUCCEEDED(wic_factory_->CreateBitmapClipper(
              clipper.GetAddressOf())) &&
          SUCCEEDED(clipper->Initialize(source.Get(), &rect))) {
        source = clipper;
      }
    }
  }
  ComPtr<IWICBitmapScaler> scaler;
  if (FAILED(wic_factory_->CreateBitmapScaler(scaler.GetAddressOf())) ||
      FAILED(scaler->Initialize(source.Get(), px, px,
                                WICBitmapInterpolationModeFant))) {
    return nullptr;
  }
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(wic_factory_->CreateFormatConverter(converter.GetAddressOf())) ||
      FAILED(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return nullptr;
  }
  // CacheOnLoad：像素立刻拷出来，之后不再引用 |png| 的内存。
  ComPtr<IWICBitmap> pixels;
  if (FAILED(wic_factory_->CreateBitmapFromSource(
          converter.Get(), WICBitmapCacheOnLoad, pixels.GetAddressOf()))) {
    return nullptr;
  }
  const D2D1_BITMAP_PROPERTIES props = D2D1::BitmapProperties(
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                        D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f, 96.0f);
  if (FAILED(render_target_->CreateBitmapFromWicBitmap(
          pixels.Get(), &props, entry.bitmap.GetAddressOf()))) {
    entry.bitmap.Reset();
    return nullptr;
  }
  entry.failed = false;
  return entry.bitmap.Get();
}

// ── 窗口过程 ────────────────────────────────────────────────────────────────

LRESULT CALLBACK FloatingBallWindow::BallWndProc(HWND hwnd, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<FloatingBallWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleBallMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK FloatingBallWindow::MenuWndProc(HWND hwnd, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self = reinterpret_cast<FloatingBallWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMenuMessage(hwnd, message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT FloatingBallWindow::HandleBallMessage(HWND hwnd, UINT message,
                                              WPARAM wparam,
                                              LPARAM lparam) noexcept {
  switch (message) {
    // 点球不抢前台：否则「应用外查词」取不到别的程序的选区。WS_EX_NOACTIVATE 只挡
    // 鼠标点击；触摸 / 触控笔按下还会发 WM_POINTERACTIVATE（DefWindowProc 回
    // PA_ACTIVATE），与查词覆盖窗同一条策略（BUG-2788）一起回「不激活」。
    case WM_POINTERACTIVATE:
    case WM_MOUSEACTIVATE:
      return OverlayNoActivateReply(message);
    case WM_LBUTTONDOWN: {
      pressing_ball_ = true;
      dragging_ = false;
      GetCursorPos(&down_point_);
      SetCapture(hwnd);
      return 0;
    }
    case WM_MOUSEMOVE: {
      if (!pressing_ball_) {
        return 0;
      }
      POINT cursor;
      GetCursorPos(&cursor);
      if (!dragging_) {
        // 越过系统拖动阈值才算拖动；之内都是点击。
        const int dx = std::abs(cursor.x - down_point_.x);
        const int dy = std::abs(cursor.y - down_point_.y);
        // 阈值按球所在显示器的 DPI 换成物理像素：SM_CXDRAG 是用户设定的裸像素
        // （默认 4），GetSystemMetricsForDpi 对它不缩放（实测 96~288 DPI 恒回
        // 4），200% 屏上鼠标 / 触控笔一抖 2 个逻辑像素就被当成拖动。
        const UINT dpi = GetDpiForWindow(hwnd);
        const int drag_x =
            MulDiv(GetSystemMetrics(SM_CXDRAG), dpi, USER_DEFAULT_SCREEN_DPI);
        const int drag_y =
            MulDiv(GetSystemMetrics(SM_CYDRAG), dpi, USER_DEFAULT_SCREEN_DPI);
        if (dx <= drag_x && dy <= drag_y) {
          return 0;
        }
        BeginDrag();
      }
      DragTo(cursor);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (!pressing_ball_) {
        return 0;
      }
      // 先落状态再放捕获：ReleaseCapture 同步发 WM_CAPTURECHANGED。
      pressing_ball_ = false;
      const bool was_dragging = dragging_;
      if (GetCapture() == hwnd) {
        ReleaseCapture();
      }
      if (was_dragging) {
        EndDrag();
      } else {
        SetExpanded(!expand_target_);
      }
      return 0;
    }
    case WM_CAPTURECHANGED: {
      // 捕获被别人抢走（系统弹窗等）：当作松手。
      if (pressing_ball_) {
        pressing_ball_ = false;
        if (dragging_) {
          EndDrag();
        }
      }
      return 0;
    }
    case WM_TIMER:
      if (wparam == kAnimationTimerId) {
        OnAnimationTick();
        return 0;
      }
      break;
    case WM_DPICHANGED:
      // 拖动跨屏时的 DPI 变化由 DragTo 接管（按新屏重算尺寸）；其余情形（用户改
      // 缩放）收起并按停靠边 + 比例重摆。不采用系统建议矩形：几何由本类自己算。
      if (!dragging_) {
        OnDisplayEnvironmentChanged(/*force=*/true);
      }
      return 0;
    case WM_DISPLAYCHANGE:
      OnDisplayEnvironmentChanged(/*force=*/false);
      return 0;
    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETWORKAREA) {
        OnDisplayEnvironmentChanged(/*force=*/false);
      }
      break;
    case WM_NCDESTROY:
      SetWindowLongPtr(hwnd, GWLP_USERDATA, 0);
      if (ball_hwnd_ == hwnd) {
        // 被外部销毁（不是 Stop()）：把按钮窗与动画一起收掉，下一次 Start 从零重建。
        ball_hwnd_ = nullptr;
        timer_running_ = false;
        progress_anim_.active = false;
        snap_anim_.active = false;
        pressing_ball_ = false;
        dragging_ = false;
        expand_target_ = false;
        progress_ = 0;
        DestroyMenuWindow();
      }
      break;
    default:
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT FloatingBallWindow::HandleMenuMessage(HWND hwnd, UINT message,
                                              WPARAM wparam,
                                              LPARAM lparam) noexcept {
  switch (message) {
    // 同球窗：鼠标与触摸 / 触控笔按下都不激活。
    case WM_POINTERACTIVATE:
    case WM_MOUSEACTIVATE:
      return OverlayNoActivateReply(message);
    case WM_MOUSEMOVE: {
      if (!tracking_leave_) {
        TRACKMOUSEEVENT tme = {sizeof(tme), TME_LEAVE, hwnd, 0};
        tracking_leave_ = TrackMouseEvent(&tme) != FALSE;
      }
      const int hit = ButtonAt(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      if (hit != hovered_) {
        hovered_ = hit;
        RenderMenu();
      }
      if (pressed_ < 0) {
        UpdateTooltip(hit);
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      tracking_leave_ = false;
      HideTooltip();
      if (hovered_ >= 0) {
        hovered_ = -1;
        RenderMenu();
      }
      return 0;
    case WM_LBUTTONDOWN: {
      const int hit = ButtonAt(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      pressed_ = hit;
      HideTooltip();
      if (hit >= 0) {
        SetCapture(hwnd);
      }
      RenderMenu();
      return 0;
    }
    case WM_LBUTTONUP: {
      const int pressed = pressed_;
      pressed_ = -1;
      if (GetCapture() == hwnd) {
        ReleaseCapture();
      }
      const int hit = ButtonAt(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
      if (pressed >= 0 && pressed == hit) {
        // 可能在这里 Stop() 拆掉本窗口：之后不再碰 hwnd。
        RunButton(pressed);
        return 0;
      }
      RenderMenu();
      return 0;
    }
    case WM_CAPTURECHANGED:
      if (pressed_ >= 0) {
        pressed_ = -1;
        RenderMenu();
      }
      return 0;
    case WM_DPICHANGED:
      // 按钮窗按创建时的几何画到收起为止；DPI 变化由球窗收起重摆时一并拆掉它。
      return 0;
    case WM_NCDESTROY:
      SetWindowLongPtr(hwnd, GWLP_USERDATA, 0);
      if (menu_hwnd_ == hwnd) {
        menu_hwnd_ = nullptr;
        tooltip_hwnd_ = nullptr;
        tooltip_index_ = -1;
        hovered_ = -1;
        pressed_ = -1;
        tracking_leave_ = false;
      }
      break;
    default:
      break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
