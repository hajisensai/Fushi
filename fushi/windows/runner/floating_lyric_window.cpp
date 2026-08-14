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

constexpr wchar_t kWindowClassName[] = L"FushiFloatingLyricWindow";

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
// Hook mode draws a centred 9-slot toolbar (9 * 30 + 8 * 10 = 350dip). The
// generic 280dip floor would let the user drag the window narrower than its own
// controls, clipping the leading voice buttons; hook mode therefore floors at
// the toolbar width plus a small margin. Bump this whenever kSlotCount grows —
// the floor is derived from the row width, not from a taste-based round number.
constexpr float kHookTextMinStripWidthDip = 370.0f;
// Shift-悬停查词的轮询表（只在鼠标停在浮窗里时挂着，见 StartHoverLookupPolling）。
// 60ms ≈ 一次按键的最短可感知延迟，且远低于用户「按下 Shift 想看词」的心理预期；
// 只在窗口内轮询，代价是一次 GetAsyncKeyState + 一次 DWrite 命中测试。
constexpr UINT_PTR kHoverLookupTimerId = 1;
constexpr UINT kHoverLookupPollMs = 60;
constexpr float kMinStripHeightDip = 64.0f;
constexpr float kMaxStripWidthDip = 2400.0f;
constexpr float kMaxStripHeightDip = 480.0f;
// A press must travel this far (logical px) before it becomes a drag rather
// than a word-lookup tap — lets the bar be dragged from anywhere on the text.
constexpr float kDragThresholdDip = 6.0f;
// 振假名相对基准字的字号比例，以及为它加高的行盒比例（相对注音字号）。
// 0.45 是日文排版里 ruby 的常用比例（约基准的一半再收一点），行盒留 1.25 倍
// 注音高度，假名与基准字之间因此有一条细缝，不会贴在一起。
constexpr float kRubyFontScale = 0.45f;
constexpr float kRubyLineGapScale = 1.25f;
// 桌面歌词式文字渲染（仅 hook 台词浮窗）：文字自带「投影 + 描边」，可读性不再
// 依赖底板，于是背景可以像音乐播放器桌面歌词一样默认全透明。
//
// 描边不走自定义 DirectWrite 文本渲染器（overlay_ruby_render_guard 明确禁止
// ——它会让绘制路径与 CharIndexAt / 高亮 / 滚动共用的那份 text_layout_ 几何
// 分叉），而是把**同一个**
// text_layout_ 按 8 个方向偏移多画几遍：几何天然逐像素一致，点字 index、折行、
// 滚动、注音全部不动。8 遍 + 阴影 + 填充共 10 次 DrawTextLayout，只在文本 /
// 悬停 / 拖动变化时重绘，代价可忽略。
constexpr float kLyricOutlineRadiusDip = 1.6f;
constexpr float kLyricShadowOffsetDip = 2.0f;
constexpr uint32_t kLyricOutlineColor = 0xE0000000;  // 88% 黑描边
constexpr uint32_t kLyricShadowColor = 0x59000000;   // 35% 黑投影
// Base logical font size the lyric text was authored at; the rendered font
// scales with the bar height so growing the bar enlarges the text too.
constexpr float kBaseStripHeightForFontDip = 96.0f;
// BUG-1095 — hook mode does NOT scale its font with the window height.
//
// It used to: the caption font was style_.font_size * clamp(height / 140dip,
// 0.9, 2.5). Because strip_height_dip_ is read straight back off the live
// window rect (SyncStripSizeFromWindow on every WM_SIZE), "drag the overlay
// taller" and "enlarge the caption" were the SAME gesture. Dragging from the
// 140dip default to the 480dip ceiling (3.4x taller) also multiplied the font
// by 2.5, so the visible line count only crept from ~2.3 to ~4.3 — which is
// exactly the user report: "it doesn't fit, and dragging it taller STILL
// doesn't fit". Height and font size are two independent things the user
// wants to control, so they are now two independent inputs: the window rect
// stays the drag target, and the font size comes from its own preference
// (gal_hook_text_font_size -> Style::font_size). At the authored default
// height the old formula evaluated to exactly 1.0, so a user who never
// dragged the overlay sees pixel-identical text.
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
constexpr int kHookTextControlSlotCount = hook_toolbar::kSlotCount;
// BUG-951: padding between the standalone pass-through toolbar window's edge
// and its button row. Small on purpose — this window sits ON TOP of the game
// and every pixel of it is a pixel the player cannot click — but non-zero so
// there is a background strip to grab when dragging the overlay.
constexpr float kToolbarWindowMarginDip = 5.0f;

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

// BUG-1095 (第二阶段) — hook 台词的滚动条 / 滚轮步长（逻辑 96-DPI px）。
//
// 轨道画在文本区**右侧的留白**里：text_rect_ 只占 [pad, width - pad]，所以这条
// 指示条压不到任何一个字，也就不必为它缩窄换行宽度——缩窄宽度会反过来改变
// metrics.height，从而改变可滚行程，形成回环。轨道底端让开右下角 resize grip，
// 免得两个可拖拽的东西叠在同一块像素上。
constexpr float kScrollBarWidthDip = 4.0f;
constexpr float kScrollBarMinThumbDip = 16.0f;
constexpr float kScrollWheelStepDip = 40.0f;

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
        hook_text_mode_ ? L"Fushi Hook Text" : window_title_.c_str(),
        WS_POPUP, x, y, width, height,
        nullptr, nullptr, GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
    if (has_initial_bounds_) {
      const int restored_width = initial_bounds_.right - initial_bounds_.left;
      const int restored_height = initial_bounds_.bottom - initial_bounds_.top;
      if (restored_width > 0 && restored_height > 0) {
        // 存下来的宽度可能比**今天**的工具栏还窄（老版本槽位少、下限也低）。不夹
        // 一下，恢复出来的窗口会把首尾按钮裁掉；下限本身就是按当前槽数算的。
        const int min_width =
            static_cast<int>(ScaleForDpi(MinStripWidthDip()));
        SetWindowPos(hwnd_, HWND_TOPMOST, initial_bounds_.left,
                     initial_bounds_.top, std::max(restored_width, min_width),
                     restored_height, SWP_NOACTIVATE);
        SyncStripSizeFromWindow();
        ClampCurrentPositionToWindowMonitor();
      }
    }
  }

  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  visible_ = true;
  // BUG-951: a re-show while pass-through is still on must re-create the
  // escape-hatch toolbar and re-arm the body's click-through in one place.
  ApplyPassThroughExStyle();
  RequestRender();
  return true;
}

void FloatingLyricWindow::CancelPointerGesture() {
  pressed_ = false;
  dragging_ = false;
  press_was_text_ = false;
  if (hwnd_ != nullptr && GetCapture() == hwnd_) {
    ReleaseCapture();
  }
}

void FloatingLyricWindow::Hide() {
  visible_ = false;
  hovered_ = false;
  tracking_mouse_leave_ = false;
  // BUG-1471: a hidden window never receives the WM_LBUTTONUP that would end an
  // in-flight press. Clearing only `dragging_` here left `pressed_` stuck true
  // across the hide, and MaybeHoverLookup bails on `pressed_` -- hover lookup
  // then stayed dead for the rest of the session while the text kept updating.
  CancelPointerGesture();
  // 隐藏后收不到 WM_MOUSELEAVE：定时器留着就是后台空转。
  StopHoverLookupPolling();
  ResetHoverLookupAnchor();
  // BUG-951: hand clicks back unconditionally and take the toolbar down with
  // the body. A hidden window that is still WS_EX_TRANSPARENT would come back
  // click-through even if pass-through was switched off while hidden.
  ApplyPassThroughExStyle();
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
                                    const std::string& context_id,
                                    const std::vector<RubySpan>& ruby_spans) {
  text_ = text;
  // 注音区间只信任落在新文本范围内的那些：越界的一律丢掉，绝不让一段错位的
  // 振假名飘在别的字上面（宁可不显示）。
  ruby_spans_.clear();
  const int text_length = static_cast<int>(text.size());
  for (const RubySpan& span : ruby_spans) {
    if (span.start < 0 || span.length <= 0 || span.ruby.empty()) continue;
    if (span.start + span.length > text_length) continue;
    ruby_spans_.push_back(span);
  }
  context_id_ = context_id;
  current_line_start_ = current_line_start;
  current_line_length_ = current_line_length;
  highlight_start_ = -1;
  highlight_length_ = 0;
  text_layout_.Reset();
  // BUG-1095 (第二阶段) — 新台词一律回到顶部。
  //
  // 这里换掉的是**整句**，不是往下追加：保留旧偏移只会把用户直接扔到一句他还
  // 没读过的话的中间，比「跳回开头」糟得多。所以没有「用户正在往下看就别动」
  // 的分支——那个分支要成立，前提是新旧文本连续，而 hook 台词从来不是。
  scroll_offset_px_ = 0.0f;
  scroll_max_px_ = 0.0f;
  // 换了台词，去重锚指的那个下标已经是另一个字了：不清就会出现「新句子里鼠标下
  // 的字正好同号 → 悬停不查」。
  ResetHoverLookupAnchor();
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
  ruby_format_.Reset();
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

void FloatingLyricWindow::SetTopmost(bool enabled) {
  topmost_ = enabled;
  if (hwnd_ == nullptr) {
    // 还没建窗：Show() 自己会按 topmost_ 插入 Z 序。
    return;
  }
  // 不做「值没变就早退」：Dart 每局 show 会再调一次 SetTopmost(true)，同值也把窗口
  // 重新插到 Z 序顶上——上一局被别的窗口爬到上面时，这一次复位就是把它拉回来。
  SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  RequestRender();
}

void FloatingLyricWindow::SetHoverAutoLookup(bool enabled) {
  if (hover_auto_lookup_ == enabled) {
    return;
  }
  hover_auto_lookup_ = enabled;
  // 开关一变，上一次的去重锚就没有意义了（刚关掉时更要清，否则重新按 Shift 停在
  // 同一个字上会被当成「已经查过」）。
  ResetHoverLookupAnchor();
}

bool FloatingLyricWindow::ScrollBy(float delta_px) {
  // 三个前置条件写在一处，调用方（WM_MOUSEWHEEL）不必再抄一遍：
  //  * 只有 hook 台词能滚——歌词条 / 剪贴板文本窗保持历史行为，一字不改；
  //  * 穿透模式下鼠标整个属于游戏，滚轮不归我们（BUG-951 之后正文窗直接带
  //    WS_EX_TRANSPARENT，系统压根不往这儿投鼠标消息；这条判据留着是为了
  //    「先置位、还没走到应用 ex-style」那一瞬也不例外）；
  //  * 没有溢出就没有行程，返回 false 让事件继续往下传。
  if (!hook_text_mode_ || pass_through_ || scroll_max_px_ <= 0.0f) {
    return false;
  }
  const float next =
      std::clamp(scroll_offset_px_ + delta_px, 0.0f, scroll_max_px_);
  if (next == scroll_offset_px_) {
    return false;  // 已经顶到头 / 到底：不吞事件。
  }
  scroll_offset_px_ = next;
  RequestRender();
  return true;
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
    CancelPointerGesture();
  }
  RequestRender();
}

void FloatingLyricWindow::SetPassThrough(bool enabled) {
  if (pass_through_ == enabled) {
    return;
  }
  pass_through_ = enabled;
  CancelPointerGesture();
  // A click-through body receives no mouse messages at all, so it will never
  // see the WM_MOUSELEAVE that would normally clear the hover state. Clear it
  // here or the body would render its hovered appearance forever.
  hovered_ = false;
  tracking_mouse_leave_ = false;
  ApplyPassThroughExStyle();
  RequestRender();
}

void FloatingLyricWindow::ApplyPassThroughExStyle() {
  if (hwnd_ == nullptr) {
    return;
  }
  // Only the galgame hook overlay has a pass-through mode. The audiobook lyric
  // strip and the clipboard text window never reach the branch below, so their
  // window styles are byte-for-byte what they always were.
  const bool want = hook_text_mode_ && pass_through_ && visible_;
  if (!want) {
    pass_through_toolbar_.Hide();
    SetBodyExTransparent(false);
    return;
  }
  if (!toolbar_callbacks_bound_) {
    pass_through_toolbar_.SetActionCallback(
        [this](const std::string& action) { DispatchControlAction(action); });
    pass_through_toolbar_.SetDragCallback(
        [this](int x, int y) { MoveBodyTo(x, y); });
    pass_through_toolbar_.SetDragEndCallback([this]() {
      SyncStripSizeFromWindow();
      // The clamp can still nudge the body (e.g. the drag ended half off a
      // monitor edge), so re-sync the toolbar before reporting the bounds —
      // otherwise the pill would sit a few px away from the body it belongs to.
      ClampCurrentPositionToWindowMonitor();
      SyncPassThroughToolbar();
      NotifyBoundsChanged();
    });
    toolbar_callbacks_bound_ = true;
  }
  // Escape hatch FIRST. The body may only stop taking clicks once the window
  // that can switch pass-through back off is actually on screen; if it cannot
  // be created we refuse the toggle instead of stranding the user.
  if (!pass_through_toolbar_.Show(ComputePassThroughToolbarLayout(),
                                  ToolbarStyle(), ToolbarStates())) {
    SetBodyExTransparent(false);
    pass_through_ = false;
    // Tell Dart the toggle was refused. Without this its own flag stays true,
    // and the user's next press on the button sends setPassThrough(false) into
    // an already-false native state — a press that visibly does nothing.
    if (on_pass_through_) {
      on_pass_through_(false);
    }
    return;
  }
  // BUG-1480: deliberately do NOT set WS_EX_TRANSPARENT here any more.
  //
  // 用户要的是「穿透态下仍能点文字查词」。WS_EX_TRANSPARENT 是全窗口级的，OS 连
  // WM_LBUTTONDOWN 都不投，字和背景一视同仁 —— 想留一个能点的字就得再造一套机制。
  // 而这个窗口是 UpdateLayeredWindow 的逐像素 alpha 窗：**alpha-0 像素本来就会把
  // 点击透给下面的窗口，跨进程有效，且与 WM_NCHITTEST 无关**（这正是 BUG-1046 那条
  // 注释记录的事实）。所以把背景强制成 alpha 0（见 Render）之后，OS 自己就给出了
  // 我们要的两分：背景像素 → 游戏，字形像素 → 我们。
  //
  // 与 BUG-951 的区别必须说清，别被"又回到老路"误伤：BUG-951 修掉的是
  // HTTRANSPARENT，那玩意只在**同线程**窗口间走，永远到不了另一个进程的游戏，所以
  // 点击是被**吞掉**的；PR#460 修掉的是**定时器翻转可交互性**的竞态。逐像素 alpha
  // 既不是前者也不是后者：它是 OS 在合成阶段就判定"这个窗口在这个像素上不存在"。
  SetBodyExTransparent(false);
}

void FloatingLyricWindow::SetBodyExTransparent(bool enabled) {
  if (hwnd_ == nullptr || ex_transparent_ == enabled) {
    return;
  }
  const LONG_PTR bit = static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
  LONG_PTR ex = GetWindowLongPtr(hwnd_, GWL_EXSTYLE);
  ex = enabled ? (ex | bit) : (ex & ~bit);
  SetWindowLongPtr(hwnd_, GWL_EXSTYLE, ex);
  // An ex-style change is not picked up until the frame is revalidated; without
  // SWP_FRAMECHANGED the window keeps hit-testing with the OLD style.
  SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  ex_transparent_ = enabled;
}

hook_toolbar::Layout FloatingLyricWindow::ComputePassThroughToolbarLayout()
    const {
  hook_toolbar::Layout layout;
  if (hwnd_ == nullptr) {
    return layout;
  }
  RECT wr = {};
  if (!GetWindowRect(hwnd_, &wr)) {
    return layout;
  }
  const float btn = ScaleForDpi(kButtonSizeDip);
  const float gap = ScaleForDpi(kButtonGapDip);
  const float margin = ScaleForDpi(kToolbarWindowMarginDip);
  const float row_w = btn * kHookTextControlSlotCount +
                      gap * (kHookTextControlSlotCount - 1);
  // Same origin the in-body toolbar draws at (centred row, kControlsTopDip from
  // the top), grown by |margin| so the pill has an edge to grab for dragging.
  const float body_w = static_cast<float>(wr.right - wr.left);
  const float row_x = wr.left + (body_w - row_w) / 2.0f;
  const float row_y = wr.top + ScaleForDpi(kControlsTopDip);
  layout.rect.left = static_cast<LONG>(std::lround(row_x - margin));
  layout.rect.top = static_cast<LONG>(std::lround(row_y - margin));
  layout.rect.right =
      layout.rect.left + static_cast<LONG>(std::lround(row_w + margin * 2));
  layout.rect.bottom =
      layout.rect.top + static_cast<LONG>(std::lround(btn + margin * 2));
  layout.owner_origin = POINT{wr.left, wr.top};
  layout.button_px = btn;
  layout.gap_px = gap;
  layout.margin_px = margin;
  return layout;
}

hook_toolbar::Style FloatingLyricWindow::ToolbarStyle() const {
  hook_toolbar::Style style;
  style.button_text_color = style_.button_text_color;
  style.button_bg_color = style_.button_bg_color;
  style.active_color = style_.active_color;
  style.bg_color = style_.bg_color;
  return style;
}

hook_toolbar::States FloatingLyricWindow::ToolbarStates() const {
  hook_toolbar::States states;
  states.replaying = replaying_;
  states.recapturing = recapturing_;
  states.playing = playing_;
  states.pass_through = pass_through_;
  states.locked = locked_;
  states.topmost = topmost_;
  return states;
}

void FloatingLyricWindow::SyncPassThroughToolbar() {
  if (!pass_through_toolbar_.IsShowing()) {
    return;
  }
  pass_through_toolbar_.Sync(ComputePassThroughToolbarLayout(), ToolbarStyle(),
                             ToolbarStates());
}

void FloatingLyricWindow::MoveBodyTo(int x, int y) {
  if (hwnd_ == nullptr) {
    return;
  }
  RECT rc;
  if (!GetWindowRect(hwnd_, &rc)) {
    return;
  }
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  // Clamp against the monitor under the cursor, exactly like the body's own
  // drag path (TODO-832), so dragging by the toolbar cannot push the overlay
  // off-screen and can still slide it across displays.
  POINT cursor;
  if (GetCursorPos(&cursor)) {
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {};
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfo(monitor, &mi)) {
      const POINT clamped =
          ClampOriginToWorkArea(x, y, width, height, mi.rcWork);
      x = clamped.x;
      y = clamped.y;
    }
  }
  SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOACTIVATE);
  SyncPassThroughToolbar();
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
      // 鼠标进了窗口才开轮询表：静止光标上按下 Shift 也要能出词（BUG-880 在视频页
      // 的同款坑）。离开窗口时 WM_MOUSELEAVE 停表。
      StartHoverLookupPolling();
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
      // Shift-悬停查词：按住 Shift 在台词上划过即逐字查词（与阅读器 / 视频字幕的
      // onShiftHover 同语义）。命中新字才派发一次，见 MaybeHoverLookup。
      MaybeHoverLookup(static_cast<float>(GET_X_LPARAM(lparam)),
                       static_cast<float>(GET_Y_LPARAM(lparam)));
      return 0;
    }
    case WM_TIMER: {
      if (wparam != kHoverLookupTimerId) {
        return DefWindowProc(hwnd_, message, wparam, lparam);
      }
      // 轮询只补一件 WM_MOUSEMOVE 补不了的事：光标不动、用户刚按下 Shift。光标位置
      // 现问系统（不缓存），落在窗口外就直接停表——WM_MOUSELEAVE 偶尔会因为窗口 Z
      // 序变化而不来，这是兜底。
      POINT cursor;
      if (!GetCursorPos(&cursor)) {
        return 0;
      }
      RECT rc;
      if (!GetWindowRect(hwnd_, &rc) || !PtInRect(&rc, cursor)) {
        StopHoverLookupPolling();
        ResetHoverLookupAnchor();
        return 0;
      }
      POINT client = cursor;
      ScreenToClient(hwnd_, &client);
      MaybeHoverLookup(static_cast<float>(client.x),
                       static_cast<float>(client.y));
      return 0;
    }
    case WM_MOUSELEAVE: {
      tracking_mouse_leave_ = false;
      StopHoverLookupPolling();
      ResetHoverLookupAnchor();
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
      if (!action.empty()) {
        DispatchControlAction(action);
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
    // BUG-1471: the system took our capture away (foreground window changed —
    // the game grabbing focus back is a per-session event for a WS_EX_NOACTIVATE
    // background-thread window). The button-up for this press will never arrive,
    // so end the gesture here or `pressed_` stays true forever and hover lookup
    // goes silent for the rest of the session while the text keeps updating.
    case WM_CAPTURECHANGED: {
      CancelPointerGesture();
      return 0;
    }
    case WM_LBUTTONUP: {
      const bool was_dragging = dragging_;
      const bool was_pressed = pressed_;
      const bool was_text = press_was_text_;
      const POINT lookup_pt = press_client_;
      CancelPointerGesture();
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
      if (!was_dragging && was_pressed && was_text) {
        DispatchLookupAt(static_cast<float>(lookup_pt.x),
                         static_cast<float>(lookup_pt.y));
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
      //
      // BUG-951: there is deliberately NO pass-through branch here any more.
      // HTTRANSPARENT only walks same-thread windows, so it never reached the
      // galgame (a different process) — the click was simply swallowed. Real
      // pass-through is WS_EX_TRANSPARENT on the whole body window, applied in
      // ApplyPassThroughExStyle(); while it is set this handler is not called
      // at all, which is exactly the point.
      POINT screen = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      POINT client = screen;
      ScreenToClient(hwnd_, &client);
      if (ResizeGripContains(static_cast<float>(client.x),
                             static_cast<float>(client.y))) {
        return HTBOTTOMRIGHT;
      }
      return HTCLIENT;
    }
    case WM_MOUSEWHEEL: {
      // BUG-1095 (第二阶段) — 滚轮翻台词。交互契约写在这里，别处不再重复：
      //
      //  * **接管条件**全在 ScrollBy 里（hook 模式 + 非穿透 + 真有溢出）。不满足
      //    就落回 DefWindowProc，歌词条 / 剪贴板文本窗的行为一字不改。
      //  * **穿透模式**下正文窗带 WS_EX_TRANSPARENT，系统不投递任何鼠标消息，
      //    滚轮压根到不了这里（BUG-951）；工具条独立窗自己不吃滚轮。穿透就是
      //    「鼠标整个属于游戏」，不留半个例外。
      //  * **和工具条不打架**：那八个按钮只吃 WM_LBUTTONDOWN，从不吃滚轮。所以
      //    滚轮的命中区可以是整个窗口，不需要「避开按钮」这种特例分支——鼠标停
      //    在按钮上滚也照样翻文本，这正是用户预期。
      //  * **滚到顶 / 滚到底不吞事件**（ScrollBy 返回 false），避免把窗口变成一
      //    个吃掉滚轮的黑洞。
      const int delta = GET_WHEEL_DELTA_WPARAM(wparam);
      if (delta != 0) {
        const float step = ScaleForDpi(kScrollWheelStepDip) *
                           (-static_cast<float>(delta) / WHEEL_DELTA);
        if (ScrollBy(step)) {
          return 0;
        }
      }
      return DefWindowProc(hwnd_, message, wparam, lparam);
    }
    case WM_SIZE: {
      // A system resize (corner drag) changed the window rect; recompute the
      // logical strip size and re-render so the text + controls follow.
      SyncStripSizeFromWindow();
      text_format_.Reset();
      ruby_format_.Reset();
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
  // BUG-1480: pass-through now relies on PER-PIXEL hit testing (see
  // ApplyPassThroughExStyle) instead of WS_EX_TRANSPARENT, so the background
  // MUST be truly alpha 0 — otherwise a user-chosen visible background makes
  // the whole rect opaque, the OS routes every click to us, and the game gets
  // nothing. This is the exact failure the old per-pixel behaviour had; forcing
  // the fill removes the "only works if you happened to set opacity 0" caveat
  // rather than documenting it.
  if (hook_text_mode_ && pass_through_) {
    body_bg &= 0x00FFFFFF;
  }
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> brush;
  render_target_->CreateSolidColorBrush(ColorFromArgb(body_bg),
                                        brush.GetAddressOf());
  render_target_->FillRoundedRectangle(bg_rect, brush.Get());

  // Text format / layout. The audiobook lyric strip keeps its historical
  // behaviour: its authored font size assumes the default bar height and the
  // live font scales with strip_height_dip_, so dragging the resize grip larger
  // enlarges the lyric text too. Hook mode does NOT (BUG-1095): its font size is
  // an independent user preference, so dragging the overlay taller buys visible
  // LINES instead of re-inflating the same two lines.
  const float height_scale =
      hook_text_mode_ ? 1.0f : strip_height_dip_ / kBaseStripHeightForFontDip;
  const float scaled_font = static_cast<float>(style_.font_size) *
                            std::max(0.5f, height_scale);
  // 注音字号与行盒加高量（物理 px）。ruby_spans_ 为空时下面所有注音分支都不执行，
  // 排版与绘制逐像素回到引入注音之前。
  const float ruby_font_px =
      static_cast<float>(ScaleForDpi(scaled_font * kRubyFontScale));
  const float ruby_gap_px = ruby_font_px * kRubyLineGapScale;
  const bool has_ruby = !ruby_spans_.empty();

  // 桌面歌词字重：hook 模式半粗（描边字太细会被描边吃掉笔画）；歌词条 / 剪贴板
  // 窗保持 NORMAL，逐像素不变。
  const DWRITE_FONT_WEIGHT text_weight = hook_text_mode_
                                             ? DWRITE_FONT_WEIGHT_SEMI_BOLD
                                             : DWRITE_FONT_WEIGHT_NORMAL;
  if (text_format_ == nullptr) {
    dwrite_factory_->CreateTextFormat(
        L"Yu Gothic UI", nullptr, text_weight,
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

  // 振假名的小号 format：居中 + 不换行。注音比基准字窄时居中压在基准上方；比
  // 基准宽时向两侧对称溢出（DrawText 不带 CLIP 选项不会自己裁，外层已经用
  // PushAxisAlignedClip 把一切文字绘制框在 text_rect_ 里，绝不会画到控件带上）。
  if (has_ruby && ruby_format_ == nullptr) {
    dwrite_factory_->CreateTextFormat(
        L"Yu Gothic UI", nullptr, text_weight,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, ruby_font_px,
        L"", ruby_format_.GetAddressOf());
    if (ruby_format_ != nullptr) {
      ruby_format_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
      ruby_format_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
      ruby_format_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    }
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

  // BUG-1095 (第二阶段) — 可滚行程每帧从零重算：文本 / 字号 / 窗高任何一项变了都
  // 在下面的排版分支里重新量出来。没有文本 = 没有行程（分支根本不执行）；非 hook
  // 模式也永远停在 0，歌词条 / 剪贴板窗因此完全不受滚动这套东西影响。
  scroll_max_px_ = 0.0f;

  if (text_format_ != nullptr && !text_.empty()) {
    if (text_layout_ == nullptr) {
      dwrite_factory_->CreateTextLayout(text_.c_str(),
                                        static_cast<UINT32>(text_.size()),
                                        text_format_.Get(), text_rect_.width,
                                        text_rect_.height,
                                        text_layout_.GetAddressOf());
      // 有注音就把每行的行盒整体加高、基线整体下压 ruby_gap_px：多出来的空间
      // 正好落在每行字的**正上方**，注音画进去既不遮基准字，也不会压到上一行。
      // 只加高、不改宽，所以自动折行的断点与没有注音时完全一致。
      if (has_ruby && text_layout_ != nullptr) {
        // 先问行数再按数分配：缓冲区不足时 DirectWrite 只回填 actualLineCount，
        // 并不写入 metrics，拿一个未初始化的行高去设行距会直接把排版搞乱。
        UINT32 line_count = 0;
        text_layout_->GetLineMetrics(nullptr, 0, &line_count);
        if (line_count > 0) {
          std::vector<DWRITE_LINE_METRICS> lines(line_count);
          if (SUCCEEDED(text_layout_->GetLineMetrics(lines.data(), line_count,
                                                     &line_count)) &&
              line_count > 0) {
            text_layout_->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM,
                                         lines[0].height + ruby_gap_px,
                                         lines[0].baseline + ruby_gap_px);
          }
        }
      }
    }
    if (text_layout_ != nullptr) {
      // BUG-1095: with scrolling added (phase 2) the strip no longer loses the
      // tail for good, but WHICH end is off-screen first still matters. With the paragraph
      // vertically centred, an over-long caption loses its head AND its tail
      // symmetrically — the user cannot even start reading. Top-align the hook
      // caption the moment it no longer fits, so reading order is preserved and
      // only the tail is lost; a caption that fits stays centred (unchanged
      // pixels). Scoped to hook mode: the audiobook lyric strip wants its
      // current line near the middle, so its centring is left alone.
      if (hook_text_mode_) {
        DWRITE_TEXT_METRICS metrics = {};
        if (SUCCEEDED(text_layout_->GetMetrics(&metrics))) {
          text_layout_->SetParagraphAlignment(
              metrics.height > text_rect_.height
                  ? DWRITE_PARAGRAPH_ALIGNMENT_NEAR
                  : DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
          // BUG-1095 (第二阶段) — 溢出量就是可滚动行程。
          //
          // 顶端对齐（上面那句 NEAR）让排版从 text_rect_.top 起画，于是「滚动」
          // 就是把绘制原点整体上移 scroll_offset_px_，而下面的裁剪框 text_clip
          // 一动不动 —— 视口下移，被裁掉的句尾从下面走进来。这是分层窗里唯一
          // 不需要第二个渲染目标就能做出来的滚动。
          scroll_max_px_ = std::max(0.0f, metrics.height - text_rect_.height);
        }
      }
      scroll_offset_px_ = std::clamp(scroll_offset_px_, 0.0f, scroll_max_px_);
      // 没有溢出时 scroll_offset_px_ 恒为 0，text_origin_y == text_rect_.top，
      // 与滚动引入之前逐像素一致。
      const float text_origin_y = text_rect_.top - scroll_offset_px_;
      // BUG-1070: the lyric / hook-text body is vertically centred
      // (DWRITE_PARAGRAPH_ALIGNMENT_CENTER) inside a layout box whose top edge
      // is text_rect_.top == controls_h, i.e. just below the hover control band
      // [kControlsTopDip, kControlsTopDip + kButtonSizeDip]. When the wrapped
      // text is taller than the box (many lines in a short strip), vertical
      // centring pushes the extra lines symmetrically OUTWARD, so the top lines
      // spill ABOVE the box into the control band. Because the buttons only
      // occupy the horizontal centre, the spilled glyphs show through the two
      // uncovered sides of the toolbar strip and read as "the subtitle is
      // covering the UI". Clip every pixel of text drawing (highlight fills +
      // the DrawTextLayout below) to text_rect_ so nothing is ever painted above
      // y == controls_h. text_rect_ is already in physical px (its top/left use
      // the same ScaleForDpi() as the render target's pixel-sized DIB), so no
      // extra DIP→px conversion is needed. A short single line stays vertically
      // centred well inside text_rect_ and is therefore never clipped.
      const D2D1_RECT_F text_clip = D2D1::RectF(
          text_rect_.left, text_rect_.top, text_rect_.left + text_rect_.width,
          text_rect_.top + text_rect_.height);
      render_target_->PushAxisAlignedClip(text_clip,
                                          D2D1_ANTIALIAS_MODE_ALIASED);
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
                D2D1::RectF(text_rect_.left + m.left, text_origin_y + m.top,
                            text_rect_.left + m.left + m.width,
                            text_origin_y + m.top + m.height),
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
      // 桌面歌词式描边（仅 hook 模式）：同一 text_layout_ 先按 8 向偏移画描边、
      // 再画投影，最后回到原点画填充。所有遍都在上面的 text_clip 之内。
      // hook 的 UpdateText 恒传 current_line_start=-1，不存在 per-range dim
      // drawing effect，因此描边遍不会被 SetDrawingEffect 换色。
      Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> lyric_outline;
      Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> lyric_shadow;
      if (hook_text_mode_) {
        render_target_->CreateSolidColorBrush(
            ColorFromArgb(kLyricOutlineColor), lyric_outline.GetAddressOf());
        render_target_->CreateSolidColorBrush(
            ColorFromArgb(kLyricShadowColor), lyric_shadow.GetAddressOf());
      }
      if (hook_text_mode_ && lyric_outline != nullptr &&
          lyric_shadow != nullptr) {
        const float shadow_off = ScaleForDpi(kLyricShadowOffsetDip);
        render_target_->DrawTextLayout(
            D2D1::Point2F(text_rect_.left + shadow_off * 0.5f,
                          text_origin_y + shadow_off),
            text_layout_.Get(), lyric_shadow.Get(), D2D1_DRAW_TEXT_OPTIONS_NONE);
        const float r = ScaleForDpi(kLyricOutlineRadiusDip);
        const float d = r * 0.7071f;
        const D2D1_POINT_2F ring[8] = {
            {r, 0.0f},  {-r, 0.0f}, {0.0f, r},  {0.0f, -r},
            {d, d},     {d, -d},    {-d, d},    {-d, -d}};
        for (const D2D1_POINT_2F& off : ring) {
          render_target_->DrawTextLayout(
              D2D1::Point2F(text_rect_.left + off.x, text_origin_y + off.y),
              text_layout_.Get(), lyric_outline.Get(),
              D2D1_DRAW_TEXT_OPTIONS_NONE);
        }
      }
      render_target_->DrawTextLayout(
          D2D1::Point2F(text_rect_.left, text_origin_y), text_layout_.Get(),
          brush.Get(), D2D1_DRAW_TEXT_OPTIONS_NONE);

      // 振假名：画在基准字所在行盒的顶部那条留白里（行距已在建 layout 时加高）。
      //
      // 几何全部问 text_layout_ 要，用的是高亮背景框同一套 HitTestTextRange —— 这
      // 意味着注音不需要任何自己的排版：折行、居中、滚动偏移怎么动，注音就怎么
      // 跟着动。text_ 里也**不含**任何注音字符，所以 CharIndexAt 的 textPosition、
      // Highlight 的 range、dim 的 range 三个既有契约一个都没被碰。
      //
      // 一段注音跨行时（基准被折行切开）只取第一个矩形：把读音压在句首那半边，
      // 比在两行上各画半个假名可读。
      if (has_ruby && ruby_format_ != nullptr) {
        for (const RubySpan& span : ruby_spans_) {
          UINT32 hit_count = 0;
          text_layout_->HitTestTextRange(static_cast<UINT32>(span.start),
                                         static_cast<UINT32>(span.length), 0, 0,
                                         nullptr, 0, &hit_count);
          if (hit_count == 0) continue;
          std::vector<DWRITE_HIT_TEST_METRICS> boxes(hit_count);
          if (FAILED(text_layout_->HitTestTextRange(
                  static_cast<UINT32>(span.start),
                  static_cast<UINT32>(span.length), 0, 0, boxes.data(),
                  hit_count, &hit_count)) ||
              hit_count == 0) {
            continue;
          }
          const DWRITE_HIT_TEST_METRICS& box = boxes[0];
          const D2D1_RECT_F ruby_rect = D2D1::RectF(
              text_rect_.left + box.left, text_origin_y + box.top,
              text_rect_.left + box.left + box.width,
              text_origin_y + box.top + ruby_gap_px);
          // 注音的桌面歌词描边：字小，半径收到 0.75 倍、不画投影。
          if (hook_text_mode_ && lyric_outline != nullptr) {
            const float rr = ScaleForDpi(kLyricOutlineRadiusDip * 0.75f);
            const float rd = rr * 0.7071f;
            const D2D1_POINT_2F ruby_ring[8] = {
                {rr, 0.0f}, {-rr, 0.0f}, {0.0f, rr},  {0.0f, -rr},
                {rd, rd},   {rd, -rd},   {-rd, rd},   {-rd, -rd}};
            for (const D2D1_POINT_2F& off : ruby_ring) {
              const D2D1_RECT_F shifted = D2D1::RectF(
                  ruby_rect.left + off.x, ruby_rect.top + off.y,
                  ruby_rect.right + off.x, ruby_rect.bottom + off.y);
              render_target_->DrawTextW(
                  span.ruby.c_str(), static_cast<UINT32>(span.ruby.size()),
                  ruby_format_.Get(), shifted, lyric_outline.Get(),
                  D2D1_DRAW_TEXT_OPTIONS_NONE);
            }
          }
          render_target_->DrawTextW(
              span.ruby.c_str(), static_cast<UINT32>(span.ruby.size()),
              ruby_format_.Get(), ruby_rect, brush.Get(),
              D2D1_DRAW_TEXT_OPTIONS_NONE);
        }
      }
      // BUG-1070: balance the PushAxisAlignedClip that fenced the text to
      // text_rect_ (must pop before the control band / toolbar is drawn so the
      // buttons are unaffected).
      render_target_->PopAxisAlignedClip();

      // BUG-1095 (第二阶段) — 滚动指示条。没有它用户根本不知道「下面还有」，
      // 也看不出自己滚到了哪里。画在 text_rect_ 右侧的留白里（见
      // kScrollBarWidthDip 的注释），所以不遮字、不改换行宽度；只在 hook 模式
      // 且真有溢出时才出现，其余情况一个像素都不画。
      if (hook_text_mode_ && scroll_max_px_ > 0.0f) {
        const float bar_w = ScaleForDpi(kScrollBarWidthDip);
        const float bar_x =
            static_cast<float>(width) - pad * 0.5f - bar_w * 0.5f;
        const float track_top = text_rect_.top;
        const float track_bottom = std::max(
            track_top + bar_w,
            text_rect_.top + text_rect_.height - ScaleForDpi(kResizeGripDip));
        const float track_h = track_bottom - track_top;
        const float content_h = text_rect_.height + scroll_max_px_;
        const float min_thumb =
            std::min(track_h, ScaleForDpi(kScrollBarMinThumbDip));
        const float thumb_h = std::clamp(
            track_h * (text_rect_.height / std::max(1.0f, content_h)),
            min_thumb, track_h);
        const float thumb_y =
            track_top +
            (track_h - thumb_h) * (scroll_offset_px_ / scroll_max_px_);
        Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> bar;
        render_target_->CreateSolidColorBrush(
            ColorFromArgb(style_.button_text_color), bar.GetAddressOf());
        if (bar != nullptr) {
          bar->SetOpacity(hovered_ ? 0.12f : 0.05f);
          render_target_->FillRoundedRectangle(
              D2D1::RoundedRect(
                  D2D1::RectF(bar_x, track_top, bar_x + bar_w, track_bottom),
                  bar_w / 2.0f, bar_w / 2.0f),
              bar.Get());
          bar->SetOpacity(hovered_ ? 0.75f : 0.35f);
          render_target_->FillRoundedRectangle(
              D2D1::RoundedRect(
                  D2D1::RectF(bar_x, thumb_y, bar_x + bar_w, thumb_y + thumb_h),
                  bar_w / 2.0f, bar_w / 2.0f),
              bar.Get());
        }
      }
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

    // BUG-951: while the hook body is click-through the toolbar lives in its
    // own always-clickable window (HookToolbarWindow). Painting the band here
    // as well would both double it visually and advertise a grab handle that
    // takes no mouse input any more — the body is purely visual in that mode.
    const bool draw_body_toolbar = !(hook_text_mode_ && pass_through_);

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
    if (draw_body_toolbar) {
      render_target_->FillRoundedRectangle(strip_rect, strip_bg.Get());
    }

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
    if (draw_body_toolbar) {
      render_target_->FillRoundedRectangle(grip_rect, grip_brush.Get());
    }

    // Controls appear only on hover. Clipboard mode keeps its historical
    // right-aligned buttons (transparency, pin/topmost, lock); Hook mode uses a
    // centred shared-slot core toolbar. Their hit areas in ControlActionAt() are
    // gated on hovered_ too, so a click can never hit an invisible button.
    if (hovered_ && draw_body_toolbar) {
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
        // Glyph + active tint come from the shared slot table, so the in-body
        // toolbar and the standalone pass-through toolbar always draw the same
        // buttons in the same order (BUG-951).
        const hook_toolbar::States tb_states = ToolbarStates();
        for (int slot = 0; slot < kHookTextControlSlotCount; ++slot) {
          draw_tbtn(left + slot * (t_btn + t_gap),
                    hook_toolbar::SlotGlyph(slot, tb_states),
                    hook_toolbar::SlotActive(slot, tb_states));
        }
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

  // BUG-951: one funnel keeps the standalone toolbar in step with the body.
  // Every state change already ends in a render, and Sync() is a no-op when
  // nothing it cares about moved — so per-line caption updates do not turn into
  // toolbar repaints.
  SyncPassThroughToolbar();
}

void FloatingLyricWindow::DispatchControlAction(const std::string& action) {
  if (action.empty()) {
    return;
  }
  if (action == "lock") {
    // The lock button toggles the position lock locally and reports the new
    // state to Dart; it is never a no-op (unlike the old desktop strip).
    locked_ = !locked_;
    if (locked_ && (pressed_ || dragging_)) {
      // BUG-1471: this used to clear the flags without releasing capture, while
      // the channel path (SetLocked) released it — same action, two behaviours.
      CancelPointerGesture();
    }
    if (on_lock_) {
      on_lock_(locked_);
    }
    RequestRender();
    return;
  }
  if (action == "topmost") {
    // 按钮按下 = 翻转，落地走 SetTopmost（与 Dart 的会话复位同一条路径）。
    // Pin button (clipboard Luna toolbar + galgame hook toolbar slot 7): toggle
    // always-on-top locally (LunaTranslator #36). Handled natively — no Dart
    // round-trip — and every window-Z SetWindowPos reads topmost_ so the new
    // state sticks. Re-pinning also re-asserts HWND_TOPMOST, which is the way
    // back up when another window has since climbed over the overlay.
    //
    // 只作用于**正文窗**。穿透态下的独立工具条窗（HookToolbarWindow）永远保持
    // HWND_TOPMOST：它是 BUG-951 的逃生口，被压到游戏底下就等于用户再也回不来，
    // 所以这里刻意不把 Z 同步给它。
    SetTopmost(!topmost_);
    return;
  }
  if (on_control_) {
    on_control_(action);
  }
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
        // Shared slot table (hook_toolbar::kSlotActions): the standalone
        // pass-through toolbar indexes the very same array, so the two windows
        // physically cannot disagree about what a button does.
        return hook_toolbar::kSlotActions[slot];
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

bool FloatingLyricWindow::DispatchLookupAt(float x, float y) {
  if (on_lookup_ == nullptr && on_context_lookup_ == nullptr) {
    return false;
  }
  D2D1_RECT_F char_rect = {};
  const int index = CharIndexAt(x, y, &char_rect);
  if (index < 0) {
    return false;
  }
  int utf8_len =
      WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                          static_cast<int>(text_.size()), nullptr, 0, nullptr,
                          nullptr);
  std::string utf8(utf8_len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text_.c_str(),
                      static_cast<int>(text_.size()), utf8.data(), utf8_len,
                      nullptr, nullptr);
  if (on_context_lookup_) {
    // Client-area physical px -> screen logical px: the lookup card
    // anchors to the tapped word, so it must be in the same unit
    // system Dart uses for screen rects.
    const float scale = std::max(0.01f, static_cast<float>(dpi_) / 96.0f);
    RECT wr = {};
    GetWindowRect(hwnd_, &wr);
    const D2D1_RECT_F screen_rect =
        D2D1::RectF((wr.left + char_rect.left) / scale,
                    (wr.top + char_rect.top) / scale,
                    (wr.left + char_rect.right) / scale,
                    (wr.top + char_rect.bottom) / scale);
    on_context_lookup_(context_id_, utf8, index, screen_rect);
    return true;
  }
  on_lookup_(utf8, index);
  return true;
}

void FloatingLyricWindow::ResetHoverLookupAnchor() { hover_lookup_index_ = -1; }

void FloatingLyricWindow::MaybeHoverLookup(float x, float y) {
  // 只有 gal hook 浮窗走悬停查词：歌词条 / 剪贴板文本窗保持「点字才查」，一字不改。
  // 按下左键的那段（pending press / 拖窗 / 拉伸）里也不查——那是另一套手势，用户
  // 正在移动窗口，不是在读词。
  if (!hook_text_mode_ || !click_lookup_enabled_ || pressed_ || dragging_) {
    return;
  }
  // BUG-1480：穿透态不再整窗吃掉查词。
  //
  // 旧契约是「鼠标整个属于游戏」，因为正文窗带 WS_EX_TRANSPARENT、系统根本不投鼠标
  // 消息，于是这里必须显式挡掉靠全局光标位置轮询的悬停查词。现在穿透改成逐像素
  // 命中：**背景像素归游戏、字形像素归我们**，所以「光标正压在一个字上」这件事本身
  // 就是合法的查词信号，不该再被挡。
  //
  // 但仍保留一条收窄：穿透态只认**按住 Shift** 的悬停查词，不认「自动悬停即查」。
  // 穿透的用途是把鼠标让给游戏，纯移动就弹卡片会在玩的过程中不停打断；Shift 是
  // 用户的显式意图声明。点击查词不受此限（点在字上本来就到不了游戏）。
  const bool pass_through_requires_shift = pass_through_;
  if (on_lookup_ == nullptr && on_context_lookup_ == nullptr) {
    return;
  }
  // Shift 只能问**物理**键态：这个窗口是 WS_EX_NOACTIVATE 的分层窗，键盘焦点永远
  // 在游戏那边，GetKeyState 读的是本线程消息队列的同步键态（对一个从不收键盘消息
  // 的窗口来说永远不会更新）。GetAsyncKeyState 读的是全局实时键态，才是对的。
  const bool shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
  if (pass_through_requires_shift && !shift) {
    ResetHoverLookupAnchor();
    return;
  }
  if (!shift && !hover_auto_lookup_) {
    ResetHoverLookupAnchor();
    return;
  }
  const int index = CharIndexAt(x, y);
  if (index < 0) {
    // 移出文本区（空白 / 工具条 / 滚动条）即松锚，回来时同一个字仍会再查一次。
    ResetHoverLookupAnchor();
    return;
  }
  if (index == hover_lookup_index_) {
    return;  // 同一个字：抖动、轮询都不重复查词。
  }
  hover_lookup_index_ = index;
  if (!DispatchLookupAt(x, y)) {
    ResetHoverLookupAnchor();
  }
}

void FloatingLyricWindow::StartHoverLookupPolling() {
  if (hover_poll_active_ || hwnd_ == nullptr || !hook_text_mode_) {
    return;
  }
  if (SetTimer(hwnd_, kHoverLookupTimerId, kHoverLookupPollMs, nullptr) != 0) {
    hover_poll_active_ = true;
  }
}

void FloatingLyricWindow::StopHoverLookupPolling() {
  if (!hover_poll_active_) {
    return;
  }
  if (hwnd_ != nullptr) {
    KillTimer(hwnd_, kHoverLookupTimerId);
  }
  hover_poll_active_ = false;
}

int FloatingLyricWindow::CharIndexAt(float x, float y,
                                     D2D1_RECT_F* out_char_rect) {
  if (text_.empty() || text_layout_ == nullptr) {
    return -1;
  }
  const float local_x = x - text_rect_.left;
  // BUG-1095 (第二阶段) — 边界判在**视口**里（用户只点得到看得见的字），坐标
  // 换算到**布局**里（加回滚动偏移）。少了这一步，滚动之后点第一行会命中已经
  // 被滚上去的那一行。scroll_offset_px_ 在非 hook 模式恒为 0，旧行为不变。
  const float viewport_y = y - text_rect_.top;
  if (local_x < 0 || local_x > text_rect_.width || viewport_y < 0 ||
      viewport_y > text_rect_.height) {
    return -1;
  }
  const float local_y = viewport_y + scroll_offset_px_;
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
    out_char_rect->top = text_rect_.top + metrics.top - scroll_offset_px_;
    out_char_rect->right = out_char_rect->left + metrics.width;
    out_char_rect->bottom = out_char_rect->top + metrics.height;
  }
  return static_cast<int>(metrics.textPosition);
}
