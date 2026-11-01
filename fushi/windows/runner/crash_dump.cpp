#include "crash_dump.h"

#include <windows.h>
#include <dbghelp.h>
#include <shlobj.h>
#include <cstdio>
#include <cwchar>

namespace fushi
{
  namespace
  {
    using MiniDumpWriteDumpFn = BOOL(WINAPI*)(
      HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
      PMINIDUMP_EXCEPTION_INFORMATION,
      PMINIDUMP_USER_STREAM_INFORMATION, PMINIDUMP_CALLBACK_INFORMATION);
    // 启动时预载的 MiniDumpWriteDump（见 [PreloadMinidumpWriter]）；dbghelp 句柄
    // 故意不释放，进程生命周期内常驻。
    MiniDumpWriteDumpFn g_minidump_write_dump = nullptr;

    // 保存安装前的 unhandled exception filter（多半是 Flutter engine 的 crash
    // handler），写完自家 dump 后链回它，不抢占引擎既有上报。
    LPTOP_LEVEL_EXCEPTION_FILTER g_previous_filter = nullptr;

    // 把无符号十进制值左侧补零写进 buf（崩溃 filter 内零堆分配），返回字节数。
    size_t AppendDecW(wchar_t* buf, unsigned long value, int width)
    {
      wchar_t tmp[16];
      int n = 0;
      do {
        tmp[n++] = static_cast<wchar_t>(L'0' + (value % 10));
        value /= 10;
      } while (value != 0 && n < 16);
      const int pad = width > n ? width - n : 0;
      int out = 0;
      for (int i = 0; i < pad; ++i) buf[out++] = L'0';
      for (int i = 0; i < n; ++i) buf[out++] = tmp[n - 1 - i];
      return static_cast<size_t>(out);
    }

    size_t AppendW(wchar_t* buf, const wchar_t* s)
    {
      size_t n = 0;
      while (s[n]) { buf[n] = s[n]; ++n; }
      return n;
    }

    bool AppendSegmentW(wchar_t* buf, size_t* pos, const wchar_t* segment)
    {
      const size_t n = wcslen(segment);
      if (*pos + n >= MAX_PATH) {
        return false;
      }
      *pos += AppendW(buf + *pos, segment);
      buf[*pos] = L'\0';
      return true;
    }

    bool ResolveTestCrashDumpDirectory(wchar_t* dir)
    {
      wchar_t root[MAX_PATH];
      const DWORD len =
        GetEnvironmentVariableW(L"FUSHI_TEST_ROOT", root, MAX_PATH);
      if (len == 0 || len >= MAX_PATH) {
        return false;
      }
      size_t p = AppendW(dir, root);
      dir[p] = L'\0';
      CreateDirectoryW(dir, nullptr);
      if (!AppendSegmentW(dir, &p, L"\\logs")) return false;
      CreateDirectoryW(dir, nullptr);
      if (!AppendSegmentW(dir, &p, L"\\native")) return false;
      CreateDirectoryW(dir, nullptr);
      if (!AppendSegmentW(dir, &p, L"\\crashdumps")) return false;
      CreateDirectoryW(dir, nullptr);
      return true;
    }

  }  // namespace

  bool ResolveCrashDumpDirectory(wchar_t* dir)
  {
    if (ResolveTestCrashDumpDirectory(dir)) {
      return true;
    }
    PWSTR local_app_data = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
      &local_app_data)) || local_app_data == nullptr) {
      if (local_app_data) {
        CoTaskMemFree(local_app_data);
      }
      return false;
    }
    size_t p = AppendW(dir, local_app_data);
    CoTaskMemFree(local_app_data);
    if (!AppendSegmentW(dir, &p, L"\\Fushi")) return false;
    CreateDirectoryW(dir, nullptr);
    if (!AppendSegmentW(dir, &p, L"\\crashdumps")) return false;
    CreateDirectoryW(dir, nullptr);
    return true;
  }

  namespace
  {
    // 崩溃摘要（反馈 WkL9BvD7Z9 等「Dart 日志无栈」）：minidump 不随反馈上传（太大、含
    // 内存），但一行「异常码 / 模块+偏移 / 线程 / 栈前若干帧」足够分诊。追加进
    // crashdumps\crash_summary.log，下次启动由 Dart previous_exit_log.dart 读出折进错误
    // 日志后清空。全部用静态缓冲：崩溃 filter 里不碰堆，栈溢出（0xC00000FD）时也不再
    // 吃本就见底的线程栈。
    wchar_t g_summary_line[2048];
    char g_summary_utf8[4096];

    size_t AppendHexW(wchar_t* buf, size_t pos, size_t cap, unsigned long long v)
    {
      static const wchar_t kDigits[] = L"0123456789abcdef";
      wchar_t tmp[17];
      int n = 0;
      do {
        tmp[n++] = kDigits[v & 0xf];
        v >>= 4;
      } while (v != 0 && n < 16);
      if (pos + 2 + n >= cap) return pos;
      buf[pos++] = L'0';
      buf[pos++] = L'x';
      for (int i = n - 1; i >= 0; --i) buf[pos++] = tmp[i];
      buf[pos] = L'\0';
      return pos;
    }

    size_t AppendTextW(wchar_t* buf, size_t pos, size_t cap, const wchar_t* s)
    {
      while (*s && pos + 1 < cap) buf[pos++] = *s++;
      buf[pos] = L'\0';
      return pos;
    }

    // 「模块名+0x偏移」（模块名只取文件名，不带含用户名的完整路径）。
    size_t AppendModuleOffsetW(wchar_t* buf, size_t pos, size_t cap,
      unsigned long long address)
    {
      HMODULE module = nullptr;
      if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
        GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(address), &module) && module != nullptr) {
        wchar_t path[MAX_PATH];
        const DWORD len = GetModuleFileNameW(module, path, MAX_PATH);
        const wchar_t* name = path;
        if (len > 0 && len < MAX_PATH) {
          for (DWORD i = 0; i < len; ++i) {
            if (path[i] == L'\\' || path[i] == L'/') name = path + i + 1;
          }
        } else {
          name = L"?";
        }
        pos = AppendTextW(buf, pos, cap, name);
        pos = AppendTextW(buf, pos, cap, L"+");
        return AppendHexW(buf, pos, cap,
          address - reinterpret_cast<unsigned long long>(module));
      }
      pos = AppendTextW(buf, pos, cap, L"?");
      return AppendHexW(buf, pos, cap, address);
    }

#if defined(_M_X64)
    // 从异常上下文 unwind 出前若干帧（只用 ntdll 的 RtlLookupFunctionEntry /
    // RtlVirtualUnwind，零堆分配）。读坏栈时 SEH 兜住，只是少几帧。
    size_t AppendBacktraceW(wchar_t* buf, size_t pos, size_t cap,
      const CONTEXT* start)
    {
      static CONTEXT ctx;
      ctx = *start;
      __try {
        for (int frame = 0; frame < 10 && ctx.Rip != 0; ++frame) {
          pos = AppendTextW(buf, pos, cap, frame == 0 ? L" frames=" : L",");
          pos = AppendModuleOffsetW(buf, pos, cap, ctx.Rip);
          DWORD64 image_base = 0;
          PRUNTIME_FUNCTION fn = RtlLookupFunctionEntry(ctx.Rip, &image_base,
            nullptr);
          if (fn == nullptr) {
            // 叶函数：返回地址就在栈顶。
            ctx.Rip = *reinterpret_cast<DWORD64*>(ctx.Rsp);
            ctx.Rsp += 8;
          } else {
            PVOID handler_data = nullptr;
            DWORD64 establisher = 0;
            RtlVirtualUnwind(UNW_FLAG_NHANDLER, image_base, ctx.Rip, fn, &ctx,
              &handler_data, &establisher, nullptr);
          }
        }
      } __except (EXCEPTION_EXECUTE_HANDLER) {
        pos = AppendTextW(buf, pos, cap, L",<unwind failed>");
      }
      return pos;
    }
#endif

    void AppendCrashSummary(EXCEPTION_POINTERS* ep, DWORD thread_id,
      const wchar_t* dump_path)
    {
      if (ep == nullptr || ep->ExceptionRecord == nullptr) return;
      wchar_t* line = g_summary_line;
      const size_t cap = sizeof(g_summary_line) / sizeof(wchar_t);
      size_t pos = 0;
      line[0] = L'\0';
      SYSTEMTIME st;
      GetLocalTime(&st);
      wchar_t stamp[32];
      size_t sp = 0;
      sp += AppendDecW(stamp + sp, st.wYear, 4); stamp[sp++] = L'-';
      sp += AppendDecW(stamp + sp, st.wMonth, 2); stamp[sp++] = L'-';
      sp += AppendDecW(stamp + sp, st.wDay, 2); stamp[sp++] = L' ';
      sp += AppendDecW(stamp + sp, st.wHour, 2); stamp[sp++] = L':';
      sp += AppendDecW(stamp + sp, st.wMinute, 2); stamp[sp++] = L':';
      sp += AppendDecW(stamp + sp, st.wSecond, 2);
      stamp[sp] = L'\0';
      pos = AppendTextW(line, pos, cap, L"time=");
      pos = AppendTextW(line, pos, cap, stamp);
      const EXCEPTION_RECORD* rec = ep->ExceptionRecord;
      pos = AppendTextW(line, pos, cap, L" code=");
      pos = AppendHexW(line, pos, cap, rec->ExceptionCode);
      pos = AppendTextW(line, pos, cap, L" at=");
      pos = AppendModuleOffsetW(line, pos, cap,
        reinterpret_cast<unsigned long long>(rec->ExceptionAddress));
      if (rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION &&
        rec->NumberParameters >= 2) {
        const ULONG_PTR op = rec->ExceptionInformation[0];
        pos = AppendTextW(line, pos, cap,
          op == 0 ? L" av=read@" : (op == 1 ? L" av=write@" : L" av=exec@"));
        pos = AppendHexW(line, pos, cap, rec->ExceptionInformation[1]);
      }
      pos = AppendTextW(line, pos, cap, L" thread=");
      wchar_t tid[16];
      tid[AppendDecW(tid, thread_id, 1)] = L'\0';
      pos = AppendTextW(line, pos, cap, tid);
#if defined(_M_X64)
      if (ep->ContextRecord != nullptr) {
        pos = AppendBacktraceW(line, pos, cap, ep->ContextRecord);
      }
#endif
      pos = AppendTextW(line, pos, cap, L" dump=");
      if (dump_path != nullptr && dump_path[0] != L'\0') {
        const wchar_t* name = dump_path;
        for (const wchar_t* c = dump_path; *c; ++c) {
          if (*c == L'\\') name = c + 1;
        }
        pos = AppendTextW(line, pos, cap, name);
      } else {
        pos = AppendTextW(line, pos, cap, L"<not written>");
      }
      // 行尾 CRLF 用字符数组拼，不写成以反斜杠开头的宽字符串字面量：路径字面量守卫
      // （wgc_capture_logging_guard_test，防 MSVC C4129 吞分隔符）只放行转义的 L"\\。
      static constexpr wchar_t kCrlf[] = {L'\r', L'\n', L'\0'};
      pos = AppendTextW(line, pos, cap, kCrlf);

      wchar_t log_path[MAX_PATH];
      if (!ResolveCrashDumpDirectory(log_path)) return;
      size_t lp = wcsnlen(log_path, MAX_PATH);
      if (!AppendSegmentW(log_path, &lp, L"\\crash_summary.log")) return;
      const int bytes = WideCharToMultiByte(CP_UTF8, 0, line,
        static_cast<int>(pos), g_summary_utf8, sizeof(g_summary_utf8), nullptr,
        nullptr);
      if (bytes <= 0) return;
      HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA, FILE_SHARE_READ,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) return;
      DWORD written = 0;
      WriteFile(file, g_summary_utf8, static_cast<DWORD>(bytes), &written,
        nullptr);
      CloseHandle(file);
    }

    LONG WINAPI WriteDumpFilter(EXCEPTION_POINTERS* exception_pointers)
    {
      static wchar_t dump_path[MAX_PATH];
      dump_path[0] = L'\0';
      const DWORD thread_id = GetCurrentThreadId();
      if (!WriteProcessMinidump(L"hibiki", thread_id, exception_pointers,
        dump_path)) {
        dump_path[0] = L'\0';
      }
      AppendCrashSummary(exception_pointers, thread_id, dump_path);

      // 链回前一个 filter（Flutter engine 上报等），保留其行为。
      if (g_previous_filter) {
        return g_previous_filter(exception_pointers);
      }
      return EXCEPTION_EXECUTE_HANDLER;
    }
  }  // namespace

  void RecordSessionEnd(LPARAM end_session_flags)
  {
    // lParam 是位掩码：ENDSESSION_CRITICAL 可与其它位并存，按「最能说明原因」的先取。
    const wchar_t* reason = L"shutdown";
    if (end_session_flags & ENDSESSION_LOGOFF) {
      reason = L"logoff";
    } else if (end_session_flags & ENDSESSION_CLOSEAPP) {
      reason = L"closeapp";
    } else if (end_session_flags & ENDSESSION_CRITICAL) {
      reason = L"critical";
    }
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER t;
    t.LowPart = ft.dwLowDateTime;
    t.HighPart = ft.dwHighDateTime;
    // FILETIME（1601 起 100ns）→ Unix 毫秒。
    const unsigned long long unix_ms =
      (t.QuadPart - 116444736000000000ULL) / 10000ULL;

    char line[96];
    const int len = sprintf_s(line, sizeof(line), "%lu %llu %ls\n",
      GetCurrentProcessId(), unix_ms, reason);
    if (len <= 0) return;

    wchar_t log_path[MAX_PATH];
    if (!ResolveCrashDumpDirectory(log_path)) return;
    size_t lp = wcsnlen(log_path, MAX_PATH);
    if (!AppendSegmentW(log_path, &lp, L"\\session_end.log")) return;
    HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA, FILE_SHARE_READ,
      nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, static_cast<DWORD>(len), &written, nullptr);
    // 关机路径：返回后进程随时被结束，落盘不能留在缓存里。
    FlushFileBuffers(file);
    CloseHandle(file);
  }

  void PreloadMinidumpWriter()
  {
    if (g_minidump_write_dump != nullptr) return;
    HMODULE dbghelp = LoadLibraryW(L"dbghelp.dll");
    if (dbghelp == nullptr) return;
    g_minidump_write_dump = reinterpret_cast<MiniDumpWriteDumpFn>(
      GetProcAddress(dbghelp, "MiniDumpWriteDump"));
  }

  bool WriteProcessMinidump(const wchar_t* prefix, DWORD thread_id,
    EXCEPTION_POINTERS* exception_pointers, wchar_t* out_path)
  {
    // 解析 %LOCALAPPDATA%\Fushi\crashdumps\ 并确保存在（与 wgc_capture.log 同根，
    // 便于用户一次性打包上传）。SHGetKnownFolderPath 内部分配一小块 COM 内存，
    // 在 0xc0000005（读 null）这类异常下进程堆通常仍可用；若失败则放弃写 dump。
    wchar_t dir[MAX_PATH];
    if (!ResolveCrashDumpDirectory(dir)) {
      return false;
    }
    // 文件名：<prefix>-<pid>-<tickcount>.dmp（pid+tick 足以区分并发/连续崩溃）。
    // 崩溃 filter 用 `hibiki`（诊断区按 *.dmp 列出，历史文件名不变）；主线程停泵
    // 看门狗用 `hang`，同一目录，一眼可分「崩了」还是「卡死后抓的」。
    wchar_t path[MAX_PATH];
    size_t fp = 0;
    for (size_t i = 0; dir[i] != L'\0'; ++i) path[fp++] = dir[i];
    path[fp++] = L'\\';
    fp += AppendW(path + fp, prefix);
    path[fp++] = L'-';
    fp += AppendDecW(path + fp, GetCurrentProcessId(), 1);
    path[fp++] = L'-';
    fp += AppendDecW(path + fp, GetTickCount(), 1);
    fp += AppendW(path + fp, L".dmp");
    path[fp] = L'\0';

    bool written = false;
    // 动态加载 dbghelp（避免对 runner 强加链接依赖；找不到则放弃）。优先用启动时
    // [PreloadMinidumpWriter] 缓存的指针：看门狗要抓的正是「主线程卡死」，若主线程
    // 卡在 loader lock 里（DllMain / FreeLibrary / WebView2 teardown 都属此类），
    // 这里再 LoadLibraryW 会跟着死锁、永远拿不到 dump。
    MiniDumpWriteDumpFn write_dump = g_minidump_write_dump;
    HMODULE dbghelp = nullptr;  // 仅按需加载路径持有，用完释放
    if (write_dump == nullptr) {
      dbghelp = LoadLibraryW(L"dbghelp.dll");
      if (dbghelp) {
        write_dump = reinterpret_cast<MiniDumpWriteDumpFn>(
          GetProcAddress(dbghelp, "MiniDumpWriteDump"));
      }
    }
    {
      if (write_dump) {
        HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ,
          nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file != INVALID_HANDLE_VALUE) {
          MINIDUMP_EXCEPTION_INFORMATION mei{};
          mei.ThreadId = thread_id;
          mei.ExceptionPointers = exception_pointers;
          mei.ClientPointers = FALSE;
          // MiniDumpWithThreadInfo + IndirectlyReferencedMemory：足够 cdb
          // !analyze -v 解出 GraphicsCapture 偏移 + !vprot 验崩溃帧池内存状态，
          // 同时控制 dump 体积（不抓全堆，便于上传）。
          const MINIDUMP_TYPE type = static_cast<MINIDUMP_TYPE>(
            MiniDumpWithThreadInfo |
            MiniDumpWithIndirectlyReferencedMemory |
            MiniDumpWithUnloadedModules);
          // 没有异常上下文（hang dump）时不传 exception stream：dbghelp 对
          // ExceptionPointers==nullptr 的 MEI 会失败，全线程栈本身已够看主线程卡在哪。
          written = write_dump(GetCurrentProcess(), GetCurrentProcessId(), file,
            type, exception_pointers ? &mei : nullptr, nullptr, nullptr) != FALSE;
          CloseHandle(file);
        }
      }
      if (dbghelp) FreeLibrary(dbghelp);
    }
    if (written && out_path) {
      for (size_t i = 0; i <= fp; ++i) out_path[i] = path[i];
    }
    return written;
  }

  void InstallCrashDumpHandler()
  {
    g_previous_filter = SetUnhandledExceptionFilter(WriteDumpFilter);
  }
}
