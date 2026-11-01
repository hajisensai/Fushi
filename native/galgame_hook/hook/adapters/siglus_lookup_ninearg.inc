// Nine-argument family runtime. Sites are immutable once admission publishes
// the profile pointer; every live read is bounded and SEH-protected.
namespace siglus_ninearg = fushi_voice_hook::siglus_ninearg;
namespace siglus_ninearg_live = fushi_voice_hook::siglus_ninearg_runtime;
namespace siglus_ninearg_owner = fushi_voice_hook::siglus_ninearg_owner;
siglus_ninearg::Sites g_siglus_ninearg_sites;
SRWLOCK g_siglus_ninearg_owner_lock = SRWLOCK_INIT;
fushi_voice_hook::siglus_legacy_owner::Snapshot g_siglus_ninearg_owner_snapshot;

bool IsNineArgSiglusLookup(const fushi_voice_hook::SiglusLookupProfile& profile) {
  return profile.glyph_abi ==
      fushi_voice_hook::SiglusGlyphLayoutAbi::kStackNineArguments;
}

bool ReadSiglusNineArgSnapshot(siglus_ninearg_live::Snapshot* snapshot) {
  return siglus_ninearg_live::ReadSnapshot(
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr)),
      g_siglus_ninearg_sites, ReadSiglusLegacyMemory, nullptr, snapshot);
}

// The engine's own visibility/input predicates and the window/design identity
// gate input; there is no separate render-block slot in this generation.
bool ReadSiglusNineArgView(HWND game,
                           const fushi_voice_hook::SiglusLookupProfile& profile,
                           fushi_voice_hook::SiglusLookupEngineView* view) {
  DWORD window_process = 0;
  if (game == nullptr || GetWindowThreadProcessId(game, &window_process) == 0 ||
      window_process != GetCurrentProcessId()) return false;
  siglus_ninearg_live::Snapshot snapshot;
  if (!ReadSiglusNineArgSnapshot(&snapshot) || !snapshot.dialogue_input_allowed ||
      snapshot.window_handle != reinterpret_cast<uintptr_t>(game) ||
      !IsWindow(game) || snapshot.design_width != profile.viewport_width ||
      snapshot.design_height != profile.viewport_height) return false;
  view->owner = snapshot.owner;
  view->viewport = {snapshot.viewport.x, snapshot.viewport.y,
                    snapshot.viewport.width, snapshot.viewport.height};
  return true;
}

bool RefreshSiglusNineArgGlyphOwners() {
  const uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  auto read = [](uint32_t address, void* output, size_t bytes) {
    return ReadSiglusLegacyMemory(nullptr, address, output, bytes);
  };
  fushi_voice_hook::siglus_legacy_owner::Snapshot next;
  const bool valid = siglus_ninearg_owner::BuildSnapshot(
      static_cast<uint32_t>(base + g_siglus_ninearg_sites.config_slot),
      static_cast<uint32_t>(base + g_siglus_ninearg_sites.owner_slot),
      read, &next);
  return fushi_voice_hook::siglus_legacy_owner::PublishSnapshot(
      next, valid, &g_siglus_ninearg_owner_snapshot,
      [] { return TryAcquireSRWLockExclusive(&g_siglus_ninearg_owner_lock) != 0; },
      [] { ReleaseSRWLockExclusive(&g_siglus_ninearg_owner_lock); });
}

bool IsSiglusNineArgGlyphOwned(void* self) {
  if (!TryAcquireSRWLockShared(&g_siglus_ninearg_owner_lock)) return false;
  auto read = [](uint32_t address, void* output, size_t bytes) {
    return ReadSiglusLegacyMemory(nullptr, address, output, bytes);
  };
  const bool owned = siglus_ninearg_owner::ContainsCurrentGlyph(
      g_siglus_ninearg_owner_snapshot, reinterpret_cast<uint32_t>(self), read);
  ReleaseSRWLockShared(&g_siglus_ninearg_owner_lock);
  return owned;
}
