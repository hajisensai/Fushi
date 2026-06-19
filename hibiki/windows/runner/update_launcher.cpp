#include <windows.h>
#include <shellapi.h>

#include <cstdlib>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr DWORD kParentExitTimeoutMs = 120000;
// After the parent PID exits we still poll the single-instance mutex until
// it is truly released. WaitForSingleObject on the parent handle returns as
// soon as that one PID dies, but a second hibiki.exe (or a lingering
// WebView2 child) can keep HibikiSingleInstanceMutex held; launching Inno
// then still trips the AppMutex "is currently running" abort. This closes
// the "only waited on the parent PID" blind spot. The .iss [Code]
// InitializeSetup layer is the primary guard; this is belt-and-suspenders.
constexpr wchar_t kHibikiSingleInstanceMutex[] = L"HibikiSingleInstanceMutex";
constexpr DWORD kMutexReleaseTimeoutMs = 10000;
constexpr DWORD kMutexPollIntervalMs = 250;

std::string ToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                           static_cast<int>(value.size()),
                                           nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(length), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), result.data(), length,
                        nullptr, nullptr);
  return result;
}

std::string JsonEscape(const std::string& value) {
  std::string result;
  result.reserve(value.size() + 8);
  for (const char ch : value) {
    switch (ch) {
      case '\\':
        result += "\\\\";
        break;
      case '"':
        result += "\\\"";
        break;
      case '\b':
        result += "\\b";
        break;
      case '\f':
        result += "\\f";
        break;
      case '\n':
        result += "\\n";
        break;
      case '\r':
        result += "\\r";
        break;
      case '\t':
        result += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x",
                        static_cast<unsigned int>(
                            static_cast<unsigned char>(ch)));
          result += buffer;
        } else {
          result += ch;
        }
        break;
    }
  }
  return result;
}

std::string JsonString(const std::string& value) {
  return "\"" + JsonEscape(value) + "\"";
}

std::string NowIsoUtc() {
  SYSTEMTIME time;
  ::GetSystemTime(&time);
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer),
                "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
                static_cast<unsigned>(time.wYear),
                static_cast<unsigned>(time.wMonth),
                static_cast<unsigned>(time.wDay),
                static_cast<unsigned>(time.wHour),
                static_cast<unsigned>(time.wMinute),
                static_cast<unsigned>(time.wSecond),
                static_cast<unsigned>(time.wMilliseconds));
  return std::string(buffer);
}

std::string LastErrorMessage(const std::string& action) {
  const DWORD error = ::GetLastError();
  LPWSTR raw = nullptr;
  const DWORD length = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&raw), 0, nullptr);
  std::wstring message;
  if (length > 0 && raw != nullptr) {
    message.assign(raw, length);
    while (!message.empty() &&
           (message.back() == L'\r' || message.back() == L'\n')) {
      message.pop_back();
    }
  }
  if (raw != nullptr) {
    ::LocalFree(raw);
  }
  return action + " failed (" + std::to_string(error) + "): " +
         ToUtf8(message);
}

bool ReadTextFile(const std::wstring& path, std::string* output) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE |
                                  FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    output->assign("{}");
    return false;
  }

  LARGE_INTEGER size;
  if (!::GetFileSizeEx(file, &size) || size.QuadPart < 0 ||
      size.QuadPart > 16 * 1024 * 1024) {
    ::CloseHandle(file);
    output->assign("{}");
    return false;
  }

  output->assign(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  const BOOL ok = output->empty()
                      ? TRUE
                      : ::ReadFile(file, output->data(),
                                   static_cast<DWORD>(output->size()), &read,
                                   nullptr);
  ::CloseHandle(file);
  if (!ok) {
    output->assign("{}");
    return false;
  }
  output->resize(read);
  return true;
}

bool WriteTextFile(const std::wstring& path, const std::string& contents) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                              nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD written = 0;
  const BOOL ok =
      contents.empty()
          ? TRUE
          : ::WriteFile(file, contents.data(),
                        static_cast<DWORD>(contents.size()), &written,
                        nullptr);
  ::CloseHandle(file);
  return ok && static_cast<size_t>(written) == contents.size();
}

bool AppendMarkerFields(
    const std::wstring& marker_path,
    const std::vector<std::pair<std::string, std::string>>& fields) {
  std::string json;
  ReadTextFile(marker_path, &json);
  const size_t end = json.find_last_of('}');
  if (end == std::string::npos) {
    json = "{}";
  } else {
    json.erase(end);
  }

  bool has_field = false;
  for (const char ch : json) {
    if (ch != '{' && ch != ' ' && ch != '\r' && ch != '\n' && ch != '\t') {
      has_field = true;
      break;
    }
  }

  for (const auto& field : fields) {
    if (has_field) {
      json += ",";
    }
    json += "\n  ";
    json += JsonString(field.first);
    json += ": ";
    json += field.second;
    has_field = true;
  }
  json += "\n}";
  return WriteTextFile(marker_path, json);
}

std::wstring QuoteArg(const std::wstring& arg) {
  if (arg.empty()) {
    return L"\"\"";
  }
  bool needs_quotes = false;
  for (const wchar_t ch : arg) {
    if (ch == L' ' || ch == L'\t' || ch == L'"' || ch == L'&') {
      needs_quotes = true;
      break;
    }
  }
  if (!needs_quotes) {
    return arg;
  }

  std::wstring result = L"\"";
  int backslashes = 0;
  for (const wchar_t ch : arg) {
    if (ch == L'\\') {
      backslashes++;
      continue;
    }
    if (ch == L'"') {
      result.append(static_cast<size_t>(backslashes * 2 + 1), L'\\');
      result.push_back(ch);
      backslashes = 0;
      continue;
    }
    result.append(static_cast<size_t>(backslashes), L'\\');
    backslashes = 0;
    result.push_back(ch);
  }
  result.append(static_cast<size_t>(backslashes * 2), L'\\');
  result.push_back(L'"');
  return result;
}

std::wstring BuildCommandLine(const std::wstring& executable,
                              const std::vector<std::wstring>& args) {
  std::wstring command_line = QuoteArg(executable);
  for (const std::wstring& arg : args) {
    command_line.push_back(L' ');
    command_line += QuoteArg(arg);
  }
  return command_line;
}

struct ParsedArgs {
  std::wstring marker_path;
  DWORD parent_pid = 0;
  std::wstring installer_path;
  std::vector<std::wstring> installer_args;
};

bool ParseArgs(int argc, wchar_t** argv, ParsedArgs* parsed) {
  int i = 1;
  while (i < argc) {
    const std::wstring arg = argv[i];
    if (arg == L"--") {
      i++;
      break;
    }
    if (arg == L"--marker" && i + 1 < argc) {
      parsed->marker_path = argv[i + 1];
      i += 2;
      continue;
    }
    if (arg == L"--parent-pid" && i + 1 < argc) {
      parsed->parent_pid = static_cast<DWORD>(_wtoi(argv[i + 1]));
      i += 2;
      continue;
    }
    if (arg == L"--installer" && i + 1 < argc) {
      parsed->installer_path = argv[i + 1];
      i += 2;
      continue;
    }
    return false;
  }
  for (; i < argc; i++) {
    parsed->installer_args.push_back(argv[i]);
  }
  return !parsed->marker_path.empty() && parsed->parent_pid > 0 &&
         !parsed->installer_path.empty();
}

void MarkLaunchFailed(const std::wstring& marker_path,
                      const std::string& error) {
  AppendMarkerFields(marker_path,
                     {{"installerLaunchSucceeded", "false"},
                      {"installerLaunchFailedAt", JsonString(NowIsoUtc())},
                      {"launchError", JsonString(error)}});
}

bool WaitForParentExit(const ParsedArgs& args) {
  HANDLE parent = ::OpenProcess(SYNCHRONIZE, FALSE, args.parent_pid);
  if (parent == nullptr) {
    if (::GetLastError() == ERROR_INVALID_PARAMETER) {
      AppendMarkerFields(args.marker_path,
                         {{"parentExitObserved", "true"},
                          {"parentExitObservedAt", JsonString(NowIsoUtc())}});
      return true;
    }
    AppendMarkerFields(args.marker_path,
                       {{"parentExitObserved", "false"},
                        {"parentExitObservedAt", JsonString(NowIsoUtc())}});
    MarkLaunchFailed(args.marker_path, LastErrorMessage("OpenProcess parent"));
    return false;
  }

  const DWORD wait = ::WaitForSingleObject(parent, kParentExitTimeoutMs);
  ::CloseHandle(parent);
  const bool observed = wait == WAIT_OBJECT_0;
  AppendMarkerFields(args.marker_path,
                     {{"parentExitObserved", observed ? "true" : "false"},
                      {"parentExitObservedAt", JsonString(NowIsoUtc())}});
  if (!observed) {
    MarkLaunchFailed(args.marker_path,
                     "Timed out waiting for the Hibiki parent process to exit");
  }
  return observed;
}

// Returns true once HibikiSingleInstanceMutex is no longer present, or false
// if it is still held after kMutexReleaseTimeoutMs. OpenMutexW succeeds (and
// must then be closed) only while some process still holds the named mutex;
// ERROR_FILE_NOT_FOUND means it is gone. We never create the mutex here, so
// probing cannot itself keep the app "running".
bool WaitForMutexReleased() {
  const DWORD deadline = ::GetTickCount() + kMutexReleaseTimeoutMs;
  for (;;) {
    HANDLE mutex = ::OpenMutexW(SYNCHRONIZE, FALSE, kHibikiSingleInstanceMutex);
    if (mutex == nullptr) {
      return true;  // Mutex released (or never existed): safe to launch Inno.
    }
    ::CloseHandle(mutex);
    if (static_cast<LONG>(deadline - ::GetTickCount()) <= 0) {
      return false;  // Still held after the timeout; fall through anyway.
    }
    ::Sleep(kMutexPollIntervalMs);
  }
}

bool LaunchInstaller(const ParsedArgs& args, DWORD* installer_pid) {
  std::wstring command_line =
      BuildCommandLine(args.installer_path, args.installer_args);
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  const BOOL ok = ::CreateProcessW(
      args.installer_path.c_str(), command_line.data(), nullptr, nullptr, FALSE,
      CREATE_NEW_PROCESS_GROUP, nullptr, nullptr, &startup, &process);
  if (!ok) {
    MarkLaunchFailed(args.marker_path, LastErrorMessage("CreateProcess Inno"));
    return false;
  }
  *installer_pid = process.dwProcessId;
  ::CloseHandle(process.hThread);
  ::CloseHandle(process.hProcess);
  return true;
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return 2;
  }

  ParsedArgs args;
  const bool parsed = ParseArgs(argc, argv, &args);
  ::LocalFree(argv);
  if (!parsed) {
    return 2;
  }

  AppendMarkerFields(args.marker_path,
                     {{"launcherStartedAt", JsonString(NowIsoUtc())},
                      {"launcherPid",
                       std::to_string(::GetCurrentProcessId())},
                      {"parentProcessId", std::to_string(args.parent_pid)}});

  if (!WaitForParentExit(args)) {
    return 3;
  }

  // Close the "only waited on the parent PID" blind spot: a second hibiki.exe
  // or a leftover WebView2 child can still hold the mutex after the parent
  // dies. Wait (bounded) for it to be released before launching Inno.
  const bool mutex_released = WaitForMutexReleased();
  AppendMarkerFields(
      args.marker_path,
      {{"launcherMutexReleased", mutex_released ? "true" : "false"},
       {"launcherMutexCheckedAt", JsonString(NowIsoUtc())}});

  DWORD installer_pid = 0;
  if (!LaunchInstaller(args, &installer_pid)) {
    return 4;
  }

  AppendMarkerFields(args.marker_path,
                     {{"installerLaunchSucceeded", "true"},
                      {"installerLaunchedAt", JsonString(NowIsoUtc())},
                      {"installerPid", std::to_string(installer_pid)}});
  return 0;
}
