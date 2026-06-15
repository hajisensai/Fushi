#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "crash_dump.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Inno Setup 静默更新靠这个命名互斥量检测并关闭运行中的实例（见 hibiki.iss AppMutex）。
  ::CreateMutexW(nullptr, FALSE, L"HibikiSingleInstanceMutex");

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
