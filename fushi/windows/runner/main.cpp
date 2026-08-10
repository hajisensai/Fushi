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
// 这是「用 Fushi 打开视频」时资源管理器 / 命令行传进来的 `"%1"`。只做字符串级判定，
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

// TODO-935 BUG: 数据迁移成功后的自动重启（DesktopLifecycleService.restartApp）
// 带的重启标志。必须与 Dart 侧 DesktopLifecycleService.restartMarkerArg 逐字符一致。
// 见到它说明本次启动是「旧进程刚迁完数据、主动拉起的新进程」，而非用户二次点击图标。
constexpr wchar_t kRestartMarkerArg[] = L"--fushi-restarted";

// 本进程 argv 是否带 [kRestartMarkerArg]（自动重启拉起的新进程）。
bool HasRestartMarker() {
  int argc = 0;
  wchar_t **argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
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

// 等待旧实例释放单实例互斥量（[mutex] 由 CreateMutexW 返回、本进程未持有所有权）。
// 自动重启时旧进程已开始退出序列（prepareForProcessExit + exit(0)），但「拉起新进程」
// 与「旧进程真正退出」之间有一小段并发窗口：此刻互斥量仍被旧进程持有，新进程裸调
// CreateMutexW 会拿到 ERROR_ALREADY_EXISTS 而被误判成「二次启动」直接退出，导致重启
// 落空——数据已迁移但应用从未以新数据根重新初始化（用户感知「弹了下进度就重启、位置没变」）。
// 这里用 WaitForSingleObject 阻塞到旧进程退出（其句柄关闭 → 互斥量被遗弃 → 本进程拿到
// WAIT_ABANDONED/WAIT_OBJECT_0 即取得所有权），加超时上界避免旧进程异常不退时永久卡死。
// 返回 true = 已取得所有权可继续启动；false = 超时（旧实例仍在，按二次启动语义放弃）。
bool WaitForSingleInstanceMutex(HANDLE mutex, DWORD timeout_ms) {
  if (mutex == nullptr) {
    return false;
  }
  const DWORD wait = ::WaitForSingleObject(mutex, timeout_ms);
  // WAIT_OBJECT_0：正常取得；WAIT_ABANDONED：上一持有者（旧进程）未释放就退出，所有权
  // 移交本进程——对单实例守卫语义而言同样是「旧实例已走、我接管」，可继续启动。
  return wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED;
}

// TODO-1003: 本进程是否为自动化集成测试 runner。itest harness（tool/run_windows_itest.ps1）
// 在离屏/置屏两模式下都恒设 FUSHI_TEST_HIDDEN（同 win32_window.cpp 的 IsTestHiddenMode）。
// 测试模式下**必须跳过**下面的单实例守卫：测试 runner 本就该以首实例语义启动，哪怕用户
// 自己的 Fushi 正开着；否则守卫会看到用户实例持有 FushiSingleInstanceMutex，走
// FindWindow→前置→return EXIT_SUCCESS 分支，在 Flutter engine 初始化**之前**就退出 →
// flutter_tool 永远拿不到 VM service URI（报 "log reader stopped unexpectedly"，整套
// Windows itest 无法 attach）。跳过是安全的：守卫唯一目的是防两进程共享默认 WebView2
// userDataFolder（BUG-437），而 harness 已用 FUSHI_WEBVIEW2_USER_DATA_FOLDER 把测试
// runner 的 WebView2 profile 隔离开，冲突不存在。生产侧该变量只会被下面的
// EnsureWritableWebView2UserDataFolder 按 exe 路径确定性地设置（BUG-1483），同一
// exe 的多进程仍指向同一目录，守卫职责不变。
bool IsTestRunnerMode() {
  return ::GetEnvironmentVariableW(L"FUSHI_TEST_HIDDEN", nullptr, 0) > 0;
}

// BUG-1483: [dir] 下能否创建文件（进而创建 WebView2 数据目录）。用一次性探针文件
// 实测 ACL，FILE_FLAG_DELETE_ON_CLOSE 保证句柄一关探针即消失，不留垃圾。
bool DirectoryWritable(const std::wstring &dir) {
  const std::wstring probe = dir + L"\\.fushi-webview2-write-probe";
  HANDLE handle = ::CreateFileW(
      probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
  if (handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  ::CloseHandle(handle);
  return true;
}

// BUG-1483: WebView2 不传 userDataFolder 时默认把数据目录建在 exe 旁
// （<exe>.WebView2\EBWebView）。装进 Program Files 这类普通用户不可写的目录后，
// msedgewebview2 建不出数据目录 → 每次启动弹「无法创建数据目录」、阅读器/查词
// WebView 整体不可用。fork 的两个环境创建点（in_app_webview.cpp 默认环境 +
// webview_environment.cpp 自定义环境）都以 FUSHI_WEBVIEW2_USER_DATA_FOLDER 为
// 唯一覆盖入口，所以在引擎起来之前探测一次：
// - 变量已设（itest harness，TODO-1003）→ 原样尊重；
// - exe 旁可写（含既有 <exe>.WebView2 profile 本身可写）→ 什么都不做，存量
//   安装的 profile 位置字节不变（Never break userspace）；
// - 不可写 → 把变量指到 %LOCALAPPDATA%\Fushi\WebView2（与全局查词浮窗的
//   OverlayUserDataFolder 同根不同叶，不会撞 0x8007139F 选项冲突）。
// 值只由 exe 路径与 ACL 决定，同一 exe 的两个进程仍会算出同一目录，单实例
// 守卫（BUG-437）防并发共享的职责不变。
void EnsureWritableWebView2UserDataFolder() {
  if (::GetEnvironmentVariableW(L"FUSHI_WEBVIEW2_USER_DATA_FOLDER", nullptr,
                                0) > 0) {
    return;
  }
  wchar_t exe_path[MAX_PATH];
  const DWORD len = ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) {
    return;  // 拿不到 exe 路径：维持默认行为，错误留给 WebView2 自己浮现。
  }
  const std::wstring exe(exe_path, len);
  const size_t slash = exe.find_last_of(L'\\');
  if (slash == std::wstring::npos) {
    return;
  }
  const std::wstring default_folder = exe + L".WebView2";
  const DWORD attrs = ::GetFileAttributesW(default_folder.c_str());
  const bool has_default_dir = attrs != INVALID_FILE_ATTRIBUTES &&
                               (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
  // 既有 profile 在就探它自己（它可写即可继续用），否则探 exe 目录
  // （WebView2 需要在这里新建 <exe>.WebView2）。
  if (DirectoryWritable(has_default_dir ? default_folder
                                        : exe.substr(0, slash))) {
    return;
  }
  wchar_t local_appdata[MAX_PATH];
  const DWORD n =
      ::GetEnvironmentVariableW(L"LOCALAPPDATA", local_appdata, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return;
  }
  std::wstring fallback(local_appdata, n);
  fallback += L"\\Fushi";
  ::CreateDirectoryW(fallback.c_str(), nullptr);
  fallback += L"\\WebView2";
  ::CreateDirectoryW(fallback.c_str(), nullptr);
  ::SetEnvironmentVariableW(L"FUSHI_WEBVIEW2_USER_DATA_FOLDER",
                            fallback.c_str());
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Inno Setup 静默更新靠这个命名互斥量检测并关闭运行中的实例（见 hibiki.iss AppMutex）。
  // TODO-904 / BUG-437: 真单实例守卫。第二个 fushi.exe 与首实例共享同一 WebView2
  // 默认 userDataFolder（基于 exe 名），而 WebView2 契约不允许多进程并发同一
  // userDataFolder → 第二实例 env 创建锁冲突失败 → `Cannot create the InAppWebView
  // instance!`。原本只 CreateMutexW 不查 ERROR_ALREADY_EXISTS = 没有真单实例。
  // 此处检测已有实例则把首实例窗口前置并退出本进程，消除双实例锁冲突放大器。
  // 集成测试 runner（FUSHI_TEST_HIDDEN 非空）跳过整套单实例守卫——见 IsTestRunnerMode
  // 注释：否则撞用户实例的互斥量会在引擎初始化前退出，itest 无法 attach。
  const bool test_runner = IsTestRunnerMode();
  HANDLE single_instance_mutex = nullptr;
  bool another_instance = false;
  if (!test_runner) {
    ::SetLastError(ERROR_SUCCESS);
    single_instance_mutex =
        ::CreateMutexW(nullptr, FALSE, L"FushiSingleInstanceMutex");
    another_instance = single_instance_mutex != nullptr &&
                       ::GetLastError() == ERROR_ALREADY_EXISTS;
  }
  // TODO-935 BUG 修复：数据迁移后的自动重启会以 detached 模式拉起带 [kRestartMarkerArg]
  // 的新进程，但此刻旧进程尚未走完退出序列、仍持有单实例互斥量。若直接按「二次启动」
  // 退出本进程，则重启落空：数据已迁到新根、data_root pref 已写，但应用从未重新初始化
  // 去读新根 → 用户看到「弹了下进度就重启、位置没变」。带重启标志时改为**等待**旧进程
  // 释放互斥量（旧进程 exit(0) 后句柄关闭），取得所有权后继续正常启动，新进程的
  // AppPaths.resolve() 即读到新 data_root。等待加 10s 上界，旧进程异常不退时退回二次
  // 启动语义（前置旧窗口 + 退出），不永久卡死。普通用户二次点击图标无此标志，行为不变。
  if (another_instance && HasRestartMarker()) {
    if (WaitForSingleInstanceMutex(single_instance_mutex, 10000)) {
      another_instance = false;  // 已接管单实例所有权：按首实例正常启动。
    }
  }
  if (another_instance) {
    // 已有实例在跑：找到首实例主窗口。
    HWND existing = ::FindWindowW(nullptr, L"Fushi");
    if (existing != nullptr) {
      // TODO-904 P0 回归修复：本次启动若带视频文件参数（文件关联 / 拖到 exe /
      // CLI `fushi.exe "%1"`），必须把路径**转交**首实例，否则第二实例只前置窗口
      // 就退出 → 视频路径整个丢掉、首实例从不知情 →「点了没反应」。用 WM_COPYDATA
      // 把 UTF-8 路径字节跨进程发给首实例的窗口过程（见 flutter_window.cpp 的
      // WM_COPYDATA 处理 → app.fushi/external_video MethodChannel →
      // _openExternalVideo）。无文件参数（纯第二次启动）则只前置 + 退出。
      const std::wstring file_arg = FirstFileArgFromCommandLine();
      if (!file_arg.empty()) {
        ::fushi::SendExternalVideoPath(existing, file_arg);
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

  // BUG-1483：必须在 Flutter engine（进而 WebView2 环境）创建之前决定用户数据
  // 目录，见函数注释。
  EnsureWritableWebView2UserDataFolder();

  // BUG-209 / TODO-398：在 Flutter engine / COM 初始化之前安装进程级 minidump
  // 写出（写进 %LOCALAPPDATA%\Fushi\crashdumps\，链回引擎既有 filter），让
  // GraphicsCapture 延迟 UAF 崩溃必留可被 cdb 分析的 dump，不再赌系统 WER。
  ::fushi::InstallCrashDumpHandler();

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
  if (!window.CreateAndShow(L"Fushi", origin, size)) {
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
