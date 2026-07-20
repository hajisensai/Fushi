#include <cassert>
#include <string>

#include "steam_launch.h"

int main() {
  using hibiki_voice_hook::ParseAcfQuotedValue;
  using hibiki_voice_hook::ParseSteamLibraryPath;
  using hibiki_voice_hook::SteamLibraryPath;

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
  return 0;
}
