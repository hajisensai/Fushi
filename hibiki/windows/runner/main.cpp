#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "crash_dump.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Inno Setup 静默更新靠这个命名互斥量检测并关闭运行中的实例（见 hibiki.iss AppMutex）。
  // TODO-904 / BUG-437: 真单实例守卫。第二个 hibiki.exe 与首实例共享同一 WebView2
  // 默认 userDataFolder（基于 exe 名），而 WebView2 契约不允许多进程并发同一
  // userDataFolder → 第二实例 env 创建锁冲突失败 → `Cannot create the InAppWebView
  // instance!`。原本只 CreateMutexW 不查 ERROR_ALREADY_EXISTS = 没有真单实例。
  // 此处检测已有实例则把首实例窗口前置并退出本进程，消除双实例锁冲突放大器。
  ::SetLastError(ERROR_SUCCESS);
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, FALSE, L"HibikiSingleInstanceMutex");
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // 已有实例在跑：尽力把首实例主窗口前置，再退出本进程。
    HWND existing = ::FindWindowW(nullptr, L"Hibiki");
    if (existing != nullptr) {
      if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
    }
    ::ReleaseMutex(single_instance_mutex);
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  // BUG-209 / TODO-398：在 Flutter engine / COM 初始化之前安装进程级 minidump
  // 写出（写进 %LOCALAPPDATA%\Hibiki\crashdumps\，链回引擎既有 filter），让
  // GraphicsCapture 延迟 UAF 崩溃必留可被 cdb 分析的 dump，不再赌系统 WER。
  ::hibiki::InstallCrashDumpHandler();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.CreateAndShow(L"Hibiki", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
