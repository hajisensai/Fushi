#ifdef NDEBUG
#undef NDEBUG
#endif
#define NOMINMAX
#include <windows.h>
#include "generic_input_shield.h"
#include "voice_hook_ipc.h"
#include "../hook/adapters/siglus_lookup.h"
#include <array>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static_assert(sizeof(void*) == 4, "Exercise the real x86 Siglus installation policy");
namespace {
enum class Identity { kPending, kResolving, kModernLuna, kModernNative, kLegacy,
                      kRejected, kOtherEngine };
enum Export : size_t { kKey, kAsync, kTable, kRawData, kRawBuffer, kExportCount };
enum class Owner { kNone, kGeneric, kExact };
Identity identity = Identity::kOtherEngine;
fushi_voice_hook::SiglusLookupProfile test_profile;
bool leaf_matched = false, leaf_pending = false, hunex_matched = false;
bool user32_loaded = true;
std::array<int, kExportCount> export_tokens{}, trampoline_tokens{};
std::array<Owner, kExportCount> owners{};
std::array<unsigned, kExportCount> hook_calls{};
std::array<void*, kExportCount> installed_detours{}, exact_originals{};
Owner installing = Owner::kGeneric;
unsigned duplicate_calls = 0;
void* g_generic_get_key_state_original = nullptr;
void* g_generic_get_async_key_state_original = nullptr;
void* g_generic_get_keyboard_state_original = nullptr;
void* g_generic_get_raw_input_data_original = nullptr;
void* g_generic_get_raw_input_buffer_original = nullptr;
constexpr uint32_t kGenericKeyCoverageGetKeyState = 1;
constexpr uint32_t kGenericKeyCoverageGetAsyncKeyState = 2;
constexpr uint32_t kGenericKeyCoverageGetKeyboardState = 4;
constexpr uint32_t kGenericKeyCoverageAll = 7;
std::atomic<uint32_t> g_generic_key_coverage{0};
std::atomic<uint32_t> g_generic_shield_fault_mask{0};
std::atomic<uint32_t> g_generic_shield_ready_mask{0};

bool IsSiglusLookupProfileMatched() {
  return identity == Identity::kModernLuna || identity == Identity::kModernNative ||
      identity == Identity::kLegacy;
}
bool IsSiglusLookupIdentityUndecided() {
  return identity == Identity::kPending || identity == Identity::kResolving;
}
const fushi_voice_hook::SiglusLookupProfile* ActiveSiglusLookupProfile() {
  return IsSiglusLookupProfileMatched() ? &test_profile : nullptr;
}
bool IsLeafAquaplusProfileMatched() { return leaf_matched; }
bool IsLeafAquaplusIdentityUndecided() { return leaf_pending; }
bool IsHunexGgeProfileMatched() { return hunex_matched; }
void Detour_GenericGetKeyState() {}
void Detour_GenericGetAsyncKeyState() {}
void Detour_GenericGetKeyboardState() {}
void Detour_GenericGetRawInputData() {}
void Detour_GenericGetRawInputBuffer() {}
void ExactDetour() {}
HMODULE TestGetModuleHandleW(LPCWSTR name) {
  assert(wcscmp(name, L"user32.dll") == 0);
  return user32_loaded ? reinterpret_cast<HMODULE>(&export_tokens) : nullptr;
}
FARPROC TestGetProcAddress(HMODULE module, LPCSTR name) {
  assert(module == reinterpret_cast<HMODULE>(&export_tokens));
  const char* names[] = {"GetKeyState", "GetAsyncKeyState", "GetKeyboardState",
                         "GetRawInputData", "GetRawInputBuffer"};
  for (size_t i = 0; i < kExportCount; ++i)
    if (strcmp(names[i], name) == 0) return reinterpret_cast<FARPROC>(&export_tokens[i]);
  assert(false); return nullptr;
}
size_t Index(void* target) {
  for (size_t i = 0; i < kExportCount; ++i)
    if (target == &export_tokens[i]) return i;
  assert(false); return 0;
}
bool IsHookTargetTrackedByThisDll(void* target) {
  return target && owners[Index(target)] != Owner::kNone;
}
// Mock only the hooking boundary: its already-tracked outcome reproduces the
// production HookFn contract (success without supplying another trampoline).
bool HookFn(void* target, void* detour, void** original) {
  assert(target && detour && original);
  const auto index = Index(target);
  ++hook_calls[index];
  if (owners[index] != Owner::kNone) { ++duplicate_calls; return true; }
  owners[index] = installing; installed_detours[index] = detour;
  *original = &trampoline_tokens[index]; return true;
}

#define GetModuleHandleW TestGetModuleHandleW
#define GetProcAddress TestGetProcAddress
#include "generic_input_shield_install_production.inc"
#undef GetProcAddress
#undef GetModuleHandleW

void SetIdentity(Identity value) {
  identity = value; test_profile = {};
  test_profile.glyph_abi = value == Identity::kLegacy
      ? fushi_voice_hook::SiglusGlyphLayoutAbi::kStackSixteenArguments
      : fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxTenArguments;
  test_profile.text_feed = value == Identity::kModernNative
      ? fushi_voice_hook::SiglusLookupTextFeed::kNativeEcxTextUnion
      : fushi_voice_hook::SiglusLookupTextFeed::kLunaScenarioLane;
}
void Reset(Identity value) {
  SetIdentity(value);
  leaf_matched = leaf_pending = hunex_matched = false; user32_loaded = true;
  owners = {}; hook_calls = {}; installed_detours = {}; exact_originals = {};
  duplicate_calls = 0; installing = Owner::kGeneric;
  g_generic_get_key_state_original = g_generic_get_async_key_state_original = nullptr;
  g_generic_get_keyboard_state_original = g_generic_get_raw_input_data_original = nullptr;
  g_generic_get_raw_input_buffer_original = nullptr;
  g_generic_key_coverage = 0; g_generic_shield_fault_mask = 0; g_generic_shield_ready_mask = 0;
}
void ExactOwn(Export surface) {
  installing = Owner::kExact;
  assert(HookFn(&export_tokens[surface], reinterpret_cast<void*>(&ExactDetour),
                &exact_originals[surface]));
  installing = Owner::kGeneric;
  assert(owners[surface] == Owner::kExact && exact_originals[surface] != nullptr);
}
void CheckRawUnaffected() {
  assert(owners[kRawData] == Owner::kGeneric && owners[kRawBuffer] == Owner::kGeneric);
  assert(hook_calls[kRawData] == 1 && hook_calls[kRawBuffer] == 1);
}
void CheckNoDuplicateOrFault() {
  assert(duplicate_calls == 0 && g_generic_shield_fault_mask.load() == 0);
}
void TestPendingFirst() {
  for (auto state : {Identity::kPending, Identity::kResolving}) {
    Reset(state); assert(ShouldReserveSiglusKeyboardState());
    TryInstallGenericKeyAndRawInputShield();
    assert(owners[kKey] == Owner::kNone && owners[kTable] == Owner::kNone);
    assert(!g_generic_get_key_state_original && !g_generic_get_keyboard_state_original);
    assert(owners[kAsync] == Owner::kGeneric);
    assert(g_generic_key_coverage == kGenericKeyCoverageGetAsyncKeyState);
    CheckRawUnaffected(); CheckNoDuplicateOrFault();
  }
}
void TestPendingToBothModernFamilies() {
  for (auto state : {Identity::kModernLuna, Identity::kModernNative}) {
    Reset(Identity::kPending); TryInstallGenericKeyAndRawInputShield();
    SetIdentity(state); TryInstallGenericKeyAndRawInputShield();
    assert(owners[kKey] == Owner::kNone && owners[kTable] == Owner::kGeneric);
    assert(g_generic_get_keyboard_state_original == &trampoline_tokens[kTable]);
    assert(installed_detours[kTable] == reinterpret_cast<void*>(&Detour_GenericGetKeyboardState));
    ExactOwn(kKey); TryInstallGenericKeyAndRawInputShield();
    assert(g_generic_key_coverage == kGenericKeyCoverageAll);
    CheckRawUnaffected(); CheckNoDuplicateOrFault();
  }
}
void TestPendingToLegacyWithoutLookup() {
  Reset(Identity::kPending); TryInstallGenericKeyAndRawInputShield();
  SetIdentity(Identity::kLegacy);
  for (unsigned i = 0; i < 4; ++i) TryInstallGenericKeyAndRawInputShield();
  assert(owners[kKey] == Owner::kNone && owners[kTable] == Owner::kNone);
  assert(hook_calls[kKey] == 0 && hook_calls[kTable] == 0);
  // Later enabling exact lookup must still receive both original trampolines.
  ExactOwn(kKey); ExactOwn(kTable); TryInstallGenericKeyAndRawInputShield();
  assert(g_generic_key_coverage == kGenericKeyCoverageAll);
  CheckRawUnaffected(); CheckNoDuplicateOrFault();
}
void TestExactInstalledBeforeGeneric() {
  Reset(Identity::kLegacy); ExactOwn(kKey); ExactOwn(kTable);
  TryInstallGenericKeyAndRawInputShield();
  assert(hook_calls[kKey] == 1 && hook_calls[kTable] == 1);
  assert(!g_generic_get_key_state_original && !g_generic_get_keyboard_state_original);
  assert(installed_detours[kKey] == reinterpret_cast<void*>(&ExactDetour));
  assert(installed_detours[kTable] == reinterpret_cast<void*>(&ExactDetour));
  assert(g_generic_key_coverage == kGenericKeyCoverageAll);
  CheckNoDuplicateOrFault();
}
void TestRejectedAndOtherEngine() {
  for (auto state : {Identity::kRejected, Identity::kOtherEngine}) {
    Reset(Identity::kPending); TryInstallGenericKeyAndRawInputShield();
    SetIdentity(state); TryInstallGenericKeyAndRawInputShield();
    for (size_t i = 0; i < kExportCount; ++i) assert(owners[i] == Owner::kGeneric);
    assert(g_generic_key_coverage == kGenericKeyCoverageAll);
    assert(g_generic_get_key_state_original && g_generic_get_keyboard_state_original);
    CheckRawUnaffected(); CheckNoDuplicateOrFault();
  }
}
void TestPollingAndUnrelatedReservations() {
  for (unsigned other = 0; other < 3; ++other) {
    Reset(Identity::kOtherEngine);
    leaf_pending = other == 0; leaf_matched = other == 1; hunex_matched = other == 2;
    TryInstallGenericKeyAndRawInputShield();
    assert(owners[kKey] == Owner::kGeneric && owners[kTable] == Owner::kGeneric);
    assert(owners[kAsync] == Owner::kNone);
    ExactOwn(kAsync);
    for (unsigned i = 0; i < 20; ++i) TryInstallGenericKeyAndRawInputShield();
    for (size_t i = 0; i < kExportCount; ++i) assert(hook_calls[i] == 1);
    assert(g_generic_key_coverage == kGenericKeyCoverageAll);
    CheckRawUnaffected(); CheckNoDuplicateOrFault();
  }
  Reset(Identity::kPending); user32_loaded = false;
  TryInstallGenericKeyAndRawInputShield();
  for (auto calls : hook_calls) assert(calls == 0);
  user32_loaded = true; SetIdentity(Identity::kLegacy);
  TryInstallGenericKeyAndRawInputShield();
  assert(owners[kKey] == Owner::kNone && owners[kTable] == Owner::kNone);
}
}  // namespace
int main() {
  _set_error_mode(_OUT_TO_STDERR);
  _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);
  TestPendingFirst(); TestPendingToBothModernFamilies();
  TestPendingToLegacyWithoutLookup(); TestExactInstalledBeforeGeneric();
  TestRejectedAndOtherEngine(); TestPollingAndUnrelatedReservations();
  std::puts("Generic shield install: six production-path ordering scenarios passed");
}
