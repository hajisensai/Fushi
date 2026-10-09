// The included functions are extracted verbatim from update_launcher.cpp at
// configure time. Every OS, process, clock and disk boundary is inert here.
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
#include <string>
#include <utility>
#include <vector>

using DWORD = std::uint32_t;
using HANDLE = void*;
constexpr DWORD WAIT_OBJECT_0 = 0;
constexpr DWORD WAIT_TIMEOUT = 258;
constexpr DWORD WAIT_FAILED = 0xffffffffu;
constexpr DWORD ERROR_SUCCESS = 0;
constexpr DWORD ERROR_INVALID_HANDLE = 6;
constexpr DWORD kInstallerExitTimeoutMs = 1800000;
constexpr DWORD kAppRelaunchWaitMs = 20000;
struct ParsedArgs {
  std::wstring marker_path = L"fixture.json";
  std::wstring app_exe_path = L"fixture-fushi.exe";
};
struct InstallerRun {
  HANDLE process = reinterpret_cast<HANDLE>(static_cast<std::uintptr_t>(1));
};

namespace {
DWORD next_wait = WAIT_OBJECT_0;
bool app_alive = false;
int starts = 0;
int waits = 0;
int closes = 0;
std::map<std::string, std::string> marker;
}  // namespace

DWORD WaitForSingleObject(HANDLE, DWORD timeout) {
  ++waits;
  if (timeout != kInstallerExitTimeoutMs) std::abort();
  return next_wait;
}
DWORD GetLastError() { return 1234; }
bool GetExitCodeProcess(HANDLE, DWORD* code) {
  *code = 7;  // A failed installation still needs app recovery after real exit.
  return true;
}
bool CloseHandle(HANDLE) { ++closes; return true; }
bool WaitForAppAlive(DWORD timeout) {
  if (timeout != kAppRelaunchWaitMs) std::abort();
  return app_alive;
}
std::wstring AppExecutablePath(const std::wstring& path) { return path; }
bool StartApp(const std::wstring&) { ++starts; return true; }
std::string ToUtf8(const std::wstring&) { return "fixture-fushi.exe"; }
std::string JsonString(const std::string& value) { return value; }
std::string NowIsoUtc() { return "fixture-clock"; }
void AppendMarkerFields(
    const std::wstring&,
    const std::vector<std::pair<std::string, std::string>>& fields) {
  for (const auto& field : fields) marker[field.first] = field.second;
}

#include "update_launcher_completion_production.inc"

int main() {
  struct Case {
    const char* name;
    DWORD wait;
    bool alive;
    bool launched;
    bool has_handle;
    int expected_starts;
    bool expected_exit_marker;
  };
  const Case cases[] = {
      {"signaled-failed-install-no-app", WAIT_OBJECT_0, false, true, true, 1, true},
      {"timeout-installer-still-active", WAIT_TIMEOUT, false, true, true, 0, false},
      {"failed-wait-exit-unproven", WAIT_FAILED, false, true, true, 0, false},
      {"signaled-exit-app-already-alive", WAIT_OBJECT_0, true, true, true, 0, true},
      {"installer-never-launched", WAIT_OBJECT_0, false, false, false, 1, false},
      {"missing-handle-exit-unproven", WAIT_FAILED, false, true, false, 0, false},
      {"timeout-app-already-alive", WAIT_TIMEOUT, true, true, true, 0, false},
  };
  int failures = 0;
  for (const Case& c : cases) {
    next_wait = c.wait;
    app_alive = c.alive;
    starts = waits = closes = 0;
    marker.clear();
    const ParsedArgs args;
    int code = 0;
    if (c.launched) {
      InstallerRun run;
      if (!c.has_handle) run.process = nullptr;
      code = CompleteInstallerWait(args, run);
    } else {
      // Exact CreateProcess-failure recovery call from the production entry.
      EnsureAppBack(args, 0, false);
    }
    const bool exit_marker = marker.count("installerExitedAt") != 0;
    bool passed = starts == c.expected_starts &&
        exit_marker == c.expected_exit_marker &&
        waits == (c.launched && c.has_handle ? 1 : 0) && closes == waits;
    if (c.launched) {
      passed &= code == (c.expected_exit_marker ? 0 : 5);
      passed &= marker["installerExitObserved"] == (c.expected_exit_marker ? "true" : "false");
      if (!c.expected_exit_marker) {
        passed &= marker.count("installerExitCode") == 0;
        passed &= marker["installerWaitResult"] == std::to_string(c.wait);
        passed &= marker["installerWaitTimedOut"] == (c.wait == WAIT_TIMEOUT ? "true" : "false");
        const DWORD expected_error = !c.has_handle ? ERROR_INVALID_HANDLE :
            c.wait == WAIT_FAILED ? 1234 : ERROR_SUCCESS;
        passed &= marker["installerWaitError"] == std::to_string(expected_error);
      }
    }
    std::cout << c.name << " starts=" << starts << " exitMarker=" << exit_marker
              << " return=" << code << " verdict=" << (passed ? "PASS" : "FAIL") << '\n';
    if (!passed) ++failures;
  }
  std::cout << "cases=7 failures=" << failures << " processSideEffects=0\n";
  return failures == 0 ? 0 : 1;
}
