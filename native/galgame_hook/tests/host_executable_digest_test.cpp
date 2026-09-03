// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>

#include "host_executable_digest.h"

namespace {

using fushi_voice_hook::HostExecutableSha256Hex;
using fushi_voice_hook::PublishHostExecutableSha256;

// 这个槽存在的理由：准入收敛到「不支持或未识别」那一刻的定义就是**没有任何 adapter
// 认领**，各家私有摘要缓冲在那里全部够不着。下面几条钉住它与私有缓冲的差别。

void TestEmptyBeforeAnyoneComputes() {
  // 空串而不是 64 个 0：host 要能说"算不出"，而不是显示一串零让用户以为那是他的 hash。
  assert(HostExecutableSha256Hex()[0] == '\0');
}

void TestPublishFormatsLowercaseHex() {
  uint8_t digest[32];
  for (int i = 0; i < 32; ++i) digest[i] = static_cast<uint8_t>(i);
  PublishHostExecutableSha256(digest, sizeof(digest));
  assert(std::strcmp(HostExecutableSha256Hex(),
                     "000102030405060708090a0b0c0d0e0f"
                     "101112131415161718191a1b1c1d1e1f") == 0);
}

void TestSecondPublishDoesNotOverwrite() {
  // 一次性：同一个 exe 的摘要不会变，先到的那份就是答案。这条同时是并发安全的依据——
  // 两个 profile 解析线程同时写也只是写同一串字符。
  uint8_t other[32];
  for (int i = 0; i < 32; ++i) other[i] = 0xAB;
  PublishHostExecutableSha256(other, sizeof(other));
  assert(std::strcmp(HostExecutableSha256Hex(),
                     "000102030405060708090a0b0c0d0e0f"
                     "101112131415161718191a1b1c1d1e1f") == 0);
}

void TestBadDigestLengthLeavesSlotUsable() {
  // 摘要长度不对时 FormatSha256Hex 会把目标置空串。这里槽已经有值且一次性闸挡在前面，
  // 所以坏输入连门都进不去——已发布的答案不会被一次失败的调用抹掉。
  uint8_t truncated[16] = {};
  PublishHostExecutableSha256(truncated, sizeof(truncated));
  assert(HostExecutableSha256Hex()[0] == '0');
  assert(std::strlen(HostExecutableSha256Hex()) == 64);
}

}  // namespace

int main() {
  TestEmptyBeforeAnyoneComputes();
  TestPublishFormatsLowercaseHex();
  TestSecondPublishDoesNotOverwrite();
  TestBadDigestLengthLeavesSlotUsable();
  return 0;
}
