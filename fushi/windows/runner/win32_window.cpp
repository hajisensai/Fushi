#include "win32_window.h"

#include "startup_reveal_policy.h"
#include "test_window_origin_pin.h"
#include "window_activation_policy.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <chrono>
#include <cstdint>

#include "resource.h"

namespace {

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
    FreeLibrary(user32_module);
  }
}

// Far off every physical monitor; the same coordinate Windows itself uses to
// park minimized windows. Combined with WS_EX_NOACTIVATE this hides the runner
// without pausing the Flutter engine (the window stays WS_VISIBLE so it keeps
// producing frames — it is simply never on screen).
constexpr int kOffscreenOrigin = -32000;

// True when FUSHI_TEST_HIDDEN is set (to anything non-empty). In that mode the
// runner creates its window off-screen and non-activating so automated
// integration tests can drive the real desktop app — focus moves, settings
// changes, WebView DOM probes — without it appearing on screen or stealing
// keyboard/foreground focus from whatever the user is doing. GetEnvironmentVariable
// with a null buffer returns the required size (>0) when the variable exists.
bool IsTestHiddenMode() {
  return GetEnvironmentVariableW(L"FUSHI_TEST_HIDDEN", nullptr, 0) > 0;
}

// True when FUSHI_TEST_ONSCREEN is set (to anything non-empty). Only meaningful
// together with test-hidden mode: the window keeps WS_EX_NOACTIVATE (it still
// never steals the user's foreground/keyboard focus) but is placed at a real
// on-screen origin instead of off-screen, so DWM composes it for Windows
// Graphics Capture / OS screen-grab screenshots. Lets a non-blocking visible
// capture exist without hijacking what the user is doing.
bool IsTestOnscreenMode() {
  return GetEnvironmentVariableW(L"FUSHI_TEST_ONSCREEN", nullptr, 0) > 0;
}

// A test-mode "x,y,w,h" environment variable parsed into a physical-pixel
// rect; nullopt outside test-hidden mode, when unset, or when malformed.
std::optional<RECT> ReadTestRectSpec(const wchar_t* name) {
  if (!IsTestHiddenMode()) {
    return std::nullopt;
  }
  wchar_t spec[64] = {0};
  if (GetEnvironmentVariableW(name, spec, 64) == 0) {
    return std::nullopt;
  }
  int x = 0, y = 0, w = 0, h = 0;
  if (swscanf_s(spec, L"%d,%d,%d,%d", &x, &y, &w, &h) != 4 || w <= 0 ||
      h <= 0) {
    return std::nullopt;
  }
  return RECT{x, y, x + w, y + h};
}

// FUSHI_TEST_TOPMOST: see Win32Window::ApplyTestTopmostPlacement.
std::optional<RECT> ReadTestTopmostSpec() {
  return ReadTestRectSpec(L"FUSHI_TEST_TOPMOST");
}

// FUSHI_TEST_WINDOW_RECT="x,y,w,h" (BUG-3888 frame-time probe): the window's
// outer rect in physical pixels, pinned for the whole run (origin and size)
// without TOPMOST and without borrowing the foreground thread's input state:
// the window stays WS_EX_NOACTIVATE and the user's windows may cover it.
// Ignored when FUSHI_TEST_TOPMOST is also set (that one wins).
std::optional<RECT> ReadTestWindowRectSpec() {
  if (ReadTestTopmostSpec()) {
    return std::nullopt;
  }
  return ReadTestRectSpec(L"FUSHI_TEST_WINDOW_RECT");
}

// The main window stays hidden through Flutter startup. This backdrop is only
// a fallback for native surface transitions after the window is revealed.
constexpr COLORREF kInitialBackdropColor = RGB(0x1F, 0x49, 0x59);

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    // BUG-1916: 窗口类不带背景画刷（stock 模板值）。背景由每个窗口实例的
    // backdrop_brush_ 在 WM_ERASEBKGND / WM_SIZE 里自己画，见 PaintBackdrop。
    window_class.hbrBackground = nullptr;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window()
    : backdrop_brush_(CreateSolidBrush(kInitialBackdropColor)) {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
  if (backdrop_brush_ != nullptr) {
    DeleteObject(backdrop_brush_);
    backdrop_brush_ = nullptr;
  }
}

bool Win32Window::CreateAndShow(const std::wstring& title,
                                const Point& origin,
                                const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // Background test mode: park the window off-screen and make it non-activating
  // (no taskbar button, never takes foreground) so integration tests can drive
  // the real app without disturbing the user. WS_VISIBLE is kept so the engine
  // keeps rendering; only the position + ex-style change.
  const bool hidden = IsTestHiddenMode();
  // On-screen test mode keeps the window non-activating (WS_EX_NOACTIVATE, so it
  // never steals the user's foreground/keyboard focus) but at a real on-screen
  // origin so it is composed for screenshots. Default test mode stays parked
  // off-screen. Both are non-blocking; only the position differs.
  const bool onscreen = hidden && IsTestOnscreenMode();
  const DWORD ex_style = hidden ? (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) : 0;
  const int window_x =
      (hidden && !onscreen) ? kOffscreenOrigin : Scale(origin.x, scale_factor);
  const int window_y =
      (hidden && !onscreen) ? kOffscreenOrigin : Scale(origin.y, scale_factor);

  // Normal launches keep the native window hidden until Dart reveals it after
  // the first ready/error frame has rasterized. Test windows remain visible so
  // the integration harness can capture and drive them.
  // BUG-1916: WS_CLIPCHILDREN — the Flutter view is a child HWND that covers
  // the whole client area; WM_PAINT erases (BeginPaint) must not touch the
  // pixels under it (that matters if the engine ever falls back to software
  // rendering, where the view paints into this same surface). The deliberate
  // under-the-view fills go through FillSurfaceBackdrop instead.
  const DWORD window_style =
      WS_CLIPCHILDREN |
      (hidden ? (WS_OVERLAPPEDWINDOW | WS_VISIBLE) : WS_OVERLAPPEDWINDOW);

  HWND window = CreateWindowEx(
      ex_style, window_class, title.c_str(), window_style,
      window_x, window_y, Scale(size.width, scale_factor),
      Scale(size.height, scale_factor), nullptr, nullptr,
      GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // BUG-5521: a hidden launch waits for Dart's reveal, but startup placement
  // can show the window first — restoring a maximized session posts
  // SC_MAXIMIZE, and maximizing a hidden window shows it (no WM_SHOWWINDOW is
  // sent on that path, measured). Cloak it now, before anything can show it:
  // a cloaked window still maximizes and is still composed, so the first
  // frame is rasterized at the final size; RevealStartupWindow lifts the
  // cloak. Test windows are visible from creation and never cloaked.
  startup_cloaked_ = false;
  if (::fushi::ShouldCloakAtCreation(hidden)) {
    BOOL cloak = TRUE;
    startup_cloaked_ = SUCCEEDED(
        DwmSetWindowAttribute(window, DWMWA_CLOAK, &cloak, sizeof(cloak)));
  }

  // Ask the OS to deliver WM_POWERBROADCAST when a monitor powers on so the
  // window can repaint after the display returns (TODO-689). Registered after
  // the window exists (window_handle_ is set in WM_NCCREATE). The handle is
  // released in Destroy() to avoid a leak.
  power_notify_ = RegisterPowerSettingNotification(
      window_handle_, &GUID_MONITOR_POWER_ON, DEVICE_NOTIFY_WINDOW_HANDLE);

  ApplyTestTopmostPlacement(window);

  // BUG-3768: armed only now, after the runner's own placement above; from
  // here on every move (Dart startup placement, window_manager, DPI change)
  // keeps this origin. See test_window_origin_pin.h.
  const std::optional<RECT> topmost = ReadTestTopmostSpec();
  const std::optional<RECT> fixed_rect = ReadTestWindowRectSpec();
  const std::optional<RECT> evidence = topmost ? topmost : fixed_rect;
  test_origin_pin_ = ResolveTestWindowOriginPin(
      hidden, onscreen,
      evidence ? std::optional<POINT>(POINT{evidence->left, evidence->top})
               : std::nullopt,
      POINT{kOffscreenOrigin, kOffscreenOrigin});
  test_size_pin_ = ResolveTestWindowSizePin(
      hidden, fixed_rect ? std::optional<SIZE>(
                               SIZE{fixed_rect->right - fixed_rect->left,
                                    fixed_rect->bottom - fixed_rect->top})
                         : std::nullopt);

  return OnCreate();
}

// FUSHI_TEST_TOPMOST="x,y,w,h" (test mode only, alongside FUSHI_TEST_ONSCREEN):
// park the window there and make it TOPMOST so pixel-level evidence capture
// (screen grab / desktop duplication) is never covered by the user's windows.
// A background process' own HWND_TOPMOST is silently dropped by the shell
// (WS_EX_TOPMOST never set — measured, HDR Phase 0), so borrow the foreground
// thread's input state for the single SetWindowPos; no focus / foreground
// change is made, the window stays WS_EX_NOACTIVATE.
void Win32Window::ApplyTestTopmostPlacement(HWND window) {
  const std::optional<RECT> spec = ReadTestTopmostSpec();
  if (!spec) {
    // FUSHI_TEST_WINDOW_RECT: plain placement. No z-order change, no input
    // state borrowing, no activation.
    if (const std::optional<RECT> fixed = ReadTestWindowRectSpec()) {
      SetWindowPos(window, nullptr, fixed->left, fixed->top,
                   fixed->right - fixed->left, fixed->bottom - fixed->top,
                   SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
    }
    return;
  }
  const int x = spec->left;
  const int y = spec->top;
  const int w = spec->right - spec->left;
  const int h = spec->bottom - spec->top;
  const HWND foreground = GetForegroundWindow();
  const DWORD fg_thread =
      foreground ? GetWindowThreadProcessId(foreground, nullptr) : 0;
  const DWORD self_thread = GetCurrentThreadId();
  const bool attached = fg_thread != 0 && fg_thread != self_thread &&
                        AttachThreadInput(fg_thread, self_thread, TRUE);
  SetWindowPos(window, HWND_TOPMOST, x, y, w, h,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  if (attached) {
    AttachThreadInput(fg_thread, self_thread, FALSE);
  }
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    // BUG-3768: rewrite before any handler sees the request — plugins answer
    // top-level messages first in FlutterWindow::MessageHandler and could
    // otherwise consume it. Not consumed here; dispatch continues as usual.
    if (message == WM_WINDOWPOSCHANGING) {
      PinWindowPosOrigin(reinterpret_cast<WINDOWPOS*>(lparam),
                         that->test_origin_pin_, IsIconic(window) != 0);
      PinWindowPosSize(reinterpret_cast<WINDOWPOS*>(lparam),
                       that->test_size_pin_, IsIconic(window) != 0);
    }
    // BUG-5591: while fullscreen the client area is the monitor, whatever the
    // show state. Answered here, before any plugin: window_manager's
    // hidden-title-bar WM_NCCALCSIZE would pin a zoomed window's client to
    // the work-area origin (see FullscreenClientRect).
    if (message == WM_NCCALCSIZE && wparam != 0 && that->fullscreen_) {
      auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      params->rgrc[0] = fushi::FullscreenClientRect(params->rgrc[0],
                                                    that->fullscreen_monitor_);
      return 0;
    }
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  // BUG-5521: the hang watchdog's forced startup reveal (another thread).
  // Registered message, so it cannot be a case label below.
  if (message == ::fushi::ForceStartupRevealMessage()) {
    RevealStartupWindow();
    return 0;
  }
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      // BUG-2006: the client area just changed; re-evaluate whether this
      // window now presents edge to edge and therefore must not have DWM
      // paint its border / rounded corners over app content. Transition-only
      // (see UpdateFrameChrome), so a drag-resize costs one comparison per
      // WM_SIZE, not a DwmSetWindowAttribute round trip.
      UpdateFrameChrome();
      // BUG-5591: a snapshot still waiting for the view's post-fullscreen
      // frame is stale once the window is resized again outside a fullscreen
      // transition (e.g. the user drags an edge): back to the brush.
      if (transition_snapshot_ != nullptr && !fullscreen_transition_) {
        ReleaseTransitionSnapshot();
      }
      // BUG-1916: the surface just changed size; its new area is uninitialised
      // (black) and its old area may carry an older fill. Paint it whole,
      // under the view too, before the view is resized — the child MoveWindow
      // below blocks until the engine presents a frame of the new size. On the
      // hardware path the view is its own composition layer, so this fill is
      // never visible through it; if the engine has fallen back to software
      // rendering (view paints into this same surface) the worst case is one
      // theme-coloured frame under the view — still better than the old
      // teal erase on every WM_PAINT.
      FillSurfaceBackdrop();
      // Size and position the child window — through the resize gate
      // (BUG-2462), never with a bare MoveWindow.
      SyncChildToClientArea();
      return 0;
    }

    case WM_ERASEBKGND:
      // BUG-1916: erase with the instance backdrop brush (fallback colour
      // before Dart pushes the live theme surface).
      // Child-clipped, so once the view covers the client this paints nothing.
      //
      // This supersedes the earlier `if (child_content_) return TRUE; break;`
      // guard, which existed only to stop DefWindowProc from erasing the parent
      // with the *class* brush and flashing a #1F4959 rectangle over the child
      // during live resize. The class brush is gone now (hbrBackground =
      // nullptr), so that `break` would fall through to a DefWindowProc with no
      // brush at all — painting nothing. The wparam DC honours
      // WS_CLIPCHILDREN, so "don't cover the child" is structural rather than
      // a special case:
      // there is no child yet at cold start (fallback fill lands), and once the
      // view covers the client area this call is clipped down to nothing.
      PaintBackdrop(reinterpret_cast<HDC>(wparam));
      return 1;

    // Braced: this case declares locals, and without its own scope MSVC rejects
    // the switch outright (C2360, initialization skipped by a later case label).
    case WM_ACTIVATE: {
      // BUG-1933: fullscreen keeps the window HWND_TOPMOST so it covers the
      // taskbar (see SetFullscreen). Holding topmost while another app is
      // active would keep a screen-sized window over everything, so drop it on
      // deactivation and take it back when the window is activated again.
      if (fullscreen_) {
        SetWindowPos(hwnd,
                     LOWORD(wparam) == WA_INACTIVE ? HWND_NOTOPMOST
                                                   : HWND_TOPMOST,
                     0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      }
      // WM_ACTIVATE is sent for both sides of an activation hand-off. When an
      // activatable Fushi auxiliary window starts its native move/size loop,
      // the main window receives WA_INACTIVE. Restoring focus from that
      // deactivation notification pulls the main window back above the
      // auxiliary window and the user's foreground app.
      // A non-null HWND is not sufficient: child views can be destroyed and
      // Windows recycles handle values. Confirm both liveness and ownership so
      // a later main-window activation cannot focus an unrelated recycled HWND.
      const bool child_is_live =
          child_content_ != nullptr && IsWindow(child_content_);
      const bool child_belongs_to_window =
          child_is_live && GetParent(child_content_) == hwnd;
      if (ShouldRestoreChildFocus(wparam, child_is_live,
                                  child_belongs_to_window)) {
        SetFocus(child_content_);
      }
      return 0;
    }

    case WM_TIMER:
      if (wparam == kStuckDeferralTimerId) {
        KillTimer(window_handle_, kStuckDeferralTimerId);
        ReleaseStuckChildDeferral();
        return 0;
      }
      break;

    case WM_DISPLAYCHANGE:
      // Display topology / resolution / depth changed (e.g. a monitor came
      // back). Invalidate and ask the renderer for a fresh frame so the window
      // does not stay blank (TODO-689). Falls through to DefWindowProc.
      InvalidateRect(window_handle_, nullptr, FALSE);
      OnDisplayRecovered();
      break;

    case WM_POWERBROADCAST:
      // A monitor powered on. lparam carries a POWERBROADCAST_SETTING only for
      // PBT_POWERSETTINGCHANGE; guard the wparam, the non-null lparam and the
      // GUID before dereferencing to avoid a wild pointer.
      if (wparam == PBT_POWERSETTINGCHANGE && lparam != 0) {
        auto* setting = reinterpret_cast<POWERBROADCAST_SETTING*>(lparam);
        if (setting->PowerSetting == GUID_MONITOR_POWER_ON &&
            setting->Data[0] != 0) {
          InvalidateRect(window_handle_, nullptr, FALSE);
          OnDisplayRecovered();
        }
      }
      // WM_POWERBROADCAST must return TRUE to grant/acknowledge the event.
      return TRUE;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  startup_window_preparation_ = false;
  // Clear the borrowed Flutter-view handle before subclass teardown. Destroying
  // the controller can synchronously destroy that child and dispatch more
  // window messages; retaining it would turn a later HWND reuse into a focus or
  // resize operation against an unrelated window.
  child_content_ = nullptr;
  ReleaseTransitionSnapshot();
  OnDestroy();

  // Release the monitor power-on notification registration before the window
  // goes away so the handle is not leaked (TODO-689). Idempotent: nulled after
  // unregister, and re-entry (WM_DESTROY then ~Win32Window) sees nullptr.
  if (power_notify_) {
    UnregisterPowerSettingNotification(power_notify_);
    power_notify_ = nullptr;
  }

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SyncChildToClientArea();

  SetFocus(child_content_);
}

void Win32Window::SyncChildToClientArea() {
  if (child_content_ == nullptr || startup_window_preparation_) {
    return;
  }
  const RECT rect = GetClientArea();
  const ChildSize size{static_cast<int32_t>(rect.right - rect.left),
                       static_cast<int32_t>(rect.bottom - rect.top)};
  switch (child_resize_gate_.Request(size)) {
    case ChildResizeGate::Decision::kDeliver:
      DeliverChildSize(size);
      break;
    case ChildResizeGate::Decision::kNoChange:
      break;
    case ChildResizeGate::Decision::kDefer:
      // The size the engine currently presents at is being requested while an
      // earlier delivery is still unconfirmed — exactly the sequence that pins
      // the engine's resize target and drops every frame. The child keeps its
      // current size until Dart confirms the pending one
      // (OnChildFrameRasterized), which then delivers this request.
      break;
  }
  ArmStuckDeferralWatchdog();
}

void Win32Window::DeliverChildSize(ChildSize size) {
  // A confirmed delivery may hand back a parked size to deliver next (only
  // after the watchdog nudge); loop until the gate has nothing more to say.
  std::optional<ChildSize> next = size;
  while (next.has_value() && child_content_ != nullptr) {
    // MoveWindow sends the child's WM_SIZE synchronously; the engine blocks
    // inside it for up to kWindowResizeTimeout waiting for a frame of the new
    // size. The measured duration therefore tells the gate whether that wait
    // succeeded (see ChildResizeGate::DeliveryFinished).
    const auto start = std::chrono::steady_clock::now();
    MoveWindow(child_content_, 0, 0, next->width, next->height, TRUE);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - start)
                             .count();
    next = child_resize_gate_.DeliveryFinished(elapsed);
  }
}

void Win32Window::OnChildFrameRasterized(int32_t width, int32_t height) {
  // BUG-5591: the view now presents at the post-fullscreen-jump size; the
  // transition snapshot under a see-through surface has done its job.
  if (transition_snapshot_ != nullptr && !fullscreen_transition_ &&
      width == snapshot_release_size_.cx &&
      height == snapshot_release_size_.cy) {
    ReleaseTransitionSnapshot();
    FillSurfaceBackdrop();
  }
  if (startup_window_preparation_) {
    return;
  }
  const std::optional<ChildSize> deferred =
      child_resize_gate_.OnFrameRasterized(ChildSize{width, height});
  if (deferred.has_value()) {
    DeliverChildSize(*deferred);
  }
  ArmStuckDeferralWatchdog();
}

bool Win32Window::BeginStartupWindowPreparation() {
  if (window_handle_ == nullptr || IsWindowVisible(window_handle_) ||
      startup_window_preparation_) {
    return false;
  }
  startup_window_preparation_ = true;
  return true;
}

void Win32Window::EndStartupWindowPreparation() {
  if (!startup_window_preparation_) {
    return;
  }
  startup_window_preparation_ = false;
  SyncChildToClientArea();
}

void Win32Window::RevealStartupWindow() {
  if (window_handle_ == nullptr) {
    return;
  }
  // Order is irrelevant for what the user sees (a cloaked window shows
  // nothing either way), but uncloak first so a maximized window appears in
  // one step rather than being shown and then uncloaked.
  if (startup_cloaked_) {
    startup_cloaked_ = false;
    BOOL cloak = FALSE;
    DwmSetWindowAttribute(window_handle_, DWMWA_CLOAK, &cloak, sizeof(cloak));
  }
  // SW_SHOW keeps a maximized window maximized.
  ShowWindow(window_handle_, SW_SHOW);
}

void Win32Window::ArmStuckDeferralWatchdog() {
  if (window_handle_ == nullptr) {
    return;
  }
  // One timer, re-armed whenever a deferral is (still) parked and cleared as
  // soon as it is not: SetTimer with the same id replaces the previous timer,
  // so the watchdog measures "parked for this long without progress" from the
  // last gate event, not from the first.
  if (child_resize_gate_.has_deferred()) {
    SetTimer(window_handle_, kStuckDeferralTimerId, kStuckDeferralTimeoutMs,
             nullptr);
  } else {
    KillTimer(window_handle_, kStuckDeferralTimerId);
  }
}

void Win32Window::ReleaseStuckChildDeferral() {
  const std::optional<ChildSize> nudge =
      child_resize_gate_.ReleaseStuckDeferred();
  if (nudge.has_value()) {
    DeliverChildSize(*nudge);
  }
  // The nudge itself may have timed out (Dart still busy): keep watching, the
  // parked size is released when the nudge gets confirmed.
  ArmStuckDeferralWatchdog();
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

void Win32Window::SetBackdropColor(COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  if (brush == nullptr) {
    return;
  }
  if (backdrop_brush_ != nullptr) {
    DeleteObject(backdrop_brush_);
  }
  backdrop_brush_ = brush;
  // Without this the surface keeps the fallback fill under the view
  // forever, and the first maximize shows it (BUG-1916 residual).
  FillSurfaceBackdrop();
}

void Win32Window::FillSurfaceBackdrop() {
  if (window_handle_ == nullptr) {
    return;
  }
  // GetDCEx with plain DCX_CACHE deliberately ignores WS_CLIPCHILDREN so the
  // fill reaches under the child; GetDC would clip it out.
  HDC dc = GetDCEx(window_handle_, nullptr, DCX_CACHE);
  if (dc == nullptr) {
    return;
  }
  // BUG-1933: during a fullscreen transition, prefer the pre-transition frame
  // over the solid brush — a raced composition then shows stretched app
  // content instead of a colour flash. Everything else (interactive resize,
  // theme pushes) has no snapshot and keeps the cheap brush fill.
  // BUG-5591: on a see-through (Mica) surface too. Plain GDI blits write
  // alpha 0, which DWM composes additively — the ghost frame BUG-2964 kept
  // the snapshot off Mica for, which in turn left the bare material (RGB 243
  // in a light theme) showing for 1-3 frames of every jump. The snapshot
  // carries alpha 255 (CaptureTransitionSnapshot) and goes down through
  // AlphaBlend, which writes it: opaque on any surface. SetFullscreen puts
  // the plain backdrop back once the view has presented its new size, so the
  // snapshot never lingers under translucent Flutter pixels.
  bool painted = false;
  if (transition_snapshot_ != nullptr) {
    RECT rect = GetClientArea();
    HDC mem = CreateCompatibleDC(dc);
    if (mem != nullptr) {
      HGDIOBJ old = SelectObject(mem, transition_snapshot_);
      SetStretchBltMode(dc, COLORONCOLOR);
      const BLENDFUNCTION opaque{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
      painted = AlphaBlend(dc, 0, 0, rect.right - rect.left,
                           rect.bottom - rect.top, mem, 0, 0,
                           transition_snapshot_size_.cx,
                           transition_snapshot_size_.cy, opaque) != 0;
      SelectObject(mem, old);
      DeleteDC(mem);
    }
  }
  if (!painted) {
    PaintBackdrop(dc);
  }
  ReleaseDC(window_handle_, dc);
}

void Win32Window::PaintBackdrop(HDC dc) {
  if (dc == nullptr || backdrop_brush_ == nullptr || window_handle_ == nullptr) {
    return;
  }
  RECT rect = GetClientArea();
  FillRect(dc, &rect,
           fushi::MainSurfaceSeeThrough(main_surface_state())
               ? static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH))
               : backdrop_brush_);
}

void Win32Window::SetSystemBackdrop(bool enabled) {
  if (system_backdrop_ == enabled) {
    return;
  }
  system_backdrop_ = enabled;
  FillSurfaceBackdrop();
}

namespace {

// BUG-2006: true when the window's client area covers its monitor edge to
// edge. window_manager's hidden-title-bar WM_NCCALCSIZE gives this window a
// client area that reaches the frame, so a screen-covering window puts app
// content under every pixel of DWM-painted chrome.
//
// Measured on Windows 11 26200: in the runner's own fullscreen (the BUG-1933
// framed giant window — SW_SHOWNORMAL and not zoomed, because entering
// un-maximizes first) the frame insets are 8/1/8/8, so the 1 px top border
// lands on screen row 0 and 3830/3840 of it is the accent colour, with the
// desktop showing through all four rounded corners. A genuinely maximized
// window measured 11/11/11/11 on the same machine and showed no line at all
// — which is exactly why the test is "does the client reach the edges", not
// "which window state is this": the insets are a function of WM_NCCALCSIZE,
// DPI and Windows version, not of the state name.
bool ClientCoversMonitor(HWND hwnd) {
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                      &monitor)) {
    return false;
  }
  RECT client{};
  if (!GetClientRect(hwnd, &client)) {
    return false;
  }
  POINT origin{0, 0};
  if (!ClientToScreen(hwnd, &origin)) {
    return false;
  }
  return origin.x <= monitor.rcMonitor.left &&
         origin.y <= monitor.rcMonitor.top &&
         origin.x + (client.right - client.left) >= monitor.rcMonitor.right &&
         origin.y + (client.bottom - client.top) >= monitor.rcMonitor.bottom;
}

// Drop (or restore) the compositor-painted border and corner rounding.
//
// Measured on Windows 11 26200 with a faithful standalone repro (a window with
// window_manager's WM_NCCALCSIZE reshaping, client filled a known colour, the
// screen sampled): with the border enabled 600/600 pixels of the client's top
// row are chrome; with DWMWA_BORDER_COLOR=DWMWA_COLOR_NONE it is 0/600; and
// restoring the default brings the line straight back. DWMWCP_DONOTROUND is a
// separate fix for the corners — it alone leaves the top line untouched
// (measured), and the border colour alone leaves the corners clipped.
//
// Both attributes are Windows 11 (build 22000+) only; DwmSetWindowAttribute
// fails harmlessly on older Windows, which has no rounded corners and where
// window_manager already keeps a 1 px top border out of the client area.
void ApplyFrameChrome(HWND hwnd, bool suppress) {
  DWORD corner_preference = suppress ? DWMWCP_DONOTROUND : DWMWCP_DEFAULT;
  DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                        &corner_preference, sizeof(corner_preference));
  COLORREF border_color = suppress ? DWMWA_COLOR_NONE : DWMWA_COLOR_DEFAULT;
  DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &border_color,
                        sizeof(border_color));
}

}  // namespace

void Win32Window::UpdateFrameChrome() {
  HWND hwnd = window_handle_;
  if (hwnd == nullptr) {
    return;
  }
  // The three ways this window presents edge to edge. Windows drops the
  // border and the rounding for a maximized window on its own; a
  // custom-frame window has to ask, and the runner-owned fullscreen and a
  // screen-sized normal window need exactly the same treatment.
  const bool suppress =
      fullscreen_ || IsZoomed(hwnd) != 0 || ClientCoversMonitor(hwnd);
  if (suppress == frame_chrome_suppressed_) {
    return;
  }
  frame_chrome_suppressed_ = suppress;
  ApplyFrameChrome(hwnd, suppress);
}

namespace {

// BUG-5591: DWM's restore / maximize animation shows the window surface, not
// the Flutter view. The fullscreen show-state changes are one-step jumps to
// their final rectangle, so they must not animate at all.
class ScopedNoDwmTransitions {
 public:
  explicit ScopedNoDwmTransitions(HWND hwnd) : hwnd_(hwnd) { Set(TRUE); }
  ~ScopedNoDwmTransitions() { Set(FALSE); }
  ScopedNoDwmTransitions(const ScopedNoDwmTransitions&) = delete;
  ScopedNoDwmTransitions& operator=(const ScopedNoDwmTransitions&) = delete;

 private:
  void Set(BOOL disabled) {
    DwmSetWindowAttribute(hwnd_, DWMWA_TRANSITIONS_FORCEDISABLED, &disabled,
                          sizeof(disabled));
  }
  HWND hwnd_;
};

}  // namespace

void Win32Window::SetFullscreen(bool fullscreen) {
  HWND hwnd = window_handle_;
  if (hwnd == nullptr || fullscreen == fullscreen_) {
    return;
  }
  // BUG-5591: one geometry step each way, straight to the final rectangle,
  // with no DWM animation. See fullscreen_geometry.h.
  const ScopedNoDwmTransitions no_transitions(hwnd);
  fullscreen_transition_ = true;
  if (fullscreen) {
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(MONITORINFO);
    if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      fullscreen_transition_ = false;
      return;
    }
    placement_before_fullscreen_.length = sizeof(WINDOWPLACEMENT);
    if (!GetWindowPlacement(hwnd, &placement_before_fullscreen_)) {
      placement_before_fullscreen_ = {};
    }
    GetWindowRect(hwnd, &rect_before_fullscreen_);
    zoomed_before_fullscreen_ = IsZoomed(hwnd) != 0;
    CaptureTransitionSnapshot();
    // Oversize by the current frame so it hangs off-screen. The frame is
    // MEASURED (window rect vs. client origin/size), not derived from the
    // style bits: window_manager's hidden-title-bar mode reshapes the client
    // area in WM_NCCALCSIZE, which AdjustWindowRectExForDpi knows nothing
    // about. Styles are deliberately untouched (see the header comment).
    // While fullscreen the client is pinned to the monitor in WM_NCCALCSIZE,
    // so a zoomed window's insets (it is un-zoomed below) still give a client
    // that covers the monitor exactly.
    RECT client_rect = GetClientArea();
    POINT client_origin{0, 0};
    ClientToScreen(hwnd, &client_origin);
    const RECT& window_rect = rect_before_fullscreen_;
    fullscreen_insets_.left = client_origin.x - window_rect.left;
    fullscreen_insets_.top = client_origin.y - window_rect.top;
    fullscreen_insets_.right = (window_rect.right - window_rect.left) -
                               (client_rect.right - client_rect.left) -
                               fullscreen_insets_.left;
    fullscreen_insets_.bottom = (window_rect.bottom - window_rect.top) -
                                (client_rect.bottom - client_rect.top) -
                                fullscreen_insets_.top;
    fullscreen_monitor_ = monitor.rcMonitor;
    const RECT target =
        fushi::FullscreenWindowRect(fullscreen_monitor_, fullscreen_insets_);
    fullscreen_ = true;
    // Before the jump, so the compositor never paints the border/rounded
    // corners over a client area that already covers the monitor (BUG-2006).
    UpdateFrameChrome();
    if (zoomed_before_fullscreen_) {
      // A zoomed window keeps its maximized rectangle against SetWindowPos
      // (measured), so un-zoom — directly onto the fullscreen rectangle, in
      // the same call. The saved placement still records SW_SHOWMAXIMIZED
      // and the original normal rectangle for the exit.
      const WINDOWPLACEMENT unzoom = fushi::FullscreenUnzoomPlacement(
          placement_before_fullscreen_, target, monitor.rcMonitor,
          monitor.rcWork);
      SetWindowPlacement(hwnd, &unzoom);
    }
    RECT landed{};
    GetWindowRect(hwnd, &landed);
    const bool on_target = EqualRect(&landed, &target) != 0;
    // Z-order always (topmost covers the taskbar); geometry only if the
    // window is not there yet (a normal window, or an appbar layout the
    // workspace conversion did not foresee).
    SetWindowPos(hwnd, HWND_TOPMOST, target.left, target.top,
                 target.right - target.left, target.bottom - target.top,
                 SWP_NOACTIVATE | (on_target ? (SWP_NOMOVE | SWP_NOSIZE) : 0));
  } else {
    CaptureTransitionSnapshot();
    fullscreen_ = false;
    const fushi::FullscreenExitStep step = fushi::PlanFullscreenExit(
        zoomed_before_fullscreen_, IsZoomed(hwnd) != 0, IsIconic(hwnd) != 0);
    if (step == fushi::FullscreenExitStep::kRestoreRect) {
      const RECT& rect = rect_before_fullscreen_;
      SetWindowPos(hwnd, HWND_NOTOPMOST, rect.left, rect.top,
                   rect.right - rect.left, rect.bottom - rect.top,
                   SWP_NOACTIVATE);
    } else {
      if (placement_before_fullscreen_.length == sizeof(WINDOWPLACEMENT)) {
        WINDOWPLACEMENT restore = placement_before_fullscreen_;
        if (IsIconic(hwnd)) {
          // Minimized while fullscreen: stay minimized, restore later to
          // what the window was before fullscreen.
          restore.showCmd = SW_SHOWMINNOACTIVE;
          if (zoomed_before_fullscreen_) {
            restore.flags |= WPF_RESTORETOMAXIMIZED;
          }
          SetWindowPlacement(hwnd, &restore);
        } else if (restore.showCmd == SW_SHOWMAXIMIZED) {
          // Maximized before fullscreen. SetWindowPlacement would first move
          // the window to rcNormalPosition and only then maximize — the
          // small window in the middle of the screen (measured). Maximize
          // straight from the fullscreen rectangle instead (a no-op if the
          // user re-maximized meanwhile), then hand the saved placement to
          // the now-zoomed window: for a zoomed window that only records the
          // normal rectangle for a later restore, geometry stays put.
          ShowWindow(hwnd, SW_MAXIMIZE);
          SetWindowPlacement(hwnd, &restore);
        } else {
          // Normal before, maximized by the user / shell while fullscreen.
          SetWindowPlacement(hwnd, &restore);
        }
      }
      SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    // After the geometry is back, so the policy is evaluated against the
    // restored window instead of the still-oversized one (a window that was
    // already screen-sized before fullscreen keeps the chrome suppressed).
    UpdateFrameChrome();
  }
  // What is under the view after the jump. An opaque surface keeps the
  // snapshot pixels (BUG-1933 behaviour): the view covers them, and a late
  // first frame at the new size then still shows the previous content.
  // A see-through (Mica) surface must get its transparent backdrop back —
  // a leftover opaque snapshot would show through translucent Flutter pixels
  // (the home shell) — but not before the view has rasterized a frame at the
  // new client size (OnChildFrameRasterized): clearing on return from the
  // child resize left the bare material on screen for 2 frames (measured).
  const RECT client = GetClientArea();
  snapshot_release_size_ = SIZE{client.right - client.left,
                                client.bottom - client.top};
  const bool same_size =
      snapshot_release_size_.cx == transition_snapshot_size_.cx &&
      snapshot_release_size_.cy == transition_snapshot_size_.cy;
  if (!fushi::MainSurfaceSeeThrough(main_surface_state())) {
    ReleaseTransitionSnapshot();
  } else if (same_size) {
    // No new frame size will be reported, and nothing was exposed.
    ReleaseTransitionSnapshot();
    FillSurfaceBackdrop();
  }
  fullscreen_transition_ = false;
}

bool Win32Window::ApplyFullscreenMinMaxInfo(MINMAXINFO* info) const {
  if (!fullscreen_ || info == nullptr) {
    return false;
  }
  // Fullscreen deliberately sizes the window LARGER than the monitor (frame
  // off-screen). The default ptMaxTrackSize (SM_C*MAXTRACK) silently clamps
  // that and leaves a strip of desktop/taskbar exposed at the bottom
  // (BUG-1933). Generous fixed headroom over any real monitor.
  info->ptMaxTrackSize.x = GetSystemMetrics(SM_CXVIRTUALSCREEN) + 256;
  info->ptMaxTrackSize.y = GetSystemMetrics(SM_CYVIRTUALSCREEN) + 256;
  return true;
}

void Win32Window::CaptureTransitionSnapshot() {
  ReleaseTransitionSnapshot();
  if (window_handle_ == nullptr) {
    return;
  }
  RECT client = GetClientArea();
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) {
    return;
  }
  POINT origin{0, 0};
  ClientToScreen(window_handle_, &origin);
  // Screen capture (not PrintWindow): the Flutter view presents via a flip
  // swapchain that GDI cannot read from the window itself, but what is on
  // screen is exactly the frame worth preserving. An occluded/off-screen
  // window (test-hidden mode) fails or grabs stale pixels; both degrade to
  // the brush fill / an invisible window, never a crash.
  HDC screen = GetDC(nullptr);
  if (screen == nullptr) {
    return;
  }
  // A 32 bpp top-down DIB so the alpha byte can be set: FillSurfaceBackdrop
  // AlphaBlends the snapshot, and on a see-through (Mica) surface only alpha
  // 255 is opaque (BUG-5591; a screen BitBlt leaves the alpha byte 0).
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP bitmap =
      CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (mem != nullptr && bitmap != nullptr && bits != nullptr) {
    HGDIOBJ old = SelectObject(mem, bitmap);
    const bool copied = BitBlt(mem, 0, 0, width, height, screen, origin.x,
                               origin.y, SRCCOPY) != 0;
    SelectObject(mem, old);
    if (copied) {
      GdiFlush();
      auto* pixel = static_cast<uint32_t*>(bits);
      const size_t count =
          static_cast<size_t>(width) * static_cast<size_t>(height);
      for (size_t i = 0; i < count; ++i) {
        pixel[i] |= 0xFF000000u;
      }
      transition_snapshot_ = bitmap;
      transition_snapshot_size_ = {width, height};
      bitmap = nullptr;
    }
  }
  if (bitmap != nullptr) {
    DeleteObject(bitmap);
  }
  if (mem != nullptr) {
    DeleteDC(mem);
  }
  ReleaseDC(nullptr, screen);
}

void Win32Window::ReleaseTransitionSnapshot() {
  if (transition_snapshot_ != nullptr) {
    DeleteObject(transition_snapshot_);
    transition_snapshot_ = nullptr;
    transition_snapshot_size_ = {};
  }
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::OnDisplayRecovered() {
  // No-op; provided for subclasses that host a renderer (TODO-689).
}
