#undef NDEBUG
#include "../single_instance_mutex.h"

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

void Check(bool ok, const char* message) {
  if (!ok) {
    std::cerr << "FAIL: " << message << " error=" << GetLastError() << '\n';
    std::exit(1);
  }
}

int wmain(int argc, wchar_t** argv) {
  if (argc == 3) {
    fushi::SingleInstanceMutex owner(argv[1]);
    Check(owner.valid() && owner.owns(), "child owns new mutex");
    HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, argv[2]);
    Check(ready != nullptr && SetEvent(ready), "child ready");
    // The parent terminates this isolated test process, exercising kernel
    // abandonment exactly as exit(0)/a crash does without C++ stack unwinding.
    Sleep(INFINITE);
    return 1;
  }

  const std::wstring name = L"Local\\FushiMutexTest-" +
                            std::to_wstring(GetCurrentProcessId());
  const std::wstring ready_name = name + L"-ready";
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, ready_name.c_str());
  Check(ready != nullptr, "create ready event");
  wchar_t exe[MAX_PATH];
  Check(GetModuleFileNameW(nullptr, exe, MAX_PATH) != 0, "test executable");
  std::wstring command = L"\"" + std::wstring(exe) + L"\" \"" + name +
                         L"\" \"" + ready_name + L"\"";
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child = {};
  Check(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child),
        "launch isolated owner process");
  Check(WaitForSingleObject(ready, 5000) == WAIT_OBJECT_0, "owner became ready");

  {
    fushi::SingleInstanceMutex candidate(name.c_str());
    Check(candidate.valid() && !candidate.owns(), "live owner blocks takeover");
    Check(!candidate.Wait(30), "bounded wait cannot steal a live owner");
  }
  fushi::SingleInstanceMutex successor(name.c_str());
  Check(!successor.owns(), "destroying non-owner did not release owner's lock");
  Check(TerminateProcess(child.hProcess, 0), "end isolated owner");
  Check(WaitForSingleObject(child.hProcess, 5000) == WAIT_OBJECT_0, "owner exited");
  Check(successor.Wait(5000), "abandoned ownership transfers after process exit");
  Check(successor.Wait(0), "repeat wait does not acquire recursively");

  // Two candidates race after their old owner releases. Keep the winner alive
  // until the loser has timed out: exactly one may enter engine startup.
  HANDLE gate = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE release_winner = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::atomic<int> entered{0};
  std::atomic<int> finished_wait{0};
  const std::wstring race_name = name + L"-race";
  // Keep a non-owning handle open so this is the same kernel object after the
  // old owner's destructor; creating a fresh object would hide bad releases.
  HANDLE race_handle = nullptr;
  auto compete = [&]() {
    WaitForSingleObject(gate, INFINITE);
    fushi::SingleInstanceMutex candidate(race_name.c_str());
    const bool acquired = candidate.Wait(100);
    if (acquired) ++entered;
    ++finished_wait;
    if (acquired) WaitForSingleObject(release_winner, INFINITE);
  };
  std::thread first;
  std::thread second;
  {
    fushi::SingleInstanceMutex old(race_name.c_str());
    Check(old.owns(), "race old owner acquired");
    Check(old.Wait(0), "owner wait is idempotent");
    race_handle = OpenMutexW(SYNCHRONIZE, FALSE, race_name.c_str());
    Check(race_handle != nullptr, "retain race object identity");
    first = std::thread(compete);
    second = std::thread(compete);
  }
  SetEvent(gate);
  const ULONGLONG deadline = GetTickCount64() + 5000;
  while (finished_wait.load() < 2 && GetTickCount64() < deadline) Sleep(1);
  Check(finished_wait == 2 && entered == 1, "only one concurrent successor enters");
  SetEvent(release_winner);
  first.join();
  second.join();
  {
    fushi::SingleInstanceMutex next(race_name.c_str());
    Check(next.owns(), "normal destructor releases for later launch");
  }

  // Name collision with another kernel object makes CreateMutex fail. It must
  // stay invalid/non-owning, never silently opt out of the guard.
  fushi::SingleInstanceMutex invalid(ready_name.c_str());
  Check(!invalid.valid() && !invalid.owns() && !invalid.Wait(0),
        "creation failure never grants ownership");
  fushi::SingleInstanceMutex disabled(name.c_str(), false);
  Check(!disabled.valid() && !disabled.owns(), "test runner opt-out owns no mutex");
  CloseHandle(child.hThread);
  CloseHandle(child.hProcess);
  CloseHandle(ready);
  CloseHandle(gate);
  CloseHandle(release_winner);
  CloseHandle(race_handle);
  std::cout << "PASS: live owner, non-owner cleanup, process-exit takeover, "
               "concurrent successors, normal release, creation failure, test opt-out\n";
  return 0;
}
