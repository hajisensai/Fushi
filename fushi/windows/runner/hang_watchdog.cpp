#include "hang_watchdog.h"

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cwchar>
#include <string>

#include "crash_dump.h"
#include "native_glog.h"

namespace fushi
{
  namespace
  {
    // 看门狗线程的检查间隔：决定卡顿时长的计量精度（±100 ms）。
    constexpr DWORD kPollIntervalMs = 100;

    HWND g_main_window = nullptr;
    DWORD g_main_thread_id = 0;
    HANDLE g_thread = nullptr;
    HANDLE g_stop_event = nullptr;
    // RegisterWindowMessageW 注册的心跳消息；0 = 看门狗没启动，窗口过程不认。
    std::atomic<UINT> g_heartbeat_message{0};
    // 主线程应答：先写时刻、再 release 写序号；看门狗 acquire 读序号后再读时刻。
    std::atomic<uint32_t> g_acked_seq{0};
    std::atomic<ULONGLONG> g_ack_ms{0};
    // Dart 侧最近一次心跳的时刻；0 = 还没收到过（未布防）。
    std::atomic<ULONGLONG> g_dart_beat_ms{0};

    // 不含系统睡眠 / 休眠时间的单调时钟（毫秒）：合盖睡眠期间两条线程都停着，
    // 用 GetTickCount64 会在唤醒那一刻把睡眠时长误算成卡顿。
    ULONGLONG UnbiasedNowMs()
    {
      ULONGLONG t = 0;
      QueryUnbiasedInterruptTime(&t);  // 100 ns 单位
      return t / 10000;
    }

    // 往 crashdumps\hang_watchdog.log 追加一行 UTF-8（下次启动 Dart 侧折进错误日志）。
    void AppendHangLogLine(const wchar_t* text)
    {
      wchar_t log_path[MAX_PATH];
      if (!ResolveCrashDumpDirectory(log_path)) return;
      if (wcslen(log_path) + wcslen(L"\\hang_watchdog.log") >= MAX_PATH) return;
      wcscat_s(log_path, L"\\hang_watchdog.log");

      SYSTEMTIME st;
      GetLocalTime(&st);
      wchar_t line[MAX_PATH + 200];
      swprintf_s(line, L"[%04u-%02u-%02u %02u:%02u:%02u] pid=%lu %s\r\n",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
        GetCurrentProcessId(), text);

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

    // 抓完新 dump 后把 crashdumps 里 hang-*.dmp 删到只剩 kMaxHangDumpsKept 份
    // （按最后写入时间删最旧的；刚抓的那份最新，不会被删）。
    void PruneOldHangDumps()
    {
      wchar_t dir[MAX_PATH];
      if (!ResolveCrashDumpDirectory(dir)) return;
      const std::wstring base(dir);
      for (;;) {
        WIN32_FIND_DATAW data;
        HANDLE find = FindFirstFileW((base + L"\\hang-*.dmp").c_str(), &data);
        if (find == INVALID_HANDLE_VALUE) return;
        int count = 0;
        std::wstring oldest;
        FILETIME oldest_time{0xFFFFFFFF, 0xFFFFFFFF};
        do {
          if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
          ++count;
          if (CompareFileTime(&data.ftLastWriteTime, &oldest_time) < 0) {
            oldest_time = data.ftLastWriteTime;
            oldest = data.cFileName;
          }
        } while (FindNextFileW(find, &data));
        FindClose(find);
        if (count <= kMaxHangDumpsKept || oldest.empty()) return;
        if (!DeleteFileW((base + L"\\" + oldest).c_str())) return;
      }
    }

    // 完整路径只取文件名写进 hibiki_glookup.log（路径里有用户名，反馈日志不带）。
    std::string DumpFileName(const wchar_t* path)
    {
      const wchar_t* slash = wcsrchr(path, L'\\');
      const wchar_t* name = slash ? slash + 1 : path;
      std::string out;
      for (const wchar_t* p = name; *p; ++p) {
        out.push_back(*p < 0x80 ? static_cast<char>(*p) : '?');
      }
      return out;
    }

    DWORD WINAPI WatchdogMain(LPVOID)
    {
      const UINT heartbeat = g_heartbeat_message.load();
      uint32_t posted_seq = 0;
      ULONGLONG posted_ms = 0;
      bool in_flight = false;
      bool dumped_this_stall = false;
      int dumps_taken = 0;
      bool dart_dumped_this_silence = false;
      int dart_dumps_taken = 0;

      for (;;) {
        if (WaitForSingleObject(g_stop_event, kPollIntervalMs) == WAIT_OBJECT_0) {
          return 0;
        }
        if (!IsWindow(g_main_window)) {
          return 0;
        }

        // Dart 失联：主线程还在泵消息（心跳在途不足 1 s）而 Dart 心跳已静默
        // 很久。主线程自己卡住的情形留给下面的停泵路径，避免同一次事故抓两份。
        const ULONGLONG dart_beat_ms = g_dart_beat_ms.load(std::memory_order_relaxed);
        if (dart_beat_ms != 0 && !IsDebuggerPresent()) {
          const ULONGLONG now_ms = UnbiasedNowMs();
          const ULONGLONG silent_ms =
            now_ms > dart_beat_ms ? now_ms - dart_beat_ms : 0;
          const bool pump_stalled =
            in_flight && now_ms > posted_ms && now_ms - posted_ms >= 1000;
          if (dart_dumped_this_silence && silent_ms < 2000) {
            dart_dumped_this_silence = false;
            NativeGlog("dart heartbeat resumed");
            AppendHangLogLine(L"dart heartbeat resumed");
          } else if (!pump_stalled && !dart_dumped_this_silence &&
                     silent_ms >= kDartSilenceDumpThresholdMs &&
                     dart_dumps_taken < kMaxDartSilenceDumpsPerProcess) {
            dart_dumped_this_silence = true;
            dart_dumps_taken += 1;
            // 与停泵路径同一顺序：先落盘 dump 与 log，再做要分配堆的事。
            wchar_t dump_path[MAX_PATH] = L"";
            WriteProcessMinidump(L"hang", g_main_thread_id, nullptr, dump_path);
            wchar_t text[MAX_PATH + 112];
            swprintf_s(text,
              L"dart heartbeat silent >=%llu ms while main thread pumps; hang dump=%s",
              silent_ms, dump_path[0] ? dump_path : L"(write failed)");
            AppendHangLogLine(text);
            NativeGlog("dart-silence: ms=" + std::to_string(silent_ms) +
              " dump=" + (dump_path[0] ? DumpFileName(dump_path) : "(write failed)"));
            PruneOldHangDumps();
          }
        }

        if (in_flight && g_acked_seq.load(std::memory_order_acquire) == posted_seq) {
          // 心跳被应答：这一轮的停泵时长 = 应答时刻 - 发出时刻（主线程侧计时）。
          const ULONGLONG ack_ms = g_ack_ms.load(std::memory_order_relaxed);
          const ULONGLONG stall_ms = ack_ms > posted_ms ? ack_ms - posted_ms : 0;
          in_flight = false;
          if (stall_ms >= kStallLogThresholdMs && !IsDebuggerPresent()) {
            NativeGlog("main-thread stall: ms=" + std::to_string(stall_ms) +
              " dumped=" + (dumped_this_stall ? "1" : "0"));
            if (dumped_this_stall) {
              wchar_t text[96];
              swprintf_s(text, L"main thread recovered after %llu ms", stall_ms);
              AppendHangLogLine(text);
            }
          }
          dumped_this_stall = false;
        }

        if (!in_flight) {
          posted_seq += 1;
          posted_ms = UnbiasedNowMs();
          if (PostMessageW(g_main_window, heartbeat,
                static_cast<WPARAM>(posted_seq), 0)) {
            in_flight = true;
          }
          continue;
        }

        // 心跳还在途：主线程至少这么久没派发主窗消息。
        const ULONGLONG now_ms = UnbiasedNowMs();
        const ULONGLONG pending_ms = now_ms > posted_ms ? now_ms - posted_ms : 0;
        if (pending_ms < kStallDumpThresholdMs || dumped_this_stall ||
            dumps_taken >= kMaxHangDumpsPerProcess) {
          continue;
        }
        // 调试器断点下主线程当然不泵消息，那不是卡死。
        if (IsDebuggerPresent()) {
          continue;
        }
        dumped_this_stall = true;
        dumps_taken += 1;
        // 顺序有讲究：dump 与 hang_watchdog.log 这两样证据只用栈缓冲和 Win32 调用，
        // 先落盘；要分配堆内存的（NativeGlog 的 std::string / ofstream、清理旧 dump
        // 的 std::wstring）放在后面——主线程若正卡在持有堆锁 / CRT 锁的地方，
        // 看门狗线程在这些调用里跟着阻塞也不会丢掉已抓到的 dump。
        wchar_t dump_path[MAX_PATH] = L"";
        WriteProcessMinidump(L"hang", g_main_thread_id, nullptr, dump_path);
        wchar_t text[MAX_PATH + 96];
        swprintf_s(text, L"main thread unresponsive >=%llu ms; hang dump=%s",
          pending_ms, dump_path[0] ? dump_path : L"(write failed)");
        AppendHangLogLine(text);
        NativeGlog("main-thread stall: ongoing ms=" + std::to_string(pending_ms) +
          " dump=" + (dump_path[0] ? DumpFileName(dump_path) : "(write failed)"));
        PruneOldHangDumps();
      }
    }
  }  // namespace

  bool HandleHangWatchdogHeartbeat(UINT message, WPARAM wparam)
  {
    const UINT heartbeat = g_heartbeat_message.load(std::memory_order_relaxed);
    if (heartbeat == 0 || message != heartbeat) return false;
    g_ack_ms.store(UnbiasedNowMs(), std::memory_order_relaxed);
    g_acked_seq.store(static_cast<uint32_t>(wparam), std::memory_order_release);
    return true;
  }

  void NoteDartHeartbeat()
  {
    g_dart_beat_ms.store(UnbiasedNowMs(), std::memory_order_relaxed);
  }

  void StartHangWatchdog(HWND main_window)
  {
    if (g_thread != nullptr || main_window == nullptr) return;
    const UINT heartbeat = RegisterWindowMessageW(L"FushiHangWatchdogHeartbeat");
    if (heartbeat == 0) return;
    g_main_window = main_window;
    g_main_thread_id = GetCurrentThreadId();
    g_heartbeat_message.store(heartbeat);
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
