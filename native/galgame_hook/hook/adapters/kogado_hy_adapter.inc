// Kogado "Hy" adapter: the engine's message text lane (kogado_hy_text.inc;
// structural site resolution and the page rules in kogado_hy_core.h).
//
// Identity is structural (kogado_hy_profile.h: the executable exports the Hy
// runtime library).  The hook site resolves only from the image's own code,
// read from disk so other in-process hookers cannot shift it.  Voice reaches
// the host through the generic DirectSound PCM capture; in-game lookup is not
// provided yet.
#include "kogado_hy_profile.h"
#include "kogado_hy_text.inc"

class KogadoHyAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "kogado_hy"; }
  // The identity is a property of the main executable: measured once, then
  // reused.  install() (startup) and diagnostics() (Poll) may run on
  // different threads: the cache is atomic.
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = fushi_voice_hook::MatchesKogadoHyProfile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override {
    if (!probe()) return false;
    installed_ = InstallKogadoHyText() || installed_;
    return installed_;
  }
  void ProcessPendingEvents() {
    if (!installed_) return;
    ProcessKogadoHyTextTick();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    ShutdownKogadoHyText();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_kogado_hy_diag, 0, 0))};
  }

 private:
  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 Hy, 2 not
  bool installed_ = false;
};
