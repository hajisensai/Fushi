// YU-RIS adapter: the engine's message text lane and in-game lookup
// (yuris_lookup.inc; structural site resolution and pure rules in
// yuris_lookup_core.h) and per-line voice at the decoder input
// (yuris_voice.inc / yuris_voice_core.h).
//
// Identity is structural (yuris_profile.h: a self-consistent YPF archive next
// to the executable).  Every hook site resolves only from the image's own
// code, read from disk so other in-process hookers cannot shift it.  Each
// layer fails closed on its own.
#include "yuris_profile.h"
#include "yuris_lookup.inc"
#include "yuris_voice.inc"

class YurisAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "yuris"; }
  // The identity is a property of the files next to the executable: measured
  // once (it reads archive indexes from disk), then reused by install() and
  // diagnostics().  install() (startup) and diagnostics() (Poll) may run on
  // different threads: the cache is atomic, and two first calls racing only
  // measure the same files twice.
  bool probe() const override {
    int state = probe_state_.load(std::memory_order_acquire);
    if (state == 0) {
      state = fushi_voice_hook::MatchesYurisProfile(nullptr) ? 1 : 2;
      probe_state_.store(state, std::memory_order_release);
    }
    return state == 1;
  }
  bool install() override {
    if (!probe()) return false;
    text_installed_ = InstallYurisLookup() || text_installed_;
    voice_ready_ = InstallYurisVoice() || voice_ready_;
    installed_ = installed_ || text_installed_ || voice_ready_;
    return installed_;
  }
  void ProcessPendingEvents() {
    if (!installed_) return;
    // Messages first: each one settles the voice clips opened before it, so
    // a clip is only published without an owner (expiry) once every message
    // pushed so far has been seen.
    ProcessYurisLookupTick();
    ProcessYurisVoiceTasks();
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
    if (YurisLookupSensorInstalled()) {
      report.state = fushi_voice_hook::kLookupAdmissionSensorInstalled;
      return report;
    }
    if (YurisLookupSitesRejected()) {
      report.state = fushi_voice_hook::kLookupAdmissionIdentityRejected;
      strncpy_s(report.executable_sha256,
                fushi_voice_hook::HostExecutableSha256Hex(), _TRUNCATE);
      return report;
    }
    report.state = fushi_voice_hook::kLookupAdmissionIdentityAccepted;
    return report;
  }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t*) override {}
  void shutdown() override {
    ShutdownYurisLookup();
    text_installed_ = false;
    StopYurisVoice();
    voice_ready_ = false;
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_yuris_diag, 0, 0))};
  }

 private:
  mutable std::atomic<int> probe_state_{0};  // 0 unmeasured, 1 YU-RIS, 2 not
  bool installed_ = false;
  bool text_installed_ = false;
  bool voice_ready_ = false;
};
