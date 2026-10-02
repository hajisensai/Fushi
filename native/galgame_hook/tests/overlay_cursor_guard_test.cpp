// ShouldWithholdGameCursor 的真 Win32 窗口测试（BUG-2864）。
//
// 判据里的「窗口归哪个线程」「类名是什么」只有系统自己能作证，所以这里真建窗口：
// 游戏线程 = 本测试主线程；Fushi 浮层 = 另一条线程建的窗口（runner 查词卡在 fushi.exe 里、
// 注入侧位图卡在游戏进程的独立 UI 线程上，两者对游戏线程而言都是「别的线程」）。窗口全部
// 放到屏幕外、不显示，跑测试时不在开发机桌面上闪窗、不抢焦点。
// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 本文件用 Expect() 计数而不是 assert，但守卫要求这条不变式对所有原生测试一致成立，
// 免得后来者往里加 assert 时静默失效。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include "overlay_cursor_guard.h"

#include <cstdio>

namespace {

const wchar_t* const kFushiOverlayClass = L"FushiOverlayCursorGuardTestCard";
const wchar_t* const kForeignOverlayClass = L"ThirdPartyCursorGuardTestOverlay";
int g_failures = 0;

void Expect(bool condition, const char* what) {
  if (condition) return;
  ++g_failures;
  std::fprintf(stderr, "FAIL: %s\n", what);
}

void RegisterTestClass(const wchar_t* name) {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = &DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = name;
  RegisterClassW(&wc);
}

HWND CreateHiddenPopup(const wchar_t* class_name) {
  return CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, class_name, L"",
                         WS_POPUP, -32000, -32000, 64, 64, nullptr, nullptr,
                         GetModuleHandleW(nullptr), nullptr);
}

// 另一条线程建的窗口；窗口随建它的线程一起销毁，所以线程要活到判定结束。
struct OverlayThread {
  HANDLE created = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE thread = nullptr;
  DWORD thread_id = 0;
  HWND fushi = nullptr;
  HWND foreign = nullptr;

  static DWORD WINAPI Run(LPVOID param) {
    auto* self = static_cast<OverlayThread*>(param);
    self->fushi = CreateHiddenPopup(kFushiOverlayClass);
    self->foreign = CreateHiddenPopup(kForeignOverlayClass);
    SetEvent(self->created);
    WaitForSingleObject(self->release, INFINITE);
    DestroyWindow(self->fushi);
    DestroyWindow(self->foreign);
    return 0;
  }

  void Start() {
    thread = CreateThread(nullptr, 0, &Run, this, 0, &thread_id);
    WaitForSingleObject(created, INFINITE);
  }

  void Stop() {
    SetEvent(release);
    WaitForSingleObject(thread, INFINITE);
    CloseHandle(thread);
    CloseHandle(created);
    CloseHandle(release);
  }
};

void TestClassPrefix() {
  using fushi_voice_hook::IsFushiOverlayWindowClass;
  Expect(IsFushiOverlayWindowClass(L"FushiGlobalLookupWindow"),
         "runner lookup card class is a Fushi overlay");
  Expect(IsFushiOverlayWindowClass(L"FushiAttachedTextSurfaceWindow"),
         "attached text surface class is a Fushi overlay");
  Expect(IsFushiOverlayWindowClass(L"FushiLookupOverlay"),
         "injected bitmap card class is a Fushi overlay");
  Expect(!IsFushiOverlayWindowClass(L"SiglusEngine"),
         "game window class is not a Fushi overlay");
  Expect(!IsFushiOverlayWindowClass(L"Fush"), "truncated prefix is rejected");
  Expect(!IsFushiOverlayWindowClass(L"fushiLowercase"),
         "prefix match is case-sensitive like the registered classes");
  Expect(!IsFushiOverlayWindowClass(L""), "empty class is rejected");
  Expect(!IsFushiOverlayWindowClass(nullptr), "null class is rejected");
}

void TestWithholdDecision() {
  using fushi_voice_hook::ShouldWithholdGameCursor;
  const DWORD game_thread = GetCurrentThreadId();
  OverlayThread overlay;
  overlay.Start();
  Expect(overlay.fushi != nullptr && overlay.foreign != nullptr,
         "overlay thread created its windows");

  // 根因场景：光标压在别的线程的 Fushi 浮层上，游戏线程每帧 SetCursor。
  Expect(ShouldWithholdGameCursor(overlay.fushi, game_thread),
         "game cursor is withheld over a foreign-thread Fushi overlay");
  // 第三方覆盖窗口不归本 DLL 管。
  Expect(!ShouldWithholdGameCursor(overlay.foreign, game_thread),
         "non-Fushi foreign windows are left alone");
  // 浮层线程自己设光标（它的 WM_SETCURSOR）永远放行。
  Expect(!ShouldWithholdGameCursor(overlay.fushi, overlay.thread_id),
         "the overlay's own thread may always set its cursor");

  // 同线程的 Fushi 类窗口（游戏线程自己的窗口）照常放行。
  const HWND same_thread_fushi = CreateHiddenPopup(kFushiOverlayClass);
  Expect(same_thread_fushi != nullptr, "same-thread window created");
  Expect(!ShouldWithholdGameCursor(same_thread_fushi, game_thread),
         "a window owned by the calling thread never withholds its cursor");

  // 游戏线程自己持有捕获（拖拽中）：鼠标归属窗就是捕获窗，光标归游戏。
  SetCapture(same_thread_fushi);
  Expect(fushi_voice_hook::MouseOwningRootWindow() == same_thread_fushi,
         "the caller's capture window owns the mouse");
  Expect(!fushi_voice_hook::ShouldWithholdGameCursorNow(),
         "the game keeps its cursor while it holds the capture");
  ReleaseCapture();
  DestroyWindow(same_thread_fushi);

  Expect(!ShouldWithholdGameCursor(nullptr, game_thread),
         "no window under the cursor never withholds");

  const HWND stale = overlay.fushi;
  overlay.Stop();
  // 浮层已销毁（Fushi 退出 / 卡片关掉）：失败放行，游戏光标立刻恢复。
  Expect(!ShouldWithholdGameCursor(stale, game_thread),
         "a destroyed overlay fails open");
}

}  // namespace

int main() {
  RegisterTestClass(kFushiOverlayClass);
  RegisterTestClass(kForeignOverlayClass);
  TestClassPrefix();
  TestWithholdDecision();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  std::printf("overlay_cursor_guard_test: OK\n");
  return 0;
}
