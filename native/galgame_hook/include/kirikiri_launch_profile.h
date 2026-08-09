#pragma once

#include <array>
#include <string>

namespace fushi_voice_hook {

// Binary-scoped lifecycle exceptions for KiriKiri titles that crash when the
// raw TVP stream adapter is installed from a CREATE_SUSPENDED startup hook.
// These profiles preserve early injection for every other KiriKiri binary.
struct KirikiriDelayedAttachProfile {
  const char* id;
  const char* executable_sha256;
  const wchar_t* readiness_module;
};

inline constexpr std::array<KirikiriDelayedAttachProfile, 2>
    kKirikiriDelayedAttachProfiles = {{
        {"futamata-renai-cn",
         "0cb927556f83b41b08624c52ede135ce5be652ead8305e701d7be89e10d6c1ea",
         L"wuvorbis.dll"},
        {"futamata-renai-jp",
         "07a2a3d6aa665e3e2c4958fbf9fecfd93a5c9baac797813a152736b1edba3245",
         L"wuvorbis.dll"},
    }};

inline const KirikiriDelayedAttachProfile* FindKirikiriDelayedAttachProfile(
    const std::string& executable_sha256) {
  for (const auto& profile : kKirikiriDelayedAttachProfiles) {
    if (executable_sha256 == profile.executable_sha256) {
      return &profile;
    }
  }
  return nullptr;
}

}  // namespace fushi_voice_hook
