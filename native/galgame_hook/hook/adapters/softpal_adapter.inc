// SoftPal ADV System adapter: the engine's message text lane and the voice of
// each line from its own archive (softpal_text.inc), and in-game lookup
// (softpal_lookup.inc); every rule in softpal_core.h.
//
// Identity is structural (softpal_profile.h: a loaded module exports the Pal
// runtime surface).  Pal.dll may load after the hook attaches, so install
// is retried on module loads.
#include "softpal_profile.h"
#include "softpal_text.inc"
#include "softpal_lookup.inc"

class SoftpalAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "softpal"; }
  // Measured once over the loaded modules, then on each module load (the
  // only way the answer can change).  install() (startup) and diagnostics()
  // (Poll) may run on different threads: the cache is atomic.
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = fushi_voice_hook::MatchesSoftpalProfile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override { return InstallFrom(nullptr); }
  void ProcessPendingEvents() {
    if (!installed_) return;
    ProcessSoftpalTextTick();
    ProcessSoftpalLookupTick();
  }
  // The hover highlight follows the cursor on the HookWorker tick.
  bool lookup_sensor_available() const {
    return installed_ && SoftpalLookupSensorInstalled();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    report.state = SoftpalLookupSensorInstalled()
                       ? fushi_voice_hook::kLookupAdmissionSensorInstalled
                       : fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (installed_ || module_name == nullptr ||
        !fushi_voice_hook::MatchesSoftpalProfile(module_name)) {
      return;
    }
    probe_state_.store(1, std::memory_order_release);
    InstallFrom(module_name);
  }
  void shutdown() override {
    ShutdownSoftpalLookup();
    ShutdownSoftpalText();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_softpal_diag, 0, 0))};
  }

 private:
  bool InstallFrom(const wchar_t* module_name) {
    if (installed_) return true;
    installed_ = InstallSoftpalText(module_name);
    // Lookup is optional: the text lane works without it.
    if (installed_) InstallSoftpalLookup();
    return installed_;
  }

  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 Pal, 2 not
  bool installed_ = false;
};
