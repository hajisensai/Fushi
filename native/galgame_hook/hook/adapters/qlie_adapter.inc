// QLIE uses the same exported wuvorbis ABI as KiriKiri, but its encrypted
// datasource is not safely rewindable after an eager whole-stream copy.
// Capture wu_ov_read / wu_ov_read_float output: decoded per-source PCM before
// engine mixing.
#include "qlie_profile.h"

bool TryHookQlieVorbis() {
  if (!hibiki_voice_hook::MatchesQlieProfile(nullptr)) return false;
  InterlockedExchange(&hibiki_voice_hook::g_qlie_profile_active, 1);
  TryHookKirikiriDecoders();
  const bool ready = g_orig_wu_ov_open_callbacks != nullptr &&
                     (g_orig_wu_ov_read != nullptr ||
                      g_orig_wu_ov_read_float != nullptr);
  if (ready && g_header != nullptr) {
    g_header->reserved_hook_diagnostics |=
        hibiki_voice_hook::kDiagQlieVorbisHooksReady;
  }
  return ready;
}

class QlieAdapter final : public hibiki_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "qlie_filepack"; }
  bool probe() const override {
    return hibiki_voice_hook::MatchesQlieProfile(nullptr);
  }
  bool install() override {
    ready_ = TryHookQlieVorbis();
    installed_ = installed_ || ready_;
    return ready_;
  }
  hibiki_voice_hook::AdapterCapability capabilities() const override {
    return hibiki_voice_hook::AdapterCapability::kText |
           hibiki_voice_hook::AdapterCapability::kPcmAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr ||
        _wcsicmp(module_name, L"wuvorbis.dll") == 0) {
      install();
    }
  }
  void shutdown() override {
    InterlockedExchange(&hibiki_voice_hook::g_qlie_profile_active, 0);
    installed_ = false;
    ready_ = false;
  }
  hibiki_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            g_header == nullptr ? 0u : g_header->reserved_hook_diagnostics};
  }

 private:
  bool installed_ = false;
  bool ready_ = false;
};
