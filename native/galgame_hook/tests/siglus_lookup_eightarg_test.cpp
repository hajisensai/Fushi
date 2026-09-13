#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../hook/adapters/siglus_lookup.h"
#include "../hook/adapters/siglus_eightarg_lookup_family.h"
#include "../hook/adapters/siglus_eightarg_owner.h"
#include "../hook/geometry_provider_registry.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <thread>

namespace {
using namespace fushi_voice_hook;
unsigned checks = 0;
void Check(bool condition) {
  ++checks;
  if (!condition) { std::fprintf(stderr, "check %u failed\n", checks); std::exit(91); }
}
constexpr uint32_t kBase = 0x400000, kRoot = 0x2000000;
constexpr uint32_t kEngine = kRoot + 0xa476b0, kContainer = 0x4000000;
constexpr uint32_t kBody = 0x5000000, kSurface = 0x6000000, kGlyph = 0x7000000;
const HWND kWindow = reinterpret_cast<HWND>(uintptr_t{0x550012});
const siglus_eightarg_message::Owner kBodyIdentity{kBody, 0, kSurface,
                                                 kSurface + 0x124, kSurface};
struct Memory {
  std::map<uint32_t, uint8_t> bytes;
  size_t reads = 0, fail_on = 0, change_on = 0;
  std::function<void()> change;
  template<class T> void Put(uint32_t address, T value) {
    const auto* source = reinterpret_cast<const uint8_t*>(&value);
    for (size_t i = 0; i < sizeof(T); ++i) bytes[address + static_cast<uint32_t>(i)] = source[i];
  }
} memory;
bool ReadSiglusLegacyMemory(void*, uint32_t address, void* output, size_t size) {
  ++memory.reads;
  if (memory.change_on == memory.reads) memory.change();
  if (memory.fail_on == memory.reads) return false;
  for (size_t i = 0; i < size; ++i) {
    const auto item = memory.bytes.find(address + static_cast<uint32_t>(i));
    if (item == memory.bytes.end()) return false;
    static_cast<uint8_t*>(output)[i] = item->second;
  }
  return true;
}
bool window_valid = true;
DWORD window_process = 77;
HMODULE TestGetModuleHandleW(LPCWSTR) { return reinterpret_cast<HMODULE>(uintptr_t{kBase}); }
BOOL TestIsWindow(HWND window) { return window_valid && window == kWindow; }
DWORD TestGetWindowThreadProcessId(HWND, DWORD* process) { *process = window_process; return 13; }
DWORD TestGetCurrentProcessId() { return 77; }
SiglusLookupProfile active_profile;
bool profile_available = true;
const SiglusLookupProfile* ActiveSiglusLookupProfile() { return profile_available ? &active_profile : nullptr; }
SharedHeader* g_header = nullptr;
uint64_t g_siglus_lookup_glyph_processed_seq = 0;
uint32_t g_siglus_lookup_active_line_units = 0;
SiglusLookupTextIdentity g_siglus_lookup_text_identity;
unsigned resets = 0;
// The transport/reset implementation has its own production-worker harness.
// This seam deliberately advances the frontier, so Sync must preserve it.
void ResetSiglusLookupRuntimeLayout() { ++resets; g_siglus_lookup_glyph_processed_seq = 999; }
void InvalidateSiglusLookupClickTarget() {}
#define GetModuleHandleW TestGetModuleHandleW
#define IsWindow TestIsWindow
#define GetWindowThreadProcessId TestGetWindowThreadProcessId
#define GetCurrentProcessId TestGetCurrentProcessId
#include "../hook/adapters/siglus_lookup_eightarg.inc"
#undef GetModuleHandleW
#undef IsWindow
#undef GetWindowThreadProcessId
#undef GetCurrentProcessId

void Seed(bool populated = true) {
  memory = {}; window_valid = true; window_process = 77;
  profile_available = true; active_profile = {};
  active_profile.glyph_abi = SiglusGlyphLayoutAbi::kEcxEightArguments;
  active_profile.viewport_width = 1280; active_profile.viewport_height = 720;
  g_siglus_eightarg_occurrence.store(0);
  g_siglus_eightarg_worker_occurrence = 0;
  g_siglus_eightarg_thread_occurrence = 0;
  g_siglus_eightarg_thread_body = {};
  g_siglus_eightarg_binding = {};
  g_siglus_lookup_glyph_processed_seq = 7;
  g_siglus_lookup_active_line_units = 3;
  g_siglus_lookup_text_identity = {99, 88}; resets = 0;
  g_siglus_eightarg_sites = {};
  auto& s = g_siglus_eightarg_sites.input;
  using S = siglus_eightarg_input_viewport::Sites;
  constexpr uintptr_t S::* members[] = {&S::root_slot, &S::config_slot,
      &S::owner_slot, &S::window_slot, &S::input_slot, &S::current_input_slot,
      &S::prior_input_slot, &S::viewport_slot, &S::gate2_slot, &S::gate3_slot,
      &S::manager_slot, &S::scene_slot};
  const uint32_t pointers[] = {kRoot, kRoot + 0x54, kEngine, kEngine + 0x178,
      kEngine + 0x35ad4, kEngine + 0x3939c, kEngine + 0x3b000,
      kEngine + 0x3cca0, kEngine + 0x3d124, kEngine + 0x4296c,
      kEngine + 0x3d174, kEngine + 0x42898};
  for (uint32_t i = 0; i < 12; ++i) {
    s.*members[i] = 0x1000 + i * 4;
    memory.Put(kBase + 0x1000 + i * 4, pointers[i]);
  }
  s.window_vtable = 0x9000; s.window_handler = 0xa000;
  memory.Put(kEngine + 0x178, kBase + 0x9000);
  memory.Put(kBase + 0x9004, kBase + 0xa000);
  memory.Put(kEngine + 0x17c, uint32_t{0x550012});
  memory.Put(kRoot + 0x54 + 0x64, int32_t{1280});
  memory.Put(kRoot + 0x54 + 0x68, int32_t{720});
  memory.Put(kEngine + 0x3cca8, int32_t{1280});
  memory.Put(kEngine + 0x3ccac, int32_t{720});
  memory.Put(kEngine + 0x3ccb0, int32_t{37});
  memory.Put(kEngine + 0x3ccb4, int32_t{19});
  memory.Put(kEngine + 0x3ccc0, int32_t{960});
  memory.Put(kEngine + 0x3ccc4, int32_t{540});
  memory.Put(kEngine + 0x3cca0 + 0xb4, uint8_t{0});
  memory.Put(kEngine + 0x3d124 + 2, uint8_t{0});
  memory.Put(kEngine + 0x4296c + 0x138, uint8_t{0});
  memory.Put(kEngine + 0x4293c, kContainer);
  memory.Put(kContainer + 0x734 + 0x3b8, kBody);
  memory.Put(kContainer + 0x734 + 0x3bc, kBody + 0x1630);
  memory.Put(kContainer + 0x734 + 0x3c0, kBody + 0x1630);
  memory.Put(kBody + 0x160, uint32_t{0});
  memory.Put(kBody + 0x1a8, kSurface);
  memory.Put(kBody + 0x1ac, kSurface + 0x124);
  memory.Put(kBody + 0x156, uint8_t{1});
  memory.Put(kBody + 0x18c, int32_t{-1});
  memory.Put(kSurface + 0x118, kGlyph);
  memory.Put(kSurface + 0x11c, populated ? kGlyph + 0x3b4 : kGlyph);
  memory.Put(kSurface + 0x120, kGlyph + 0x3b4);
}
uint64_t Bind() {
  const auto occurrence = BeginSiglusEightArgOccurrence();
  QueueSiglusEightArgObservedBody(occurrence, kBodyIdentity);
  Check(BindSiglusEightArgText(occurrence, kBodyIdentity, {31, 41}));
  return occurrence;
}
bool View() { SiglusLookupEngineView view; return ReadSiglusEightArgView(kWindow, active_profile, &view); }
bool Owned() { return IsSiglusEightArgGlyphOwned(reinterpret_cast<void*>(uintptr_t{kGlyph})); }

void TestConstructionAndBatchSwitch() {
  Seed(false); const auto first = Bind();
  Check(g_siglus_eightarg_worker_occurrence == first && resets == 1);
  Check(g_siglus_lookup_glyph_processed_seq == 7 && g_siglus_lookup_active_line_units == 0);
  Check(g_siglus_lookup_text_identity.event_id == 0);
  SiglusEightArgBinding binding;
  Check(ReadSiglusEightArgBinding(&binding) && binding.identity.event_id == 31);
  Check(!View() && !Owned()); // Scenario has not appended a glyph yet.
  memory.Put(kSurface + 0x11c, kGlyph + 0x3b4);
  Check(View() && Owned());
  SiglusLookupEngineView view;
  Check(ReadSiglusEightArgView(kWindow, active_profile, &view));
  Check(view.occurrence == first && view.owner == kEngine && view.viewport.width == 960);
  SyncSiglusEightArgOccurrence(); Check(resets == 1 && View());
  const auto second = BeginSiglusEightArgOccurrence();
  Check(second != first && !ReadSiglusEightArgBinding(&binding) && !Owned() && !View());
  QueueSiglusEightArgObservedBody(first, kBodyIdentity); Check(!Owned());
  Check(!BindSiglusEightArgText(first, kBodyIdentity, {31, 41}));
  QueueSiglusEightArgObservedBody(second, kBodyIdentity);
  Check(Owned()); // Initial glyph may precede the worker's committed text.
  Check(BindSiglusEightArgText(second, kBodyIdentity, {32, 41}));
  Check(resets == 2 && g_siglus_lookup_glyph_processed_seq == 7);
  SyncSiglusEightArgOccurrence(); Check(resets == 2 && View());
  Check(ReadSiglusEightArgBinding(&binding) && binding.identity.event_id == 32);
}

void TestAdmissionFailuresAndTls() {
  Seed(); Bind();
  // A real SRW writer on another thread, not a mocked successful lock.
  std::atomic<bool> held{false}, release{false};
  std::thread writer([&] {
    AcquireSRWLockExclusive(&g_siglus_eightarg_binding_lock);
    held.store(true, std::memory_order_release);
    while (!release.load(std::memory_order_acquire)) std::this_thread::yield();
    ReleaseSRWLockExclusive(&g_siglus_eightarg_binding_lock);
  });
  while (!held.load(std::memory_order_acquire)) std::this_thread::yield();
  SiglusEightArgBinding binding;
  Check(!ReadSiglusEightArgBinding(&binding) && !View());
  release.store(true, std::memory_order_release); writer.join(); Check(View());
  bool inherited = true;
  std::thread renderer([&] { inherited = Owned(); }); renderer.join();
  Check(!inherited && Owned());
  window_valid = false; Check(!View()); window_valid = true;
  window_process = 78; Check(!View()); window_process = 77;
  memory.Put(kEngine + 0x17c, uint32_t{0x660012}); Check(!View());
  memory.Put(kEngine + 0x17c, uint32_t{0x550012}); Check(View());
  for (uint32_t offset : {0x3cca0u + 0xb4u, 0x3d124u + 2u, 0x4296cu + 0x138u}) {
    memory.Put(kEngine + offset, uint8_t{1}); Check(!View());
    memory.Put(kEngine + offset, uint8_t{0}); Check(View());
  }
  memory.Put(kBody + 0x156, uint8_t{0}); Check(!View() && !Owned());
  memory.Put(kBody + 0x18c, int32_t{0}); Check(View() && Owned());
  memory.Put(kBody + 0x160, uint32_t{1}); Check(!View() && !Owned());
  memory.Put(kBody + 0x160, uint32_t{0}); Check(View());
  memory.Put(kEngine + 0x4293c, kContainer + 4); Check(!View() && !Owned());
  memory.Put(kEngine + 0x4293c, kContainer);
  Check(ReadSiglusEightArgBinding(&binding) && binding.identity.event_id == 31);
}

void TestReadFailuresAndConcurrentOccurrence() {
  Seed(); Bind(); memory.reads = 0; Check(View()); const size_t view_reads = memory.reads;
  Seed(); Bind(); memory.reads = 0;
  siglus_eightarg_runtime::Snapshot snapshot;
  Check(ReadSiglusEightArgSnapshot(&snapshot)); const size_t snapshot_reads = memory.reads;
  memory.reads = 0; memory.change_on = snapshot_reads / 2 + 1;
  memory.change = [] { memory.Put(kEngine + 0x17c, uint32_t{0x660012}); };
  Check(!View()); // A HWND changed between two otherwise valid snapshots.
  Seed(); Bind(); memory.reads = 0; memory.change_on = view_reads;
  memory.change = [] { memory.Put(kSurface + 0x120, kGlyph + 2 * 0x3b4); };
  Check(!View()); // Both glyph vectors are valid, but they are not one snapshot.
  SiglusEightArgBinding preserved;
  Check(ReadSiglusEightArgBinding(&preserved) && preserved.identity.event_id == 31);
  for (size_t fail = 1; fail <= view_reads; ++fail) {
    Seed(); Bind(); memory.reads = 0; memory.fail_on = fail;
    Check(!View()); Check(memory.reads == fail);
  }
  Seed(); Bind(); memory.reads = 0;
  memory.change_on = view_reads;
  memory.change = [] { BeginSiglusEightArgOccurrence(); };
  Check(!View()); // Both memory passes succeed, but the final occurrence does not.
  Seed(); const auto occurrence = BeginSiglusEightArgOccurrence();
  SyncSiglusEightArgOccurrence(); memory.reads = 0;
  Check(BindSiglusEightArgText(occurrence, kBodyIdentity, {31, 41}));
  const size_t bind_reads = memory.reads;
  for (size_t fail = 1; fail <= bind_reads; ++fail) {
    Seed(); const auto current = BeginSiglusEightArgOccurrence();
    memory.fail_on = fail;
    Check(!BindSiglusEightArgText(current, kBodyIdentity, {31, 41}));
    SiglusEightArgBinding binding; Check(!ReadSiglusEightArgBinding(&binding));
  }
  Seed(); const auto current = BeginSiglusEightArgOccurrence();
  memory.change_on = bind_reads;
  memory.change = [] { BeginSiglusEightArgOccurrence(); };
  Check(!BindSiglusEightArgText(current, kBodyIdentity, {31, 41}));
  for (SiglusLookupTextIdentity invalid : {SiglusLookupTextIdentity{0, 41}, {31, 0}}) {
    Seed(); const auto active = BeginSiglusEightArgOccurrence();
    Check(!BindSiglusEightArgText(active, kBodyIdentity, invalid));
    Check(memory.reads == 0);
  }
  Seed(); profile_available = false;
  Check(!BindSiglusEightArgText(BeginSiglusEightArgOccurrence(), kBodyIdentity, {31, 41}));
}
} // namespace
int main() {
  TestConstructionAndBatchSwitch();
  TestAdmissionFailuresAndTls();
  TestReadFailuresAndConcurrentOccurrence();
  std::printf("siglus_lookup_eightarg: %u checks passed\n", checks);
}
