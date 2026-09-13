// SPDX-License-Identifier: LGPL-3.0-or-later
// Exercise the actual integration hooks with a fault-injectable patch backend.
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
constexpr LONG STATUS_SUCCESS = 0;
constexpr LONG STATUS_PROCEDURE_NOT_FOUND = -1;
constexpr LONG kPatchFailure = -2;
constexpr LONG kRestoreFailure = -3;
#define NT_FAILED(status) ((status) < 0)
#define countof(value) (sizeof(value) / sizeof((value)[0]))
struct LeGlobalData {
  BOOL ProcessOwnedMapping = FALSE;
  struct {
    BOOL (WINAPI* StubGetFileVersionInfoW)(LPCWSTR, DWORD, DWORD, LPVOID) = nullptr;
    BOOL (WINAPI* StubGetFileVersionInfoExW)(DWORD, LPCWSTR, DWORD, DWORD, LPVOID) = nullptr;
  } HookStub;
  struct Locale { DWORD LocaleID = 0x411; } locale;
  Locale* GetLeb() { return &locale; }
  LONG HookVersionRoutines(PVOID);
  LONG UnHookVersionRoutines();
};
using PLeGlobalData = LeGlobalData*;
using NTSTATUS = LONG;
LeGlobalData test_global;
PLeGlobalData LeGetGlobalData() { return &test_global; }
bool exports_present = true;
bool fail_patch = false;
bool fail_restore_basic = false;
int patches_applied = 0;
char basic_export;
char extended_export;
char __ImageBase;
constexpr ULONG LDR_ADDREF_DLL_PIN = 1;
bool fail_pin = false;
bool fail_self_pin = false;
LONG LdrAddRefDll(ULONG flags, PVOID module) {
  return flags != LDR_ADDREF_DLL_PIN || fail_pin ||
      (module == &__ImageBase && fail_self_pin) ? kPatchFailure : STATUS_SUCCESS;
}
BOOL WINAPI Basic(LPCWSTR, DWORD, DWORD, LPVOID) { return FALSE; }
BOOL WINAPI Extended(DWORD, LPCWSTR, DWORD, DWORD, LPVOID) { return FALSE; }
PVOID LookupExportTable(PVOID, const char* name) {
  if (!exports_present) return nullptr;
  return std::strcmp(name, "GetFileVersionInfoW") == 0
      ? &basic_export : &extended_export;
}
namespace Mp {
struct PATCH_MEMORY_DATA { void (*apply)(); };
void ApplyBasic() { test_global.HookStub.StubGetFileVersionInfoW = Basic; }
void ApplyExtended() { test_global.HookStub.StubGetFileVersionInfoExW = Extended; }
template <typename T>
PATCH_MEMORY_DATA FunctionJumpVa(PVOID original, T, T*) {
  return {original == &basic_export ? ApplyBasic : ApplyExtended};
}
LONG PatchMemory(PATCH_MEMORY_DATA* patches, size_t size) {
  ++patches_applied;
  for (size_t i = 0; i < size; ++i) {
    patches[i].apply();
    if (fail_patch) return kPatchFailure;
  }
  return STATUS_SUCCESS;
}
template <typename T>
LONG RestoreMemory(T& stub) {
  if (stub != nullptr && reinterpret_cast<PVOID>(&stub) ==
          reinterpret_cast<PVOID>(&test_global.HookStub.StubGetFileVersionInfoW) &&
      fail_restore_basic) return kRestoreFailure;
  stub = nullptr;
  return STATUS_SUCCESS;
}
}
#include "../third_party/locale_emulator/version_query_hooks.inc"
void Check(bool condition, const char* detail) {
  if (!condition) { std::fprintf(stderr, "%s\n", detail); std::exit(1); }
}
int main() {
  Check(test_global.HookVersionRoutines(nullptr) == 0, "install");
  Check(test_global.HookVersionRoutines(nullptr) == 0 && patches_applied == 1,
        "complete install is idempotent");
  fail_restore_basic = true;
  Check(test_global.UnHookVersionRoutines() == kRestoreFailure, "surface restore failure");
  Check(test_global.HookStub.StubGetFileVersionInfoW == Basic &&
        test_global.HookStub.StubGetFileVersionInfoExW == nullptr,
        "preserve only failed trampoline");
  Check(test_global.HookVersionRoutines(nullptr) == kRestoreFailure && patches_applied == 1,
        "partial state must not report installed or overwrite a trampoline");
  fail_restore_basic = false;
  Check(test_global.HookVersionRoutines(nullptr) == 0 && patches_applied == 2,
        "recover partial state after successful cleanup");
  Check(test_global.UnHookVersionRoutines() == 0, "remove complete installation");
  fail_patch = true;
  Check(test_global.HookVersionRoutines(nullptr) == kPatchFailure &&
        test_global.HookStub.StubGetFileVersionInfoW == nullptr, "rollback partial install");
  fail_restore_basic = true;
  Check(test_global.HookVersionRoutines(nullptr) == kRestoreFailure &&
        test_global.HookStub.StubGetFileVersionInfoW == Basic,
        "failed rollback retains trampoline and surfaces cleanup failure");
  fail_restore_basic = false;
  Check(test_global.UnHookVersionRoutines() == 0, "later cleanup");
  fail_patch = false;
  fail_pin = true;
  const int installed_before_pin_failure = patches_applied;
  Check(test_global.HookVersionRoutines(nullptr) == kPatchFailure &&
        patches_applied == installed_before_pin_failure, "pin failure must precede patching");
  fail_pin = false;
  fail_self_pin = true;
  Check(test_global.HookVersionRoutines(nullptr) == kPatchFailure,
        "loader-owned self pin must succeed");
  test_global.ProcessOwnedMapping = TRUE;
  Check(test_global.HookVersionRoutines(nullptr) == 0,
        "explicit process-owned mapping needs only version pin");
  Check(test_global.UnHookVersionRoutines() == 0, "process-owned cleanup");
  test_global.ProcessOwnedMapping = FALSE;
  fail_self_pin = false;
  exports_present = false;
  Check(test_global.HookVersionRoutines(nullptr) == STATUS_PROCEDURE_NOT_FOUND,
        "missing API rejected");
  unsigned char output[] = {1, 2, 3, 4};
  test_global.HookStub.StubGetFileVersionInfoW = Basic;
  test_global.HookStub.StubGetFileVersionInfoExW = Extended;
  Check(!LeGetFileVersionInfoW(L"x", 0, sizeof(output), output) &&
        !LeGetFileVersionInfoExW(0, L"x", 0, sizeof(output), output) &&
        output[0] == 1 && output[3] == 4, "failed APIs preserve caller buffer");
  std::puts("15 hook lifecycle/API checks passed");
}
