// RealLive / old VisualArt's adapter. The shared OVK layer installs generically and only publishes a
// resource after an opened *.ovk matches the bounded index and complete Ogg/EOS contract. That
// runtime observation proves the format path, not the engine identity; hash recognition stays empty
// until a real RealLive sample is measured.
#include "reallive_profile.h"

class RealliveAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "reallive"; }
  bool probe() const override {
    // Seeing a valid OVK proves only the shared container path. It must not identify the process as
    // RealLive; that requires a measured executable or module profile.
    return hibiki_voice_hook::MatchesRealliveProfile(nullptr);
  }
  bool install() override {
    installed_ = TryHookSiglusOvk();
    return installed_;
  }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kResourceAudio |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t*) override {
    // File APIs are installed at startup; module notifications remain a profile extension seam.
  }
  void shutdown() override { installed_ = false; }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->hook_diagnostics};
  }
 private:
  bool installed_ = false;
};
