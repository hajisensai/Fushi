// AliceSoft System 4 adapter: the engine's message text lane
// (system4_text.inc) and in-game lookup (system4_lookup.inc); every rule in
// system4_core.h.  No voice: the measured sample has none, so no pairing
// rule is claimed.
//
// Identity is structural (system4_profile.h: a loaded module exports the
// SACT2 HLL surface, and the VM module's MSG handler decodes).  The VM loads
// its HLL libraries after start, so install is retried on module loads.
#include "system4_profile.h"
#include "system4_text.inc"
#include "system4_lookup.inc"

class System4Adapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "system4"; }
  // Measured once over the loaded modules, then on each module load (the
  // only way the answer can change).  install() (startup) and diagnostics()
  // (Poll) may run on different threads: the cache is atomic.
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = fushi_voice_hook::MatchesSystem4Profile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override { return InstallFrom(nullptr); }
  void ProcessPendingEvents() {
    if (!installed_) return;
    ProcessSystem4TextTick();
    ProcessSystem4LookupTick();
  }
  // The hover highlight follows the cursor on the HookWorker tick.
  bool lookup_sensor_available() const {
    return installed_ && System4LookupSensorInstalled();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    report.state = System4LookupSensorInstalled()
                       ? fushi_voice_hook::kLookupAdmissionSensorInstalled
                       : fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (installed_ || module_name == nullptr ||
        !fushi_voice_hook::MatchesSystem4Profile(module_name)) {
      return;
    }
    probe_state_.store(1, std::memory_order_release);
    InstallFrom(module_name);
  }
  void shutdown() override {
    ShutdownSystem4Lookup();
    ShutdownSystem4Text();
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_system4_diag, 0, 0))};
  }

 private:
  bool InstallFrom(const wchar_t* module_name) {
    if (installed_) return true;
    installed_ = InstallSystem4Text(module_name);
    // Lookup is optional: the text lane works without it.
    if (installed_) InstallSystem4Lookup();
    return installed_;
  }

  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 SACT2, 2 not
  bool installed_ = false;
};
