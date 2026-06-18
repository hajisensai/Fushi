#include "wgc_log.h"

#include <shlobj.h>

#include <mutex>

#pragma comment(lib, "Shell32.lib")

namespace flutter_inappwebview_plugin
{
  namespace
  {
    // 进程级写锁：正常路径下 WGC 生命周期点全在 UI 线程串行触发（零竞争），
    // 此锁纯防御并发兜底，绝不阻塞 capture 关键路径。
    SRWLOCK g_write_lock = SRWLOCK_INIT;

    // 把无符号 64 位值以十六进制写进 buf（不带 0x 前缀），返回写入字节数。
    // 手写以避免崩溃 filter 路径上的 CRT/STL 堆分配（snprintf 可能分配）。
    size_t AppendHex(char* buf, uint64_t value)
    {
      char tmp[16];
      int n = 0;
      if (value == 0) {
        buf[0] = '0';
        return 1;
      }
      while (value != 0 && n < 16) {
        const int digit = static_cast<int>(value & 0xF);
        tmp[n++] = static_cast<char>(digit < 10 ? ('0' + digit)
          : ('a' + digit - 10));
        value >>= 4;
      }
      for (int i = 0; i < n; ++i) {
        buf[i] = tmp[n - 1 - i];
      }
      return static_cast<size_t>(n);
    }

    // 把无符号十进制值写进 buf（左侧补零到 [width] 位），返回写入字节数。
    size_t AppendDec(char* buf, uint32_t value, int width)
    {
      char tmp[10];
      int n = 0;
      do {
        tmp[n++] = static_cast<char>('0' + (value % 10));
        value /= 10;
      } while (value != 0 && n < 10);
      const int pad = width > n ? width - n : 0;
      int out = 0;
      for (int i = 0; i < pad; ++i) {
        buf[out++] = '0';
      }
      for (int i = 0; i < n; ++i) {
        buf[out++] = tmp[n - 1 - i];
      }
      return static_cast<size_t>(out);
    }

    std::wstring TestLogFilePath()
    {
      wchar_t root[MAX_PATH];
      const DWORD len =
        GetEnvironmentVariableW(L"HIBIKI_TEST_ROOT", root, MAX_PATH);
      if (len == 0 || len >= MAX_PATH) {
        return std::wstring();
      }
      std::wstring logs(root);
      logs += L"\\logs";
      CreateDirectoryW(logs.c_str(), nullptr);
      std::wstring native = logs + L"\\native";
      CreateDirectoryW(native.c_str(), nullptr);
      return native + L"\\wgc_capture.log";
    }
  }  // namespace

  const std::wstring& WgcLog::LogFilePath()
  {
    // 惰性解析一次：%LOCALAPPDATA%\Hibiki\wgc_capture.log，确保 Hibiki 子目录存在。
    // 解析/建目录失败则缓存空串 -> 日志静默禁用，绝不影响 capture。
    static const std::wstring path = [] () -> std::wstring {
      const std::wstring testPath = TestLogFilePath();
      if (!testPath.empty()) {
        return testPath;
      }
      PWSTR local_app_data = nullptr;
      if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
        &local_app_data)) || local_app_data == nullptr) {
        if (local_app_data) {
          CoTaskMemFree(local_app_data);
        }
        return std::wstring();
      }
      std::wstring dir(local_app_data);
      CoTaskMemFree(local_app_data);
      dir += L"\\Hibiki";
      // CreateDirectoryW 在已存在时返回 ERROR_ALREADY_EXISTS，视为成功。
      if (!CreateDirectoryW(dir.c_str(), nullptr) &&
        GetLastError() != ERROR_ALREADY_EXISTS) {
        return std::wstring();
      }
      return dir + L"\\wgc_capture.log";
    }();
    return path;
  }

  void WgcLog::TrimIfTooLarge(const std::wstring& path)
  {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      return;
    }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= kMaxFileBytes) {
      CloseHandle(file);
      return;
    }
    // 超限：保留尾部 kMaxFileBytes/2，重写文件（人工读日志只关心最近事件）。
    const DWORD keep = kMaxFileBytes / 2;
    LARGE_INTEGER offset{};
    offset.QuadPart = size.QuadPart - keep;
    if (SetFilePointerEx(file, offset, nullptr, FILE_BEGIN)) {
      std::string tail(keep, '\0');
      DWORD read = 0;
      if (ReadFile(file, tail.data(), keep, &read, nullptr) && read > 0) {
        // 从第一个换行后开始，避免半行残留。
        size_t start = tail.find('\n', 0);
        const char* data = tail.data();
        DWORD len = read;
        if (start != std::string::npos && start + 1 < read) {
          data += (start + 1);
          len = read - static_cast<DWORD>(start + 1);
        }
        SetFilePointerEx(file, LARGE_INTEGER{}, nullptr, FILE_BEGIN);
        SetEndOfFile(file);
        DWORD written = 0;
        WriteFile(file, data, len, &written, nullptr);
        SetEndOfFile(file);
      }
    }
    CloseHandle(file);
  }

  void WgcLog::Write(const char* event, const void* pool,
    const std::string& detail)
  {
    const std::wstring& path = LogFilePath();
    if (path.empty()) {
      return;
    }

    // 格式化整行到栈缓冲（无堆分配）：
    //   <YYYY-MM-DDThh:mm:ss.mmmZ> tid=<dec> evt=<name> pool=0x<hex> <detail>\r\n
    char line[512];
    size_t pos = 0;
    SYSTEMTIME st{};
    GetSystemTime(&st);  // UTC
    pos += AppendDec(line + pos, st.wYear, 4);
    line[pos++] = '-';
    pos += AppendDec(line + pos, st.wMonth, 2);
    line[pos++] = '-';
    pos += AppendDec(line + pos, st.wDay, 2);
    line[pos++] = 'T';
    pos += AppendDec(line + pos, st.wHour, 2);
    line[pos++] = ':';
    pos += AppendDec(line + pos, st.wMinute, 2);
    line[pos++] = ':';
    pos += AppendDec(line + pos, st.wSecond, 2);
    line[pos++] = '.';
    pos += AppendDec(line + pos, st.wMilliseconds, 3);
    line[pos++] = 'Z';

    const char* kTid = " tid=";
    for (const char* p = kTid; *p; ++p) line[pos++] = *p;
    pos += AppendDec(line + pos, GetCurrentThreadId(), 1);

    const char* kPid = " pid=";
    for (const char* p = kPid; *p; ++p) line[pos++] = *p;
    pos += AppendDec(line + pos, GetCurrentProcessId(), 1);

    const char* kEvt = " evt=";
    for (const char* p = kEvt; *p; ++p) line[pos++] = *p;
    for (const char* p = event; p && *p && pos < sizeof(line) - 64; ++p) {
      line[pos++] = *p;
    }

    const char* kPool = " pool=0x";
    for (const char* p = kPool; *p; ++p) line[pos++] = *p;
    pos += AppendHex(line + pos, reinterpret_cast<uintptr_t>(pool));

    if (!detail.empty()) {
      line[pos++] = ' ';
      for (size_t i = 0; i < detail.size() && pos < sizeof(line) - 4; ++i) {
        const char c = detail[i];
        // 折叠换行/制表，保证「一事件一行」可解析。
        line[pos++] = (c == '\n' || c == '\r' || c == '\t') ? ' ' : c;
      }
    }
    line[pos++] = '\r';
    line[pos++] = '\n';

    {
      AcquireSRWLockExclusive(&g_write_lock);
      // FILE_APPEND_DATA：内核保证多写者各自 append 不交错（同一句柄打开）。
      HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(file, line, static_cast<DWORD>(pos), &written, nullptr);
        CloseHandle(file);
      }
      ReleaseSRWLockExclusive(&g_write_lock);
    }

    TrimIfTooLarge(path);
  }
}
