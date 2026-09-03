// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <type_traits>

#include "luna_bridge.h"

int main() {
  static_assert(fushi_voice_hook::kLunaBridgeAbiVersion == 1);
  static_assert(fushi_voice_hook::kLunaVendoredVersion == 0x0A100102);
  static_assert(sizeof(fushi_voice_hook::LunaThreadParam) == 32);
  static_assert(std::is_same_v<fushi_voice_hook::PFN_Luna_ConnectProcess,
                               void (*)(DWORD)>);
  static_assert(std::is_same_v<fushi_voice_hook::PFN_Luna_InsertHookCode,
                               bool (*)(DWORD, const wchar_t*)>);
  static_assert(std::is_same_v<fushi_voice_hook::PFN_Luna_RemoveHook,
                               void (*)(DWORD, uint64_t)>);
  static_assert(fushi_voice_hook::kLunaRequiredExports.size() == 4);
  return 0;
}
