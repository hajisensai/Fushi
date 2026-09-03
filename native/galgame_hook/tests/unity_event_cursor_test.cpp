// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>

#include "voice_hook_session.h"

using fushi_voice_hook::AdvanceUnityEventCursorIfCommitted;

int main() {
  uint64_t next_event = 6;

  // 生产者已预留 write_count、但槽 seq 仍为 0：消费者必须保留游标。
  assert(!AdvanceUnityEventCursorIfCommitted(7, 0, &next_event));
  assert(next_event == 6);

  // 同一槽提交后再消费，恰好前进一步。
  assert(AdvanceUnityEventCursorIfCommitted(7, 7, &next_event));
  assert(next_event == 7);

  // 错槽与空指针都不能伪造消费进度。
  assert(!AdvanceUnityEventCursorIfCommitted(8, 9, &next_event));
  assert(next_event == 7);
  assert(!AdvanceUnityEventCursorIfCommitted(8, 8, nullptr));
  return 0;
}
