// Nitroplus N2System (nss/.npa) adapter: the engine's shown-line text from its
// backlog append routine (nitroplus_text.inc); every rule in nitroplus_core.h.
//
// Identity is structural (nitroplus_profile.h: the main executable carries the
// backlog append routine, proved unique by its structure).  The routine is in
// the executable, so install at startup is final; a module load never changes
// the answer.
//
// Not implemented (see engine-support.yaml known_limitations): per-line voice
// resource export (the voice tag name is captured, the .npa entry bytes are
// not), in-game lookup geometry and the click shield.
#include "nitroplus_profile.h"
#include "nitroplus_text.inc"

class NitroplusAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "nitroplus"; }
  bool probe() const override {
    return fushi_voice_hook::MatchesNitroplusProfile(nullptr);
  }
  bool install() override {
    if (installed_) return true;
    if (!probe()) return false;
    installed_ = InstallNitroplusText();
    return installed_;
  }
  void ProcessPendingEvents() {
    if (installed_) ProcessNitroplusTextTick();
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (installed_ || module_name == nullptr ||
        !fushi_voice_hook::MatchesNitroplusProfile(module_name)) {
      return;
    }
    install();
  }
  void shutdown() override {
    ShutdownNitroplusText();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_nitroplus_diag, 0, 0))};
  }

 private:
  bool installed_ = false;
};
