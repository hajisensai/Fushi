#include <cstdio>

#include "luna_hook_config.h"

int main() {
  hibiki_voice_hook::LunaTargetIdentity nine;
  nine.executable_sha256 =
      "36448822f1a8bc3840b304d3993c07de912db6c803dddd8db1202ed676ba7019";
  const auto built_in = hibiki_voice_hook::MatchLunaHookProfiles(
      hibiki_voice_hook::BuiltInLunaHookProfiles(), nine);
  if (built_in.codepage != 932 || built_in.hook_codes.size() != 1 ||
      built_in.hook_codes.front() != L"EXHVXN0@2198:nine_kokoiro.exe") {
    std::fprintf(stderr, "verified executable hash did not match\n");
    return 1;
  }

  hibiki_voice_hook::LunaTargetIdentity moved = nine;
  if (hibiki_voice_hook::MatchLunaHookProfiles(
          hibiki_voice_hook::BuiltInLunaHookProfiles(), moved)
          .hook_codes.empty()) {
    std::fprintf(stderr, "profile must not depend on install path\n");
    return 2;
  }

  hibiki_voice_hook::LunaTargetIdentity other;
  other.executable_sha256 = std::string(64, '0');
  if (!hibiki_voice_hook::MatchLunaHookProfiles(
           hibiki_voice_hook::BuiltInLunaHookProfiles(), other)
           .hook_codes.empty()) {
    return 3;
  }

  const std::string module_profile =
      "exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel\n"
      "\tkirikiri.dll\t" + std::string(64, 'a') +
      "\t932\tHQ@1234\tmodule-only\n";
  other.module_sha256["kirikiri.dll"] = std::string(64, 'a');
  if (hibiki_voice_hook::MatchLunaHookProfiles(module_profile, other)
          .hook_codes.size() != 1) {
    std::fprintf(stderr, "module hash profile did not match\n");
    return 4;
  }
  return 0;
}
