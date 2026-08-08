#include <cassert>
#include <string>

#include "steam_launch.h"

int main() {
  using fushi_voice_hook::ParseAcfQuotedValue;
  using fushi_voice_hook::ParseSteamLibraryPath;
  using fushi_voice_hook::BuildSteamRunUri;
  using fushi_voice_hook::ChooseSteamLaunchStrategy;
  using fushi_voice_hook::SteamLibraryPath;
  using fushi_voice_hook::SteamLaunchStrategy;

  SteamLibraryPath path;
  assert(ParseSteamLibraryPath(
      L"D:/steam/steamapps/common/manosaba_game/manosaba.exe", &path));
  assert(path.steamapps_dir == L"D:\\steam\\steamapps");
  assert(path.install_dir == L"manosaba_game");
  assert(!ParseSteamLibraryPath(L"C:\\Games\\game.exe", &path));

  const std::wstring manifest =
      L"\"AppState\"\n{\n  \"appid\"  \"3101040\"\n"
      L"  \"installdir\"  \"manosaba_game\"\n}\n";
  assert(ParseAcfQuotedValue(manifest, L"appid") == L"3101040");
  assert(ParseAcfQuotedValue(manifest, L"INSTALLDIR") == L"manosaba_game");
  assert(ParseAcfQuotedValue(manifest, L"missing").empty());

  assert(ChooseSteamLaunchStrategy(L"3101040") ==
         SteamLaunchStrategy::kSteamClient);
  assert(ChooseSteamLaunchStrategy(L"") ==
         SteamLaunchStrategy::kDirectExecutable);
  assert(ChooseSteamLaunchStrategy(L"3101040-beta") ==
         SteamLaunchStrategy::kDirectExecutable);
  assert(BuildSteamRunUri(L"3101040") == L"steam://run/3101040");
  assert(BuildSteamRunUri(L"not-an-appid").empty());
  return 0;
}
