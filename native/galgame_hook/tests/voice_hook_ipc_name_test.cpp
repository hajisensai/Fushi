// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include "voice_hook_ipc.h"

#include <cassert>

int main() {
  using fushi_voice_hook::ReadyEventName;
  using fushi_voice_hook::SharedMemoryName;

  assert(SharedMemoryName(32464) == L"Local\\FushiVoiceHook_32464");
  assert(ReadyEventName(32464) == L"Local\\FushiVoiceHookReady_32464");
  return 0;
}
