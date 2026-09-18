#include "hang_watchdog.h"

#include <windows.h>
#include <cwchar>

#include "crash_dump.h"

namespace fushi
{
  namespace
  {
    // 采样间隔：1 s。`IsHungAppWindow` 是廉价的系统状态读取，不涉及跨线程消息。
    constexpr DWORD kPollIntervalMs = 1000;

    HWND g_main_window = nullptr;
    DWORD g_main_thread_id = 0;
    HANDLE g_thread = nullptr;
    HANDLE g_stop_event = nullptr;

    // 把「什么时候、卡了多久、dump 在哪」追加进同目录 hang_watchdog.log。
    // 一行 ASCII/UTF-16 混排会让 Dart 侧读起来麻烦，统一写 UTF-8。
    void AppendHangLog(const wchar_t* dir, DWORD hung_ms, const wchar_t* dump_path)
    {
      wchar_t log_path[MAX_PATH];
      const size_t dir_len = wcslen(dir);
      if (dir_len + wcslen(L"\\hang_watchdog.log") >= MAX_PATH) return;
      wcscpy_s(log_path, dir);
      wcscat_s(log_path, L"\\hang_watchdog.log");

      SYSTEMTIME st;
      GetLocalTime(&st);
      wchar_t line[MAX_PATH + 160];
      swprintf_s(line,
        L"[%04u-%02u-%02u %02u:%02u:%02u] pid=%lu main thread unresponsive "
        L">=%lu ms; hang dump=%s\r\n",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
        GetCurrentProcessId(), hung_ms,
        dump_path[0] ? dump_path : L"(write failed)");

      char utf8[sizeof(line)];
      const int n = WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8,
        static_cast<int>(sizeof(utf8)), nullptr, nullptr);
      if (n <= 1) return;

      HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA, FILE_SHARE_READ,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) return;
      DWORD written = 0;
      WriteFile(file, utf8, static_cast<DWORD>(n - 1), &written, nullptr);
      CloseHandle(file);
    }

    DWORD WINAPI WatchdogMain(LPVOID)
    {
      DWORD hung_ms = 0;
      for (;;) {
        if (WaitForSingleObject(g_stop_event, kPollIntervalMs) == WAIT_OBJECT_0) {
          return 0;
        }
        if (!IsWindow(g_main_window)) {
          return 0;
        }
        if (!IsHungAppWindow(g_main_window)) {
          hung_ms = 0;
          continue;
        }
        hung_ms += kPollIntervalMs;
        if (hung_ms < kHangDumpThresholdMs) {
          continue;
        }
        // 调试器断点下主线程当然不泵消息，那不是卡死。
        if (IsDebuggerPresent()) {
          hung_ms = 0;
          continue;
        }
        wchar_t dump_path[MAX_PATH] = L"";
        WriteProcessMinidump(L"hang", g_main_thread_id, nullptr, dump_path);
        wchar_t dir[MAX_PATH];
        if (ResolveCrashDumpDirectory(dir)) {
          AppendHangLog(dir, hung_ms, dump_path);
        }
        // 每进程只抓一次：卡死一般持续到被强杀，第二份 dump 与第一份内容相同，
        // 只会白占磁盘。抓完线程退出，看门狗到此结束。
        return 0;
      }
    }
  }  // namespace

  void StartHangWatchdog(HWND main_window)
  {
    if (g_thread != nullptr || main_window == nullptr) return;
    g_main_window = main_window;
    g_main_thread_id = GetCurrentThreadId();
    // 现在（主线程还活着）就把 dbghelp 载好：抓 dump 那一刻主线程若正持有
    // loader lock，看门狗线程再去 LoadLibraryW 会一起卡死。
    PreloadMinidumpWriter();
    g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_stop_event == nullptr) return;
    g_thread = CreateThread(nullptr, 0, WatchdogMain, nullptr, 0, nullptr);
    if (g_thread == nullptr) {
      CloseHandle(g_stop_event);
      g_stop_event = nullptr;
    }
  }

  void StopHangWatchdog()
  {
    if (g_thread == nullptr) return;
    SetEvent(g_stop_event);
    WaitForSingleObject(g_thread, 2000);
    CloseHandle(g_thread);
    CloseHandle(g_stop_event);
    g_thread = nullptr;
    g_stop_event = nullptr;
    g_main_window = nullptr;
  }
}
