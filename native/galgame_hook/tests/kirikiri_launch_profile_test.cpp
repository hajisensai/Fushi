#include "kirikiri_launch_profile.h"

#include <cstdio>
#include <cstring>
#include <cwchar>

namespace {

int failures = 0;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::printf("FAIL: %s\n", message);
    ++failures;
  }
}

}  // namespace

int main() {
  const auto* chinese = hibiki_voice_hook::FindKirikiriDelayedAttachProfile(
      "0cb927556f83b41b08624c52ede135ce5be652ead8305e701d7be89e10d6c1ea");
  Check(chinese != nullptr, "verified Chinese binary selects delayed attach");
  Check(chinese != nullptr && std::strcmp(chinese->id, "futamata-renai-cn") == 0,
        "Chinese binary selects its exact profile");
  Check(chinese != nullptr &&
            std::wcscmp(chinese->readiness_module, L"wuvorbis.dll") == 0,
        "profile waits for the observed decoder module");

  const auto* japanese = hibiki_voice_hook::FindKirikiriDelayedAttachProfile(
      "07a2a3d6aa665e3e2c4958fbf9fecfd93a5c9baac797813a152736b1edba3245");
  Check(japanese != nullptr, "verified Japanese binary selects delayed attach");
  Check(japanese != nullptr && std::strcmp(japanese->id, "futamata-renai-jp") == 0,
        "Japanese binary selects its exact profile");

  Check(hibiki_voice_hook::FindKirikiriDelayedAttachProfile(
            "0cb927556f83b41b08624c52ede135ce5be652ead8305e701d7be89e10d6c1eb") ==
            nullptr,
        "one-nibble near miss keeps normal KiriKiri early injection");
  Check(hibiki_voice_hook::FindKirikiriDelayedAttachProfile(
            "2280110000000000000000000000000000000000000000000000000000000000") ==
            nullptr,
        "unrelated KiriKiri sample keeps normal early injection");
  Check(hibiki_voice_hook::FindKirikiriDelayedAttachProfile("") == nullptr,
        "missing identity never enables delayed attach");

  if (failures == 0) {
    std::printf("kirikiri_launch_profile_test: all checks passed\n");
    return 0;
  }
  return 1;
}
