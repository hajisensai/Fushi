#include "code_integrity_probe.h"

#include <windows.h>
#include <winevt.h>

#include <atomic>
#include <cstdlib>
#include <string>
#include <vector>

#include "code_integrity_report.h"
#include "crash_dump.h"
#include "native_glog.h"

namespace fushi
{
  namespace
  {
    std::atomic<bool> g_probe_running{false};

    constexpr wchar_t kChannel[] = L"Microsoft-Windows-CodeIntegrity/Operational";
    constexpr DWORD kEvtNextTimeoutMs = 5000;

    std::wstring CrashDumpDirectory()
    {
      wchar_t dir[MAX_PATH];
      if (!ResolveCrashDumpDirectory(dir)) return L"";
      return dir;
    }

    std::wstring ExecutableDirectory()
    {
      std::vector<wchar_t> buffer(MAX_PATH);
      for (;;) {
        const DWORD n = GetModuleFileNameW(nullptr, buffer.data(),
          static_cast<DWORD>(buffer.size()));
        if (n == 0) return L"";
        if (n < buffer.size()) {
          const std::wstring path(buffer.data(), n);
          const size_t slash = path.find_last_of(L'\\');
          return slash == std::wstring::npos ? L"" : path.substr(0, slash);
        }
        if (buffer.size() >= 32768) return L"";
        buffer.resize(buffer.size() * 2);
      }
    }

    std::wstring EnvironmentVariable(const wchar_t* name)
    {
      const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
      if (size == 0) return L"";
      std::wstring value(size, L'\0');
      const DWORD n = GetEnvironmentVariableW(name, value.data(), size);
      if (n == 0 || n >= size) return L"";
      value.resize(n);
      return value;
    }

    // 与 hang_watchdog.cpp 的 AppendHangLogLine 同格式：[本地时间] pid=<pid> <text>。
    void AppendUtf8Line(const std::wstring& path, const std::wstring& text)
    {
      SYSTEMTIME st;
      GetLocalTime(&st);
      wchar_t stamp[64];
      swprintf_s(stamp, L"[%04u-%02u-%02u %02u:%02u:%02u] pid=%lu ",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
        GetCurrentProcessId());
      const std::wstring line = stamp + text + L"\r\n";
      const int bytes = WideCharToMultiByte(CP_UTF8, 0, line.c_str(),
        static_cast<int>(line.size()), nullptr, 0, nullptr, nullptr);
      if (bytes <= 0) return;
      std::string utf8(static_cast<size_t>(bytes), '\0');
      WideCharToMultiByte(CP_UTF8, 0, line.c_str(), static_cast<int>(line.size()),
        utf8.data(), bytes, nullptr, nullptr);
      HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) return;
      DWORD written = 0;
      WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
      CloseHandle(file);
    }

    unsigned long long ReadLastReportedRecord(const std::wstring& path)
    {
      HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) return 0;
      char buffer[32] = {};
      DWORD read = 0;
      ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
      CloseHandle(file);
      return strtoull(buffer, nullptr, 10);
    }

    void WriteLastReportedRecord(const std::wstring& path, unsigned long long id)
    {
      HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) return;
      const std::string text = std::to_string(id);
      DWORD written = 0;
      WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
      CloseHandle(file);
    }

    bool ReadSmartAppControlState(DWORD* value)
    {
      DWORD size = sizeof(DWORD);
      return RegGetValueW(HKEY_LOCAL_MACHINE,
        L"SYSTEM\\CurrentControlSet\\Control\\CI\\Policy",
        L"VerifiedAndReputablePolicyState", RRF_RT_REG_DWORD, nullptr, value,
        &size) == ERROR_SUCCESS;
    }

    std::wstring RenderEventXml(EVT_HANDLE event)
    {
      DWORD used = 0;
      DWORD properties = 0;
      if (EvtRender(nullptr, event, EvtRenderEventXml, 0, nullptr, &used,
            &properties) ||
          GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
        return L"";
      }
      std::vector<wchar_t> buffer(used / sizeof(wchar_t) + 1, L'\0');
      if (!EvtRender(nullptr, event, EvtRenderEventXml,
            static_cast<DWORD>(buffer.size() * sizeof(wchar_t)), buffer.data(),
            &used, &properties)) {
        return L"";
      }
      return buffer.data();
    }

    void RunProbe(bool startup_stall)
    {
      const std::wstring dir = CrashDumpDirectory();
      if (dir.empty()) return;
      const std::wstring log_path = dir + L"\\code_integrity.log";
      const std::wstring marker_path = dir + L"\\code_integrity.last_record";
      const unsigned long long stored_cursor = ReadLastReportedRecord(marker_path);
      unsigned long long last_reported = stored_cursor;
      bool cursor_reset = false;
      bool saw_event = false;
      const std::wstring app_dir_key = PathMatchKey(ExecutableDirectory());
      const std::wstring profile_key = PathMatchKey(EnvironmentVariable(L"USERPROFILE"));

      std::vector<std::wstring> lines;
      size_t matched = 0;
      unsigned long long newest_seen = last_reported;
      DWORD query_error = ERROR_SUCCESS;

      const std::wstring query = BuildCodeIntegrityQuery();
      // 倒序：新的在前，超过 kMaxCodeIntegrityLinesPerReport 时留最新的。
      EVT_HANDLE results = EvtQuery(nullptr, kChannel, query.c_str(),
        EvtQueryChannelPath | EvtQueryReverseDirection);
      if (results == nullptr) {
        query_error = GetLastError();
      } else {
        EVT_HANDLE batch[16];
        DWORD returned = 0;
        while (EvtNext(results, ARRAYSIZE(batch), batch, kEvtNextTimeoutMs, 0,
                 &returned)) {
          for (DWORD i = 0; i < returned; ++i) {
            const std::wstring xml = RenderEventXml(batch[i]);
            EvtClose(batch[i]);
            CodeIntegrityEvent event;
            if (!ParseCodeIntegrityEventXml(xml, &event)) continue;
            // 倒序查询：第一条就是结果里最新的，据它判断通道是否被清空过。
            if (!saw_event) {
              saw_event = true;
              if (IsCursorReset(event.record_id, stored_cursor)) {
                cursor_reset = true;
                last_reported = 0;
                newest_seen = 0;
              }
            }
            if (event.record_id > newest_seen) newest_seen = event.record_id;
            if (!IsUnreportedRecord(event.record_id, last_reported) ||
                !EventTouchesFushi(event, app_dir_key)) {
              continue;
            }
            ++matched;
            if (lines.size() < kMaxCodeIntegrityLinesPerReport) {
              lines.push_back(FormatCodeIntegrityLine(event, app_dir_key, profile_key));
            }
          }
        }
        const DWORD end_error = GetLastError();
        if (end_error != ERROR_NO_MORE_ITEMS) query_error = end_error;
        EvtClose(results);
      }

      DWORD sac_value = 0;
      const bool sac_present = ReadSmartAppControlState(&sac_value);
      if (ShouldWriteCodeIntegrityHeader(startup_stall, matched)) {
        std::wstring header = std::wstring(L"code-integrity (") +
          (startup_stall ? L"startup stall" : L"launch") +
          L"): smart app control=" + SmartAppControlStateName(sac_present, sac_value) +
          L"; " + std::to_wstring(matched) +
          L" new blocked load(s) of Fushi files in the last 14 days";
        if (matched > lines.size()) {
          header += L" (newest " + std::to_wstring(lines.size()) + L" listed)";
        }
        if (cursor_reset) {
          header += L"; event log was cleared since the last report (cursor reset)";
        }
        if (query_error != ERROR_SUCCESS) {
          header += L"; event log query error=" + std::to_wstring(query_error);
        }
        AppendUtf8Line(log_path, header);
        for (const std::wstring& line : lines) AppendUtf8Line(log_path, line);
        NativeGlog("code-integrity: matched=" + std::to_string(matched) +
          " sac=" + std::to_string(sac_present ? static_cast<long>(sac_value) : -1L) +
          " query_error=" + std::to_string(query_error));
      }
      if (cursor_reset || newest_seen > last_reported) {
        WriteLastReportedRecord(marker_path, newest_seen);
      }
    }

    DWORD WINAPI ProbeThreadMain(LPVOID parameter)
    {
      RunProbe(parameter != nullptr);
      g_probe_running.store(false);
      return 0;
    }
  }  // namespace

  void StartCodeIntegrityProbe(bool startup_stall)
  {
    bool expected = false;
    if (!g_probe_running.compare_exchange_strong(expected, true)) return;
    HANDLE thread = CreateThread(nullptr, 0, ProbeThreadMain,
      startup_stall ? reinterpret_cast<LPVOID>(1) : nullptr, 0, nullptr);
    if (thread == nullptr) {
      g_probe_running.store(false);
      return;
    }
    CloseHandle(thread);
  }
}  // namespace fushi
