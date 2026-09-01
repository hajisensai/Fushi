#include "win32_window.h"

#include "window_activation_policy.h"

#include <dwmapi.h>
#include <flutter_windows.h>

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

// TODO-959: 数据迁移成功后的自动重启（DesktopLifecycleService.restartApp）会以
// detached 模式拉起带这个标志的新进程。必须与 main.cpp 的 kRestartMarkerArg 和
// Dart 侧 DesktopLifecycleService.restartMarkerArg 逐字符一致。见到它说明本次启动
// 是「旧进程刚迁完数据、主动拉起的新进程」，而非用户二次点击图标。
constexpr const wchar_t kRestartMarkerArg[] = L"--fushi-restarted";

// TODO-959: splash 背景色。旧进程 exit(0) 杀掉自己到新进程 Flutter 画出首帧
// 之间，runner 窗口已 WS_VISIBLE 上屏但还没有任何内容；stock 模板 hbrBackground=0
// （无背景画刷）→ 系统不擦背景 → 这段冷启动窗口里看到黑/未定义像素（经典 Flutter
// Windows runner 首帧黑窗）。用这块非黑纯色擦背景，首帧前就是它而非黑。颜色取
// Dart splash 的品牌 seed 色 0xFF1F4959（main.dart 的 ColorScheme.fromSeed
// seedColor / 加载页 _savedSplashColor 兜底同色系深青），与启动画面观感一致，
// 深色优先（不刺眼、不闪白）。COLORREF 是 0x00BBGGRR，故 R=0x1F G=0x49 B=0x59。
//
// BUG-1916: 这块颜色只是 Win32Window::backdrop_brush_ 的**初始值**，不再挂在窗口
// 类上。Flutter 子窗是 DWM 里独立的合成层，盖在本窗口自己的重定向表面之上；表面
// 里是什么颜色平时看不见，但最大化 / 还原 / DPI 切换这类过渡里 DWM 动画的是
// 「表面」而不是子窗层，表面就会露出来一帧。原实现把画刷挂在 WNDCLASS.hbrBackground
// 且父窗没有 WS_CLIPCHILDREN：每次缩放系统都把整块表面（含子窗底下）擦成深青，
// 第一次最大化实测整窗 100% 深青一帧——用户说的「缩放有层底色」。现在画刷归窗口
// 实例所有，Dart 每次主题变化把 surface 色推过来（FlutterWindow::ApplyCaptionColors
// → SetBackdropColor），并在换色和 WM_SIZE 时把表面整块（含子窗底下）刷成该色，
// 过渡帧露出的就是 app 自己的背景色（实测 0%）；冷启动首帧前仍是这块 splash 色
// （TODO-959 不变）。交互缩放本身的节奏（每步 2~3 vsync）是引擎同步缩放的固有成本，
// hello-world 同样如此，与本修复无关。
constexpr COLORREF kSplashBackgroundColor = RGB(0x1F, 0x49, 0x59);

// TODO-959: 本进程 argv 是否带 [kRestartMarkerArg]（迁移后自动重启拉起的新进程）。
// 与 main.cpp 的 HasRestartMarker 同义，在 runner 窗口层独立判定，避免给
// CreateAndShow 增加参数破坏其它平台/调用方的签名（向后兼容）。
bool IsRestartedProcess() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  bool found = false;
  for (int i = 1; i < argc; ++i) {
    if (argv[i] != nullptr && ::wcscmp(argv[i], kRestartMarkerArg) == 0) {
      found = true;
      break;
    }
  }
  ::LocalFree(argv);
  return found;
}

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
    : backdrop_brush_(CreateSolidBrush(kSplashBackgroundColor)) {
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

  // TODO-959 (方向 2)：迁移重启拉起的新进程先以隐藏状态建窗（不带
  // WS_VISIBLE），等 Dart 首帧后由 main.dart 重启分支 windowManager.show()+focus()
  // 再显示。这样旧进程 exit(0) 到新进程首帧的交接期不会出现空白/黑色
  // 的错误窗。普通启动（无 --fushi-restarted）仍带 WS_VISIBLE、立即上屏，
  // 靠上面的背景画刷兜底首帧前不黑，不会永久不显窗。测试隐藏模式
  // （hidden）不受影响：它靠 WS_VISIBLE+移出屏外保证引擎持续渲染，不能去掉
  // WS_VISIBLE。只有「非测试 + 重启新进程」走隐藏建窗。
  const bool restarted_hidden = !hidden && IsRestartedProcess();
  // BUG-1916: WS_CLIPCHILDREN — the Flutter view is a child HWND that covers
  // the whole client area; WM_PAINT erases (BeginPaint) must not touch the
  // pixels under it (that matters if the engine ever falls back to software
  // rendering, where the view paints into this same surface). The deliberate
  // under-the-view fills go through FillSurfaceBackdrop instead.
  const DWORD window_style =
      WS_CLIPCHILDREN |
      (restarted_hidden ? WS_OVERLAPPEDWINDOW
                        : (WS_OVERLAPPEDWINDOW | WS_VISIBLE));

  HWND window = CreateWindowEx(
      ex_style, window_class, title.c_str(), window_style,
      window_x, window_y, Scale(size.width, scale_factor),
      Scale(size.height, scale_factor), nullptr, nullptr,
      GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  // Ask the OS to deliver WM_POWERBROADCAST when a monitor powers on so the
  // window can repaint after the display returns (TODO-689). Registered after
  // the window exists (window_handle_ is set in WM_NCCREATE). The handle is
  // released in Destroy() to avoid a leak.
  power_notify_ = RegisterPowerSettingNotification(
      window_handle_, &GUID_MONITOR_POWER_ON, DEVICE_NOTIFY_WINDOW_HANDLE);

  ApplyTestTopmostPlacement(window);

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
  if (!IsTestHiddenMode()) {
    return;
  }
  wchar_t spec[64] = {0};
  if (GetEnvironmentVariableW(L"FUSHI_TEST_TOPMOST", spec, 64) == 0) {
    return;
  }
  int x = 0, y = 0, w = 0, h = 0;
  if (swscanf_s(spec, L"%d,%d,%d,%d", &x, &y, &w, &h) != 4 || w <= 0 ||
      h <= 0) {
    return;
  }
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
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
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
      RECT rect = GetClientArea();
      // BUG-1916: the surface just changed size; its new area is uninitialised
      // (black) and its old area may carry an older fill. Paint it whole,
      // under the view too, before the view is resized — MoveWindow below
      // blocks until the engine presents a frame of the new size. On the
      // hardware path the view is its own composition layer, so this fill is
      // never visible through it; if the engine has fallen back to software
      // rendering (view paints into this same surface) the worst case is one
      // theme-coloured frame under the view — still better than the old
      // teal erase on every WM_PAINT.
      FillSurfaceBackdrop();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ERASEBKGND:
      // BUG-1916 / TODO-959: erase with the instance backdrop brush (splash
      // colour before the first Flutter frame, live theme surface afterwards).
      // Child-clipped, so once the view covers the client this paints nothing.
      //
      // This supersedes the earlier `if (child_content_) return TRUE; break;`
      // guard, which existed only to stop DefWindowProc from erasing the parent
      // with the *class* brush and flashing a #1F4959 rectangle over the child
      // during live resize. The class brush is gone now (hbrBackground =
      // nullptr), so that `break` would fall through to a DefWindowProc with no
      // brush at all — painting nothing, and bringing the TODO-959 cold-start
      // black window straight back. The wparam DC honours WS_CLIPCHILDREN, so
      // "don't cover the child" is now structural rather than a special case:
      // there is no child yet at cold start (splash fill lands), and once the
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
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
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
  // Without this the surface keeps the cold-start splash fill under the view
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
  bool painted = false;
  if (transition_snapshot_ != nullptr) {
    RECT rect = GetClientArea();
    HDC mem = CreateCompatibleDC(dc);
    if (mem != nullptr) {
      HGDIOBJ old = SelectObject(mem, transition_snapshot_);
      SetStretchBltMode(dc, COLORONCOLOR);
      painted = StretchBlt(dc, 0, 0, rect.right - rect.left,
                           rect.bottom - rect.top, mem, 0, 0,
                           transition_snapshot_size_.cx,
                           transition_snapshot_size_.cy, SRCCOPY) != 0;
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
  FillRect(dc, &rect, backdrop_brush_);
}

namespace {

// BUG-2006: true when the window's client area covers its monitor edge to
// edge. window_manager's hidden-title-bar WM_NCCALCSIZE gives this window a
// client area that reaches the frame, so a screen-covering window puts app
// content under every pixel of DWM-painted chrome — measured on Windows 11
// 26200: a normal (SW_SHOWNORMAL, not zoomed) Hibiki window sized to the
// monitor has 3830/3840 pixels of screen row 0 painted in the accent colour,
// and the desktop showing through all four rounded corners.
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

void Win32Window::SetFullscreen(bool fullscreen) {
  HWND hwnd = window_handle_;
  if (hwnd == nullptr || fullscreen == fullscreen_) {
    return;
  }
  if (fullscreen) {
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(MONITORINFO);
    if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      return;
    }
    placement_before_fullscreen_.length = sizeof(WINDOWPLACEMENT);
    if (!GetWindowPlacement(hwnd, &placement_before_fullscreen_)) {
      placement_before_fullscreen_ = {};
    }
    CaptureTransitionSnapshot();
    // A zoomed window ignores SetWindowPos sizes (the maximize geometry is
    // enforced), so leave the maximized state first — straight onto the
    // monitor rect, no intermediate small window. The saved placement above
    // still records SW_SHOWMAXIMIZED, so exiting restores the maximized state.
    if (IsZoomed(hwnd)) {
      WINDOWPLACEMENT unzoom = placement_before_fullscreen_;
      unzoom.length = sizeof(WINDOWPLACEMENT);
      unzoom.showCmd = SW_SHOWNORMAL;
      unzoom.rcNormalPosition = monitor.rcMonitor;
      SetWindowPlacement(hwnd, &unzoom);
    }
    // Oversize by exactly the current frame so the CLIENT area covers the
    // monitor and the frame hangs off-screen. The frame is MEASURED (window
    // rect vs. client origin/size), not derived from the style bits:
    // window_manager's hidden-title-bar mode reshapes the client area in
    // WM_NCCALCSIZE (top border 0, sides/bottom trimmed), which
    // AdjustWindowRectExForDpi knows nothing about. Styles are deliberately
    // untouched (see the header comment).
    RECT window_rect{};
    GetWindowRect(hwnd, &window_rect);
    RECT client_rect = GetClientArea();
    POINT client_origin{0, 0};
    ClientToScreen(hwnd, &client_origin);
    const int border_left = client_origin.x - window_rect.left;
    const int border_top = client_origin.y - window_rect.top;
    const int border_right = (window_rect.right - window_rect.left) -
                             (client_rect.right - client_rect.left) -
                             border_left;
    const int border_bottom = (window_rect.bottom - window_rect.top) -
                              (client_rect.bottom - client_rect.top) -
                              border_top;
    fullscreen_ = true;
    // Before the jump, so the compositor never paints the border/rounded
    // corners over a client area that already covers the monitor (BUG-2006).
    UpdateFrameChrome();
    SetWindowPos(hwnd, HWND_TOPMOST, monitor.rcMonitor.left - border_left,
                 monitor.rcMonitor.top - border_top,
                 (monitor.rcMonitor.right - monitor.rcMonitor.left) +
                     border_left + border_right,
                 (monitor.rcMonitor.bottom - monitor.rcMonitor.top) +
                     border_top + border_bottom,
                 SWP_NOACTIVATE);
    ReleaseTransitionSnapshot();
  } else {
    CaptureTransitionSnapshot();
    fullscreen_ = false;
    if (placement_before_fullscreen_.length == sizeof(WINDOWPLACEMENT)) {
      const bool was_maximized =
          placement_before_fullscreen_.showCmd == SW_SHOWMAXIMIZED;
      WINDOWPLACEMENT restore = placement_before_fullscreen_;
      if (was_maximized) {
        // The zoomed flag survives the fullscreen SetWindowPos, so restoring a
        // SW_SHOWMAXIMIZED placement onto an already-"maximized" window is a
        // geometry no-op (the window would stay at the oversized fullscreen
        // rect). Drop to the normal placement first, then re-maximize.
        restore.showCmd = SW_SHOWNORMAL;
      }
      SetWindowPlacement(hwnd, &restore);
      if (was_maximized) {
        ShowWindow(hwnd, SW_MAXIMIZE);
      }
    }
    SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    // After the geometry is back, so the policy is evaluated against the
    // restored window instead of the still-oversized one (a window that was
    // already screen-sized before fullscreen keeps the chrome suppressed).
    UpdateFrameChrome();
    ReleaseTransitionSnapshot();
  }
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
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateCompatibleBitmap(screen, width, height);
  if (mem != nullptr && bitmap != nullptr) {
    HGDIOBJ old = SelectObject(mem, bitmap);
    const bool copied = BitBlt(mem, 0, 0, width, height, screen, origin.x,
                               origin.y, SRCCOPY) != 0;
    SelectObject(mem, old);
    if (copied) {
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
