// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cstdint>
#include <cstdio>

#include "hook_original_registry.h"

namespace {

int g_failures = 0;

void Check(bool condition, const char* message) {
  if (condition) return;
  std::fprintf(stderr, "FAIL: %s\n", message);
  ++g_failures;
}

void* Address(uintptr_t value) { return reinterpret_cast<void*>(value); }

}  // namespace

int main() {
  fushi_voice_hook::HookOriginalRegistry<2> registry;
  void* const wave_target = Address(0x1000);
  void* const wave_original = Address(0x2000);
  void* const wma_target = Address(0x3000);
  void* const wma_original = Address(0x4000);

  Check(registry.Publish(wave_target, wave_original),
        "wave target must publish");
  Check(registry.Publish(wma_target, wma_original),
        "WMA target must publish independently");
  Check(registry.Lookup(wave_target) == wave_original,
        "wave target must keep its own trampoline after WMA publication");
  Check(registry.Lookup(wma_target) == wma_original,
        "WMA target must resolve its own trampoline");
  Check(registry.Lookup(Address(0x5000)) == nullptr,
        "unknown target must not fall back to the latest trampoline");
  Check(!registry.Publish(wave_target, wma_original),
        "a target must not be rebound to a different trampoline");
  Check(!registry.Publish(Address(0x5000), Address(0x6000)),
        "full registry must reject an untracked hook");
  Check(!registry.Erase(wave_target, wma_original),
        "rollback must require the matching trampoline");
  Check(registry.Erase(wave_target, wave_original),
        "matching hook publication must be removable before enable");
  Check(registry.Lookup(wave_target) == nullptr,
        "erased target must not resolve");

  return g_failures == 0 ? 0 : 1;
}
