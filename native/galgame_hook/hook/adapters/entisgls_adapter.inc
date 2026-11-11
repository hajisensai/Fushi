// EntisGLS adapter: the engine's message text lane (entisgls_text.inc);
// structural site resolution and every rule in entisgls_core.h.
//
// Identity is structural (entisgls_profile.h: the executable exports the
// Sakura2 VM syscall table and the message-window runtime classes).  The
// hook sites resolve only from the image's own code, read from disk so other
// in-process hookers and the loader's relocation cannot shift them.
//
// Not covered here (see engine-support.yaml known_limitations): voice (the
// engine mixes its own sound lines and plays through waveOut; no per-line
// resource or PCM producer is bound) and in-game lookup (no glyph-geometry
// provider and no input gate), so lookupAdmission() keeps the default
// EngineUnsupported.
#include "entisgls_profile.h"
#include "entisgls_text.inc"

class EntisglsAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "entisgls"; }
  // The identity is a property of the main executable: measured once, then
  // reused.  install() (startup) and diagnostics() (Poll) may run on
  // different threads: the cache is atomic.
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = fushi_voice_hook::MatchesEntisGlsProfile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override {
    if (!probe()) return false;
    installed_ = InstallEntisGlsText() || installed_;
    return installed_;
  }
  void ProcessPendingEvents() {
    if (!installed_) return;
    ProcessEntisGlsTextTick();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    ShutdownEntisGlsText();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_entisgls_diag, 0, 0))};
  }

 private:
  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 EntisGLS, 2 not
  bool installed_ = false;
};
