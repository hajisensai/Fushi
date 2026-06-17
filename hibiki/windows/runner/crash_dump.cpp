#include "crash_dump.h"

#include <windows.h>
#include <dbghelp.h>
#include <shlobj.h>
#include <cwchar>

namespace hibiki
{
  namespace
  {
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
        GetEnvironmentVariableW(L"HIBIKI_TEST_ROOT", root, MAX_PATH);
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
      if (!AppendSegmentW(dir, &p, L"\\Hibiki")) return false;
      CreateDirectoryW(dir, nullptr);
      if (!AppendSegmentW(dir, &p, L"\\crashdumps")) return false;
      CreateDirectoryW(dir, nullptr);
      return true;
    }

    LONG WINAPI WriteDumpFilter(EXCEPTION_POINTERS* exception_pointers)
    {
      // 解析 %LOCALAPPDATA%\Hibiki\crashdumps\ 并确保存在（与 wgc_capture.log 同根，
      // 便于用户一次性打包上传）。SHGetKnownFolderPath 内部分配一小块 COM 内存，
      // 在 0xc0000005（读 null）这类异常下进程堆通常仍可用；若失败则放弃写 dump。
      wchar_t dir[MAX_PATH];
      if (ResolveCrashDumpDirectory(dir)) {
        // 文件名：hibiki-<pid>-<tickcount>.dmp（pid+tick 足以区分并发/连续崩溃）。
        wchar_t path[MAX_PATH];
        size_t fp = 0;
        for (size_t i = 0; dir[i] != L'\0'; ++i) path[fp++] = dir[i];
        fp += AppendW(path + fp, L"\\hibiki-");
        fp += AppendDecW(path + fp, GetCurrentProcessId(), 1);
        path[fp++] = L'-';
        fp += AppendDecW(path + fp, GetTickCount(), 1);
        fp += AppendW(path + fp, L".dmp");
        path[fp] = L'\0';

        // 动态加载 dbghelp（避免对 runner 强加链接依赖；找不到则放弃）。
        HMODULE dbghelp = LoadLibraryW(L"dbghelp.dll");
        if (dbghelp) {
          using MiniDumpWriteDumpFn = BOOL(WINAPI*)(
            HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
            PMINIDUMP_EXCEPTION_INFORMATION,
            PMINIDUMP_USER_STREAM_INFORMATION, PMINIDUMP_CALLBACK_INFORMATION);
          auto write_dump = reinterpret_cast<MiniDumpWriteDumpFn>(
            GetProcAddress(dbghelp, "MiniDumpWriteDump"));
          if (write_dump) {
            HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ,
              nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (file != INVALID_HANDLE_VALUE) {
              MINIDUMP_EXCEPTION_INFORMATION mei{};
              mei.ThreadId = GetCurrentThreadId();
              mei.ExceptionPointers = exception_pointers;
              mei.ClientPointers = FALSE;
              // MiniDumpWithThreadInfo + IndirectlyReferencedMemory：足够 cdb
              // !analyze -v 解出 GraphicsCapture 偏移 + !vprot 验崩溃帧池内存状态，
              // 同时控制 dump 体积（不抓全堆，便于上传）。
              const MINIDUMP_TYPE type = static_cast<MINIDUMP_TYPE>(
                MiniDumpWithThreadInfo |
                MiniDumpWithIndirectlyReferencedMemory |
                MiniDumpWithUnloadedModules);
              write_dump(GetCurrentProcess(), GetCurrentProcessId(), file,
                type, &mei, nullptr, nullptr);
              CloseHandle(file);
            }
          }
          FreeLibrary(dbghelp);
        }
      }

      // 链回前一个 filter（Flutter engine 上报等），保留其行为。
      if (g_previous_filter) {
        return g_previous_filter(exception_pointers);
      }
      return EXCEPTION_EXECUTE_HANDLER;
    }
  }  // namespace

  void InstallCrashDumpHandler()
  {
    g_previous_filter = SetUnhandledExceptionFilter(WriteDumpFilter);
  }
}
