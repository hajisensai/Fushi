#include "win32_window.h"

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

// True when HIBIKI_TEST_HIDDEN is set (to anything non-empty). In that mode the
// runner creates its window off-screen and non-activating so automated
// integration tests can drive the real desktop app — focus moves, settings
// changes, WebView DOM probes — without it appearing on screen or stealing
// keyboard/foreground focus from whatever the user is doing. GetEnvironmentVariable
// with a null buffer returns the required size (>0) when the variable exists.
bool IsTestHiddenMode() {
  return GetEnvironmentVariableW(L"HIBIKI_TEST_HIDDEN", nullptr, 0) > 0;
}

// True when HIBIKI_TEST_ONSCREEN is set (to anything non-empty). Only meaningful
// together with test-hidden mode: the window keeps WS_EX_NOACTIVATE (it still
// never steals the user's foreground/keyboard focus) but is placed at a real
// on-screen origin instead of off-screen, so DWM composes it for Windows
// Graphics Capture / OS screen-grab screenshots. Lets a non-blocking visible
// capture exist without hijacking what the user is doing.
bool IsTestOnscreenMode() {
  return GetEnvironmentVariableW(L"HIBIKI_TEST_ONSCREEN", nullptr, 0) > 0;
}

// TODO-959: 数据迁移成功后的自动重启（DesktopLifecycleService.restartApp）会以
// detached 模式拉起带这个标志的新进程。必须与 main.cpp 的 kRestartMarkerArg 和
// Dart 侧 DesktopLifecycleService.restartMarkerArg 逐字符一致。见到它说明本次启动
// 是「旧进程刚迁完数据、主动拉起的新进程」，而非用户二次点击图标。
constexpr const wchar_t kRestartMarkerArg[] = L"--hibiki-restarted";

// TODO-959: splash 背景画刷色。旧进程 exit(0) 杀掉自己到新进程 Flutter 画出首帧
// 之间，runner 窗口已 WS_VISIBLE 上屏但还没有任何内容；窗口类原本 hbrBackground=0
// （无背景画刷）→ 系统不擦背景 → 这段冷启动窗口里看到黑/未定义像素（经典 Flutter
// Windows runner 首帧黑窗）。给窗口类一个非黑的 solid brush，让 WM_ERASEBKGND 用它
// 填充，首帧前就是这块纯色而非黑。颜色取 Dart splash 的品牌 seed 色 0xFF1F4959
// （main.dart 的 ColorScheme.fromSeed seedColor / 加载页 _savedSplashColor 兜底同色系深青），
// 与启动画面观感一致，深色优先（不刺眼、不闪白）。COLORREF 是 0x00BBGGRR，
// 故 R=0x1F G=0x49 B=0x59。
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
    // TODO-959: 给窗口类一个非黑背景画刷（原为 0 = 无画刷），消除迁移重启
    // 新进程冷启动期「窗已上屏但 Flutter 首帧未出」的黑窗。系统用它响应
    // WM_ERASEBKGND 填充客户区。画刷由窗口类持有，生存期到 UnregisterWindowClass，
    // RegisterClass 成功后由系统管理，无需手动 DeleteObject。
    window_class.hbrBackground = CreateSolidBrush(kSplashBackgroundColor);
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

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
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
  // 的错误窗。普通启动（无 --hibiki-restarted）仍带 WS_VISIBLE、立即上屏，
  // 靠上面的背景画刷兜底首帧前不黑，不会永久不显窗。测试隐藏模式
  // （hidden）不受影响：它靠 WS_VISIBLE+移出屏外保证引擎持续渲染，不能去掉
  // WS_VISIBLE。只有「非测试 + 重启新进程」走隐藏建窗。
  const bool restarted_hidden = !hidden && IsRestartedProcess();
  const DWORD window_style = restarted_hidden
                                 ? WS_OVERLAPPEDWINDOW
                                 : (WS_OVERLAPPEDWINDOW | WS_VISIBLE);

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

  return OnCreate();
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
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

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
