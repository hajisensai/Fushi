// Eight-argument runtime state. Included after the bounded memory reader.
namespace siglus_eightarg = fushi_voice_hook::siglus_eightarg_lookup_family;
namespace siglus_eightarg_live = fushi_voice_hook::siglus_eightarg_runtime;
namespace siglus_eightarg_owner = fushi_voice_hook::siglus_eightarg_owner;
namespace siglus_eightarg_message = fushi_voice_hook::siglus_eightarg_message;
siglus_eightarg::Sites g_siglus_eightarg_sites;
std::atomic<uint64_t> g_siglus_eightarg_occurrence{0};
uint64_t g_siglus_eightarg_worker_occurrence = 0;
__declspec(thread) uint64_t g_siglus_eightarg_thread_occurrence = 0;
__declspec(thread) siglus_eightarg_message::Owner g_siglus_eightarg_thread_body = {};
struct SiglusEightArgBinding {
  uint64_t occurrence = 0;
  fushi_voice_hook::SiglusLookupTextIdentity identity;
  siglus_eightarg_message::Owner body{};
};
SRWLOCK g_siglus_eightarg_binding_lock = SRWLOCK_INIT;
SiglusEightArgBinding g_siglus_eightarg_binding;

bool IsEightArgSiglusLookup(const fushi_voice_hook::SiglusLookupProfile& profile) {
  return profile.glyph_abi == fushi_voice_hook::SiglusGlyphLayoutAbi::kEcxEightArguments;
}
bool ReadSiglusEightArgSnapshot(siglus_eightarg_live::Snapshot* out) {
  return siglus_eightarg_live::ReadSnapshot(
      reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr)),
      g_siglus_eightarg_sites.input, ReadSiglusLegacyMemory, nullptr, out);
}
uint64_t BeginSiglusEightArgOccurrence() {
  g_siglus_eightarg_thread_occurrence = 0;
  g_siglus_eightarg_thread_body = {};
  return g_siglus_eightarg_occurrence.fetch_add(1, std::memory_order_acq_rel) + 1;
}
void QueueSiglusEightArgObservedBody(uint64_t occurrence,
                                   const siglus_eightarg_message::Owner& body) {
  if (occurrence == 0 || occurrence !=
      g_siglus_eightarg_occurrence.load(std::memory_order_acquire)) return;
  // The engine's rendering thread can observe initial glyphs before the worker
  // commits the copied text. TLS never exposes a partially written body.
  g_siglus_eightarg_thread_body = body;
  g_siglus_eightarg_thread_occurrence = occurrence;
}
bool ReadSiglusEightArgBinding(SiglusEightArgBinding* out) {
  if (!TryAcquireSRWLockShared(&g_siglus_eightarg_binding_lock)) return false;
  *out = g_siglus_eightarg_binding;
  ReleaseSRWLockShared(&g_siglus_eightarg_binding_lock);
  return out->occurrence != 0 && out->identity.event_id != 0 &&
      out->identity.thread_id != 0 && out->occurrence ==
          g_siglus_eightarg_occurrence.load(std::memory_order_acquire);
}
void SyncSiglusEightArgOccurrence();
bool BindSiglusEightArgText(uint64_t occurrence,
                          const siglus_eightarg_message::Owner& body,
                          fushi_voice_hook::SiglusLookupTextIdentity identity) {
  if (occurrence == 0 || identity.event_id == 0 || identity.thread_id == 0 ||
      occurrence != g_siglus_eightarg_occurrence.load(std::memory_order_acquire))
    return false;
  if (occurrence != g_siglus_eightarg_worker_occurrence) SyncSiglusEightArgOccurrence();
  if (occurrence != g_siglus_eightarg_worker_occurrence) return false;
  siglus_eightarg_live::Snapshot snapshot;
  siglus_eightarg_owner::Path path;
  if (!ReadSiglusEightArgSnapshot(&snapshot) ||
      !siglus_eightarg_owner::ReadSelectedBody(snapshot.owner, body,
          ReadSiglusLegacyMemory, nullptr, &path)) return false;
  AcquireSRWLockExclusive(&g_siglus_eightarg_binding_lock);
  const bool current = occurrence ==
      g_siglus_eightarg_occurrence.load(std::memory_order_acquire);
  if (current) g_siglus_eightarg_binding = {occurrence, identity, body};
  ReleaseSRWLockExclusive(&g_siglus_eightarg_binding_lock);
  return current;
}
bool ReadSiglusEightArgView(HWND game, const fushi_voice_hook::SiglusLookupProfile& profile,
                           fushi_voice_hook::SiglusLookupEngineView* view) {
  SiglusEightArgBinding binding;
  siglus_eightarg_live::Snapshot snapshot;
  siglus_eightarg_owner::Path path;
  DWORD process = 0;
  if (!game || !IsWindow(game) || !GetWindowThreadProcessId(game, &process) ||
      process != GetCurrentProcessId() || !ReadSiglusEightArgBinding(&binding) ||
      !ReadSiglusEightArgSnapshot(&snapshot) || !snapshot.input_allowed ||
      snapshot.window_handle != reinterpret_cast<uintptr_t>(game) ||
      snapshot.design_width != profile.viewport_width ||
      snapshot.design_height != profile.viewport_height ||
      !siglus_eightarg_owner::ReadPath(snapshot.owner, binding.body,
          ReadSiglusLegacyMemory, nullptr, &path) || binding.occurrence !=
          g_siglus_eightarg_occurrence.load(std::memory_order_acquire)) return false;
  view->owner = snapshot.owner;
  view->viewport = {snapshot.viewport_x, snapshot.viewport_y,
                   snapshot.viewport_width, snapshot.viewport_height};
  view->occurrence = binding.occurrence;
  return true;
}
bool ReadSiglusEightArgGlyphOrdinal(void* self, uint32_t* ordinal, uint32_t* count,
                                  siglus_eightarg_owner::Vector* vector = nullptr) {
  const uint64_t occurrence = g_siglus_eightarg_thread_occurrence;
  const uintptr_t address = reinterpret_cast<uintptr_t>(self);
  if (address > UINT32_MAX || occurrence == 0 || occurrence !=
      g_siglus_eightarg_occurrence.load(std::memory_order_acquire)) return false;
  siglus_eightarg_live::Snapshot snapshot;
  siglus_eightarg_owner::Path path;
  const bool owned = ReadSiglusEightArgSnapshot(&snapshot) &&
      siglus_eightarg_owner::ReadPath(snapshot.owner, g_siglus_eightarg_thread_body,
          ReadSiglusLegacyMemory, nullptr, &path) &&
      siglus_eightarg_owner::Contains(path.glyphs, static_cast<uint32_t>(address), 0x3b4) &&
      occurrence == g_siglus_eightarg_occurrence.load(std::memory_order_acquire);
  if (!owned) return false;
  *ordinal = (static_cast<uint32_t>(address) - path.glyphs.begin) / 0x3b4;
  *count = (path.glyphs.end - path.glyphs.begin) / 0x3b4;
  if (vector) *vector = path.glyphs;
  return true;
}
bool IsSiglusEightArgGlyphOwned(void* self) {
  uint32_t ordinal = 0, count = 0;
  return ReadSiglusEightArgGlyphOrdinal(self, &ordinal, &count);
}

void ResetSiglusLookupRuntimeLayout();
void InvalidateSiglusLookupClickTarget();
void SyncSiglusEightArgOccurrence() {
  const auto* profile = ActiveSiglusLookupProfile();
  if (!profile || !IsEightArgSiglusLookup(*profile)) return;
  const uint64_t occurrence = g_siglus_eightarg_occurrence.load(std::memory_order_acquire);
  if (occurrence == g_siglus_eightarg_worker_occurrence) return;
  g_siglus_eightarg_worker_occurrence = occurrence;
  AcquireSRWLockExclusive(&g_siglus_eightarg_binding_lock);
  g_siglus_eightarg_binding = {};
  ReleaseSRWLockExclusive(&g_siglus_eightarg_binding_lock);
  // Preserve unconsumed transport: each event carries its occurrence, so the
  // worker can discard old glyphs without discarding the new initial redraw.
  const uint64_t processed = g_siglus_lookup_glyph_processed_seq;
  ResetSiglusLookupRuntimeLayout();
  g_siglus_lookup_glyph_processed_seq = processed;
  g_siglus_lookup_active_line_units = 0;
  g_siglus_lookup_text_identity = {};
  fushi_voice_hook::g_geometry_provider_registry.Retire(g_header,
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout,
      fushi_voice_hook::kLookupGeometryProviderIdSiglus);
}
