// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cstdint>
#include <cstring>
#include <vector>

#include "../hook/adapters/reallive_profile.h"
#include "../hook/visual_arts_ovk.h"

namespace {
void PutLe32(std::vector<uint8_t>* bytes, size_t at, uint32_t value) {
  std::memcpy(bytes->data() + at, &value, sizeof(value));
}
}

int main() {
  if (fushi_voice_hook::MatchesRealliveProfile(nullptr)) return 1;

  std::vector<uint8_t> archive(20, 0);
  PutLe32(&archive, 0, 1);
  PutLe32(&archive, 4, 31);
  PutLe32(&archive, 8, 20);
  PutLe32(&archive, 12, 250);
  PutLe32(&archive, 16, 7);
  fushi_voice_hook::visual_arts::OvkEntry entry;
  if (!fushi_voice_hook::visual_arts::FindEntryAtOffset(
          archive.data(), archive.size(), 51, 20, &entry)) {
    return 2;
  }
  return entry.byte_len == 31 && entry.id == 7 ? 0 : 3;
}
