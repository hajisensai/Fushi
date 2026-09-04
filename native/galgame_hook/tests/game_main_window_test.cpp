// FindGameMainWindow 的真 Win32 窗口测试（BUG-2121）。
//
// 用本进程真建窗口而不是伪造 EnumWindows：判据里三个 Win32 事实——IsWindowVisible 只看
// WS_VISIBLE、GW_OWNER 取的是 CreateWindowEx 的 hWndParent（对 WS_POPUP 即 owner）、
// 隐藏 owner 不影响 owned 窗口的可见性——都只有系统自己能作证。窗口全部放到屏幕外并以
// WS_EX_NOACTIVATE / SW_SHOWNOACTIVATE 显示，跑测试时不会在开发机桌面上闪窗、不抢焦点。
#include "game_main_window.h"

#include <cstdio>
#include <vector>

namespace {

const wchar_t* const kClassName = L"FushiGameMainWindowTestWindow";
int g_failures = 0;

void Expect(bool condition, const char* what) {
  if (condition) return;
  ++g_failures;
  std::fprintf(stderr, "FAIL: %s\n", what);
}

void RegisterTestClass() {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = &DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kClassName;
  RegisterClassW(&wc);
}

struct Windows {
  std::vector<HWND> handles;
  // 屏幕外 WS_POPUP 窗口。visible=false 只创建不显示（WS_VISIBLE 不置）。
  HWND Create(HWND owner, int width, int height, bool visible) {
    const HWND hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName, L"", WS_POPUP,
        -20000, -20000, width, height, owner, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    handles.push_back(hwnd);
    if (hwnd != nullptr && visible) ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    return hwnd;
  }
  ~Windows() {
    for (auto it = handles.rbegin(); it != handles.rend(); ++it) {
      if (*it != nullptr && IsWindow(*it)) DestroyWindow(*it);
    }
  }
};

void TestNoVisibleWindowReturnsNull() {
  Windows w;
  w.Create(nullptr, 640, 480, false);
  Expect(fushi_voice_hook::FindGameMainWindow() == nullptr,
         "hidden-only process has no main window");
}

// MSVC 引擎（KiriKiri Z 等）的形状：主窗无 owner；对话框被主窗 own。
void TestUnownedMainBeatsOwnedDialogAndSmallerTools() {
  Windows w;
  const HWND tool = w.Create(nullptr, 200, 100, true);
  const HWND main = w.Create(nullptr, 640, 480, true);
  const HWND dialog = w.Create(main, 900, 700, true);  // 比主窗还大，但被可见主窗 own
  Expect(tool != nullptr && main != nullptr && dialog != nullptr, "windows created");
  Expect(fushi_voice_hook::FindGameMainWindow() == main,
         "unowned largest visible window wins; visible-owned dialog excluded");
}

// Borland VCL（KiriKiri2 2.x/BCB）的形状：TApplication 窗永远隐藏，每个 TForm 都被它 own。
void TestFormOwnedByHiddenOwnerIsMainWindow() {
  Windows w;
  const HWND app = w.Create(nullptr, 0, 0, false);  // TApplication：隐藏、0x0
  const HWND form = w.Create(app, 800, 600, true);   // TTVPWindowForm
  const HWND dialog = w.Create(form, 300, 200, true);  // form 的对话框
  Expect(app != nullptr && form != nullptr && dialog != nullptr, "vcl windows created");
  Expect(GetWindow(form, GW_OWNER) == app, "form is owned by hidden app window");
  Expect(fushi_voice_hook::FindGameMainWindow() == form,
         "form owned by a hidden owner is the main window (BUG-2121)");
}

// owner 隐藏但窗体本身也隐藏：照旧不入选（不能因为放宽 owner 就把隐藏窗放进来）。
void TestHiddenFormUnderHiddenOwnerStaysExcluded() {
  Windows w;
  const HWND app = w.Create(nullptr, 0, 0, false);
  w.Create(app, 800, 600, false);
  const HWND visible = w.Create(nullptr, 100, 100, true);
  Expect(fushi_voice_hook::FindGameMainWindow() == visible,
         "hidden form is excluded even though its owner is hidden");
}

// 别的进程的窗口不算：按 pid 过滤。用一个不存在的 pid 证明过滤真在起作用。
void TestForeignPidSeesNothing() {
  Windows w;
  w.Create(nullptr, 640, 480, true);
  Expect(fushi_voice_hook::FindGameMainWindowOfProcess(0xFFFFFFFEu) == nullptr,
         "foreign pid finds nothing");
}

}  // namespace

int main() {
  RegisterTestClass();
  TestNoVisibleWindowReturnsNull();
  TestUnownedMainBeatsOwnedDialogAndSmallerTools();
  TestFormOwnedByHiddenOwnerIsMainWindow();
  TestHiddenFormUnderHiddenOwnerStaysExcluded();
  TestForeignPidSeesNothing();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  std::printf("game_main_window_test: ok\n");
  return 0;
}
