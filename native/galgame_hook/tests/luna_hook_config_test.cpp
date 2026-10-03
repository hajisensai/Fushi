// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <array>
#include <cstdio>
#include <cstring>
#include <string>

#include "luna_hook_config.h"
#include "luna_text_selector.h"
#include "sgre_family.h"

int main() {
  fushi_voice_hook::LunaTargetIdentity wa2;
  wa2.executable_sha256 =
      "005e71107ed70e662c41cb526879cdcf0b9486e067c0e5a306308688c17409ed";
  const auto wa2_profile = fushi_voice_hook::MatchLunaHookProfiles(
      fushi_voice_hook::BuiltInLunaHookProfiles(), wa2);
  if (wa2_profile.codepage != 932 || wa2_profile.enable_pc_hooks ||
      wa2_profile.hook_codes.size() != 1 ||
      wa2_profile.hook_codes.front() != L"HSX0:0@512BF:WA2.exe") {
    std::fprintf(stderr, "WHITE ALBUM2 exact profile did not match\n");
    return 9;
  }

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

  fushi_voice_hook::LunaTargetIdentity sgre;
  sgre.executable_sha256 =
      "75a83a0e2a7e22055417ae0474b47be98418c4e42c695c548b558705c404b9d8";
  const auto sgre_profile = fushi_voice_hook::MatchLunaHookProfiles(
      fushi_voice_hook::BuiltInLunaHookProfiles(), sgre);
  // 引擎级适配：SGRE 的文本走游戏内 adapter 的结构识别（SGRE exact 文本线），MAGES
  // 控制符归一化由引擎身份打开（kLunaMagesControlEngineAdapterId），内置表里不得再有按
  // 这份 exe 哈希钉死的 hook code / 选项。
  if (!sgre_profile.hook_codes.empty() || sgre_profile.normalize_mages_controls ||
      sgre_profile.enable_pc_hooks || sgre_profile.codepage != 0) {
    std::fprintf(stderr,
                 "built-in Luna profiles must not pin STEINS;GATE RE:BOOT by "
                 "executable hash\n");
    return 8;
  }
  if (std::strcmp(fushi_voice_hook::kLunaMagesControlEngineAdapterId, "sgre") !=
      0) {
    std::fprintf(stderr, "MAGES normalization must follow the SGRE engine id\n");
    return 8;
  }
  // 显式用户 profile 仍可打开该选项（与引擎身份并列，供未识别的 MAGES 变体兜底）。
  {
    const std::string user_profile =
        "exe_sha256\tmodule_name\tmodule_sha256\tcodepage\thook_code\tlabel\t"
        "options\n" +
        std::string(64, 'b') + "\t\t\t932\t\tuser MAGES\tnormalize-mages-controls\n";
    fushi_voice_hook::LunaTargetIdentity user;
    user.executable_sha256 = std::string(64, 'b');
    if (!fushi_voice_hook::MatchLunaHookProfiles(user_profile, user)
             .normalize_mages_controls) {
      std::fprintf(stderr, "user normalize-mages-controls option was ignored\n");
      return 8;
    }
  }

  // 注入器在注入前用与 SGRE adapter probe() 同一判据（exe 旁 wind3d11 语音归档）打开
  // MAGES 控制符归一化，Luna 第一行起就生效。判据看目录结构，不看 exe 名 / 哈希。
  {
    if (fushi_voice_hook::SgreVoiceArchivePathForExecutable(
            L"C:\\Games\\SGRE\\any_name.exe") !=
        L"C:\\Games\\SGRE\\wind3d11data\\voice_body.bin") {
      std::fprintf(stderr, "SGRE archive path composition drifted\n");
      return 9;
    }
    if (!fushi_voice_hook::SgreVoiceArchivePathForExecutable(L"bare.exe")
             .empty()) {
      std::fprintf(stderr, "directory-less path must not resolve an archive\n");
      return 9;
    }
    wchar_t temp[MAX_PATH] = {};
    const DWORD temp_chars = GetTempPathW(MAX_PATH, temp);
    if (temp_chars == 0 || temp_chars >= MAX_PATH) return 9;
    const std::wstring root = std::wstring(temp) + L"fushi_sgre_family_" +
                              std::to_wstring(GetCurrentProcessId());
    const std::wstring data = root + L"\\wind3d11data";
    const std::wstring archive = data + L"\\voice_body.bin";
    const std::wstring exe = root + L"\\renamed_game.exe";
    CreateDirectoryW(root.c_str(), nullptr);
    if (fushi_voice_hook::SgreVoiceArchiveExistsBesideExecutable(exe)) {
      std::fprintf(stderr, "SGRE identity claimed without the voice archive\n");
      return 9;
    }
    CreateDirectoryW(data.c_str(), nullptr);
    CreateDirectoryW(archive.c_str(), nullptr);
    const bool directory_accepted =
        fushi_voice_hook::SgreVoiceArchiveExistsBesideExecutable(exe);
    RemoveDirectoryW(archive.c_str());
    if (directory_accepted) {
      std::fprintf(stderr, "a directory named voice_body.bin is not an archive\n");
      return 9;
    }
    HANDLE file = CreateFileW(archive.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 9;
    CloseHandle(file);
    const bool matched =
        fushi_voice_hook::SgreVoiceArchiveExistsBesideExecutable(exe);
    DeleteFileW(archive.c_str());
    RemoveDirectoryW(data.c_str());
    RemoveDirectoryW(root.c_str());
    if (!matched) {
      std::fprintf(stderr, "SGRE voice archive was not recognized\n");
      return 9;
    }
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
