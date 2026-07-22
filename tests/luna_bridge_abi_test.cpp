#include <type_traits>

#include "luna_bridge.h"

int main() {
  static_assert(hibiki_voice_hook::kLunaBridgeAbiVersion == 1);
  static_assert(hibiki_voice_hook::kLunaVendoredVersion == 0x0A100102);
  static_assert(sizeof(hibiki_voice_hook::LunaThreadParam) == 32);
  static_assert(std::is_same_v<hibiki_voice_hook::PFN_Luna_ConnectProcess,
                               void (*)(DWORD)>);
  static_assert(std::is_same_v<hibiki_voice_hook::PFN_Luna_InsertHookCode,
                               bool (*)(DWORD, const wchar_t*)>);
  return hibiki_voice_hook::kLunaRequiredExports.size() == 4 ? 0 : 1;
}
