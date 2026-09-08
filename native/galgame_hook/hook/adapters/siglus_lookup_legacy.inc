// Legacy family runtime reads are small bounded copies. The profile and sites
// are immutable once admission publishes the profile pointer.
namespace siglus_legacy_input = fushi_voice_hook::siglus_legacy_input_viewport;
namespace siglus_legacy_live = fushi_voice_hook::siglus_legacy_runtime;
namespace siglus_legacy_owner = fushi_voice_hook::siglus_legacy_owner;
siglus_legacy_input::Sites g_siglus_legacy_input_sites;
fushi_voice_hook::LegacyGlyphSites g_siglus_legacy_glyph_sites;
siglus_legacy_owner::Sites g_siglus_legacy_owner_sites;
SRWLOCK g_siglus_legacy_owner_lock = SRWLOCK_INIT;
siglus_legacy_owner::Snapshot g_siglus_legacy_owner_snapshot;

bool IsLegacySiglusLookup(const fushi_voice_hook::SiglusLookupProfile& profile) {
  return profile.glyph_abi ==
      fushi_voice_hook::SiglusGlyphLayoutAbi::kStackSixteenArguments;
}

bool ReadSiglusLegacyMemory(void*, uint32_t address, void* output, size_t bytes) {
  if (output == nullptr || bytes == 0 || bytes > 16) return false;
  __try {
    const void* source = reinterpret_cast<const void*>(address);
    if (!fushi_voice_hook::exact_lookup::IsReadableSpan(source, bytes)) return false;
    memcpy(output, source, bytes);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

bool ReadSiglusLegacySnapshot(siglus_legacy_live::Snapshot* snapshot) {
  return siglus_legacy_live::ReadSnapshot(
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr)),
      g_siglus_legacy_input_sites, ReadSiglusLegacyMemory, nullptr, snapshot);
}

bool ReadSiglusLookupEngineView(HWND game,
                                 fushi_voice_hook::SiglusLookupEngineView* view) {
  if (view == nullptr) return false;
  *view = {};
  const auto* profile = ActiveSiglusLookupProfile();
  if (profile == nullptr) return false;
  if (!IsLegacySiglusLookup(*profile)) return true;
  DWORD window_process = 0;
  if (game == nullptr || GetWindowThreadProcessId(game, &window_process) == 0 ||
      window_process != GetCurrentProcessId()) return false;
  siglus_legacy_live::Snapshot snapshot;
  if (!ReadSiglusLegacySnapshot(&snapshot) || !snapshot.dialogue_input_allowed ||
      snapshot.window_handle != reinterpret_cast<uintptr_t>(game) ||
      !IsWindow(game) || snapshot.design_width != profile->viewport_width ||
      snapshot.design_height != profile->viewport_height) return false;
  auto read = [](uint32_t address, void* output, size_t bytes) {
    return ReadSiglusLegacyMemory(nullptr, address, output, bytes);
  };
  const uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  if (!siglus_legacy_owner::RenderAllowed(
          static_cast<uint32_t>(base + g_siglus_legacy_owner_sites.render_block_slot),
          read)) return false;
  view->owner = snapshot.owner;
  view->viewport = {snapshot.viewport.x, snapshot.viewport.y,
                   snapshot.viewport.width, snapshot.viewport.height};
  return true;
}

bool SiglusLookupViewAllowsInput(HWND game) {
  fushi_voice_hook::SiglusLookupEngineView view;
  return ReadSiglusLookupEngineView(game, &view);
}

bool RefreshSiglusLegacyGlyphOwners() {
  const auto* profile = ActiveSiglusLookupProfile();
  if (profile == nullptr) return false;
  if (!IsLegacySiglusLookup(*profile)) return true;
  const uintptr_t base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
  auto read = [](uint32_t address, void* output, size_t bytes) {
    return ReadSiglusLegacyMemory(nullptr, address, output, bytes);
  };
  siglus_legacy_owner::Snapshot next;
  const bool valid = siglus_legacy_owner::BuildSnapshot(
      static_cast<uint32_t>(base + g_siglus_legacy_owner_sites.config_slot),
      static_cast<uint32_t>(base + g_siglus_legacy_owner_sites.manager_slot),
      read, &next);
  return siglus_legacy_owner::PublishSnapshot(
      next, valid, &g_siglus_legacy_owner_snapshot,
      [] { return TryAcquireSRWLockExclusive(&g_siglus_legacy_owner_lock) != 0; },
      [] { ReleaseSRWLockExclusive(&g_siglus_legacy_owner_lock); });
}

bool IsSiglusLookupGlyphOwned(void* self) {
  const auto* profile = ActiveSiglusLookupProfile();
  if (profile == nullptr) return false;
  if (profile->glyph_abi ==
      fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxTenArguments) return true;
  // New ABI families must install their own occurrence-bound owner proof.
  if (!IsLegacySiglusLookup(*profile)) return false;
  if (!TryAcquireSRWLockShared(&g_siglus_legacy_owner_lock)) return false;
  auto read = [](uint32_t address, void* output, size_t bytes) {
    return ReadSiglusLegacyMemory(nullptr, address, output, bytes);
  };
  const bool owned = siglus_legacy_owner::ContainsCurrentGlyph(
      g_siglus_legacy_owner_snapshot, reinterpret_cast<uint32_t>(self), read);
  ReleaseSRWLockShared(&g_siglus_legacy_owner_lock);
  return owned;
}
