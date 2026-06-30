#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>

#include <string>

#include "crash_dump.h"
#include "external_video_handoff.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// 从本进程 argv 里挑出第一个「文件」参数（跳过以 `-` 开头的 flag / 调试器注入参数）。
// 这是「用 Hibiki 打开视频」时资源管理器 / 命令行传进来的 `"%1"`。只做字符串级判定，
// 真正的视频扩展名白名单 + 存在性校验仍由首实例 Dart 侧（firstExternalVideoArg +
// File.existsSync）负责——这里转交的是「候选路径」，首实例自行决定是否打开。
std::wstring FirstFileArgFromCommandLine() {
  int argc = 0;
  wchar_t **argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::wstring();
  }
  std::wstring file_arg;
  // 跳过 argv[0]（binary 名）。
  for (int i = 1; i < argc; ++i) {
    if (argv[i] == nullptr || argv[i][0] == 0) {
      continue;
    }
    if (argv[i][0] == L'-') {
      continue;  // flag（如调试器注入），不是文件路径。
    }
    file_arg = argv[i];
    break;
  }
  ::LocalFree(argv);
  return file_arg;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Inno Setup 静默更新靠这个命名互斥量检测并关闭运行中的实例（见 hibiki.iss AppMutex）。
  // TODO-904 / BUG-437: 真单实例守卫。第二个 hibiki.exe 与首实例共享同一 WebView2
  // 默认 userDataFolder（基于 exe 名），而 WebView2 契约不允许多进程并发同一
  // userDataFolder → 第二实例 env 创建锁冲突失败 → `Cannot create the InAppWebView
  // instance!`。原本只 CreateMutexW 不查 ERROR_ALREADY_EXISTS = 没有真单实例。
  // 此处检测已有实例则把首实例窗口前置并退出本进程，消除双实例锁冲突放大器。
  // 离屏集成测试模式（HIBIKI_TEST_HIDDEN）完全不参与单实例互斥量：测试 runner 用隔离的
  // WebView2 userDataFolder（HIBIKI_WEBVIEW2_USER_DATA_FOLDER），与用户在用的 Hibiki 不
  // 抢同一 userDataFolder，无 WebView2 锁冲突。若仍走单实例守卫，测试 exe 会在用户开着
  // Hibiki 时检测到首实例后立即 return EXIT_SUCCESS 退出 → `flutter test -d windows` 报
  // 「log reader stopped/never started / Unable to start the app」（启动间歇失败的真因）。
  // 跳过后测试实例与用户实例并存、互不干扰，也不持有互斥量去挡用户启动自己的 Hibiki。
  const bool test_hidden_mode =
      ::GetEnvironmentVariableW(L"HIBIKI_TEST_HIDDEN", nullptr, 0) > 0;
  ::SetLastError(ERROR_SUCCESS);
  HANDLE single_instance_mutex =
      test_hidden_mode
          ? nullptr
          : ::CreateMutexW(nullptr, FALSE, L"HibikiSingleInstanceMutex");
  if (!test_hidden_mode && single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // 已有实例在跑：找到首实例主窗口。
    HWND existing = ::FindWindowW(nullptr, L"Hibiki");
    if (existing != nullptr) {
      // TODO-904 P0 回归修复：本次启动若带视频文件参数（文件关联 / 拖到 exe /
      // CLI `hibiki.exe "%1"`），必须把路径**转交**首实例，否则第二实例只前置窗口
      // 就退出 → 视频路径整个丢掉、首实例从不知情 →「点了没反应」。用 WM_COPYDATA
      // 把 UTF-8 路径字节跨进程发给首实例的窗口过程（见 flutter_window.cpp 的
      // WM_COPYDATA 处理 → app.hibiki/external_video MethodChannel →
      // _openExternalVideo）。无文件参数（纯第二次启动）则只前置 + 退出。
      const std::wstring file_arg = FirstFileArgFromCommandLine();
      if (!file_arg.empty()) {
        ::hibiki::SendExternalVideoPath(existing, file_arg);
      }
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
