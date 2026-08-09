#include <array>
#include <cstdio>

#include "luna_hook_config.h"

int main() {
  fushi_voice_hook::LunaTargetIdentity nine;
  nine.executable_sha256 =
      "36448822f1a8bc3840b304d3993c07de912db6c803dddd8db1202ed676ba7019";
  const auto built_in = fushi_voice_hook::MatchLunaHookProfiles(
      fushi_voice_hook::BuiltInLunaHookProfiles(), nine);
  if (built_in.codepage != 932 || built_in.hook_codes.size() != 1 ||
      built_in.hook_codes.front() != L"EXHVXN0@2198:nine_kokoiro.exe") {
    std::fprintf(stderr, "verified executable hash did not match\n");
    return 1;
  }

  fushi_voice_hook::LunaTargetIdentity fate;
  fate.executable_sha256 =
      "9c195563b8724131cfc5cfd7b32767597efba136d98bb81dfda2fdb242695c2a";
  const auto fate_profile = fushi_voice_hook::MatchLunaHookProfiles(
      fushi_voice_hook::BuiltInLunaHookProfiles(), fate);
  if (fate_profile.enable_pc_hooks ||
      fate_profile.defer_until_running_ms != 8000 ||
      fate_profile.blocked_hook_codes.size() != 2 ||
      fate_profile.blocked_hook_codes.front() != L"EXHQXN8@1647F4" ||
      fate_profile.blocked_hook_codes.back() != L"EXHWXN0@1D2865" ||
      fate_profile.blocked_hook_names.size() != 2 ||
      fate_profile.blocked_hook_names.front() != L"Krkr2wcs" ||
      fate_profile.blocked_hook_names.back() != L"EmbedKrkr2" ||
      fate_profile.preferred_hook_codes.size() != 1 ||
      fate_profile.preferred_hook_codes.front() != L"HQXN-C@1D2F80" ||
      !fushi_voice_hook::LunaHookCodeMatchesBlock(
          fate_profile.blocked_hook_codes.front(),
          L"EXHQXN8@1647F4:Fate／stay night[Realta Nua] -Fate-.exe") ||
      fushi_voice_hook::LunaHookCodeMatchesBlock(
          fate_profile.blocked_hook_codes.front(), L"EXHQXN8@1647F5")) {
    std::fprintf(stderr, "Fate unsafe auto-hook profile did not match\n");
    return 5;
  }
  if (!fushi_voice_hook::LunaHostLogConfirmsHookRemoval(
          L"移除钩子: Krkr2wcs", L"Krkr2wcs") ||
      !fushi_voice_hook::LunaHostLogConfirmsHookRemoval(
          L"remove hook Krkr2wcs  \r\n", L"Krkr2wcs") ||
      fushi_voice_hook::LunaHostLogConfirmsHookRemoval(
          L"注入钩子: Krkr2wcs 005647F4", L"Krkr2wcs")) {
    std::fprintf(stderr, "Luna removal confirmation parsing failed\n");
    return 6;
  }
  std::array<wchar_t, fushi_voice_hook::kMaxLunaHostLogCharacters>
      unterminated_log{};
  unterminated_log.fill(L'x');
  if (fushi_voice_hook::LunaHostLogConfirmsHookRemoval(
          unterminated_log.data(), L"Krkr2wcs")) {
    std::fprintf(stderr, "unterminated Luna host log was accepted\n");
    return 7;
  }

  fushi_voice_hook::LunaTargetIdentity moved = nine;
  if (fushi_voice_hook::MatchLunaHookProfiles(
          fushi_voice_hook::BuiltInLunaHookProfiles(), moved)
          .hook_codes.empty()) {
    std::fprintf(stderr, "profile must not depend on install path\n");
    return 2;
  }

  fushi_voice_hook::LunaTargetIdentity other;
  other.executable_sha256 = std::string(64, '0');
  if (!fushi_voice_hook::MatchLunaHookProfiles(
           fushi_voice_hook::BuiltInLunaHookProfiles(), other)
           .hook_codes.empty()) {
    return 3;
  }

  const std::string module_profile =
      "exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel\n"
      "\tkirikiri.dll\t" + std::string(64, 'a') +
      "\t932\tHQ@1234\tmodule-only\n";
  other.module_sha256["kirikiri.dll"] = std::string(64, 'a');
  if (fushi_voice_hook::MatchLunaHookProfiles(module_profile, other)
          .hook_codes.size() != 1) {
    std::fprintf(stderr, "module hash profile did not match\n");
    return 4;
  }
  return 0;
}
