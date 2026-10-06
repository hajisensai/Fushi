// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <initializer_list>

#include "x86_insn_len.h"

using fushi_voice_hook::x86::FindFirstAcceptedCallTarget;
using fushi_voice_hook::x86::InsnLen32;
using fushi_voice_hook::x86::RelCallDest;

namespace {

uint32_t Len(std::initializer_list<uint8_t> bytes) {
  uint8_t buf[16] = {};
  size_t i = 0;
  for (uint8_t b : bytes) buf[i++] = b;
  return InsnLen32(buf);
}

// 在 buf[at] 写一条 call rel32，使目标为 buf + target。
void PutCall(uint8_t* buf, size_t at, size_t target) {
  const int32_t rel = static_cast<int32_t>(target) - static_cast<int32_t>(at + 5);
  buf[at] = 0xE8;
  std::memcpy(buf + at + 1, &rel, 4);
}

}  // namespace

int main() {
  // 0x66 把 imm32 变 imm16（BUG-2887：BCB try 帧序言 `mov word ptr [ebp-20h], 0`）。
  assert(Len({0x66, 0xC7, 0x45, 0xE0, 0x00, 0x00}) == 6);
  assert(Len({0xC7, 0x45, 0xD8, 1, 2, 3, 4}) == 7);
  assert(Len({0x66, 0xB8, 0x34, 0x12}) == 4);
  assert(Len({0xB8, 1, 2, 3, 4}) == 5);
  assert(Len({0x66, 0x81, 0xC1, 0x34, 0x12}) == 5);
  assert(Len({0x66, 0x3D, 0x34, 0x12}) == 4);
  assert(Len({0x66, 0x68, 0x34, 0x12}) == 4);
  // 段前缀不改宽度：fs:[0] 的 SEH 链读写。
  assert(Len({0x64, 0x8B, 0x0D, 0, 0, 0, 0}) == 7);
  assert(Len({0x64, 0xA3, 0, 0, 0, 0}) == 6);
  assert(Len({0x64, 0x89, 0x25, 0, 0, 0, 0}) == 7);
  // 0x66 不影响 moffs（跟地址宽度）与 rel32。
  assert(Len({0x66, 0xA1, 0, 0, 0, 0}) == 6);
  // 常见序言 / modrm 形态。
  assert(Len({0x55}) == 1);
  assert(Len({0x8B, 0xEC}) == 2);
  assert(Len({0x83, 0xC4, 0xCC}) == 3);
  assert(Len({0x89, 0x65, 0xDC}) == 3);
  assert(Len({0x8D, 0x45, 0xD0}) == 3);
  assert(Len({0x8B, 0x04, 0x24}) == 3);         // SIB
  assert(Len({0x8B, 0x84, 0x24, 1, 2, 3, 4}) == 7);  // SIB + disp32
  assert(Len({0x0F, 0x84, 1, 2, 3, 4}) == 6);
  assert(Len({0xD9, 0x00}) == 0);  // 未知（x87）→ 放弃

  // RelCallDest：负向 rel32。
  {
    uint8_t buf[32] = {};
    PutCall(buf, 20, 4);
    assert(RelCallDest(buf + 20) == buf + 4);
  }

  // BCB 风格 TVPCreateIStream 函数体（try 帧序言 + 两个 imm 里藏 E8 的诱饵 + 首个真 call）。
  {
    uint8_t body[128] = {};
    size_t n = 0;
    auto put = [&](std::initializer_list<uint8_t> bytes) {
      for (uint8_t b : bytes) body[n++] = b;
    };
    put({0x55, 0x8B, 0xEC, 0x83, 0xC4, 0xCC});          // push ebp; mov ebp,esp; add esp,-34h
    put({0x53, 0x56, 0x57, 0x8B, 0xD8});                // push ebx/esi/edi; mov ebx,eax
    put({0xC7, 0x45, 0xD8, 0xE8, 0x11, 0x22, 0x33});    // mov [ebp-28h], imm32（首字节 E8 诱饵）
    put({0x89, 0x65, 0xDC});                            // mov [ebp-24h], esp
    put({0xB8, 0xE8, 0x00, 0x00, 0x00});                // mov eax, imm32（E8 诱饵）
    put({0x89, 0x45, 0xD4, 0x8B, 0xF2});                // mov [ebp-2Ch],eax; mov esi,edx
    put({0x66, 0xC7, 0x45, 0xE0, 0x00, 0x00});          // mov word [ebp-20h], 0
    put({0x33, 0xD2, 0x89, 0x55, 0xEC});                // xor edx,edx; mov [ebp-14h],edx
    put({0x64, 0x8B, 0x0D, 0, 0, 0, 0});                // mov ecx, fs:[0]
    put({0x89, 0x4D, 0xD0, 0x8D, 0x45, 0xD0});          // mov [ebp-30h],ecx; lea eax,[ebp-30h]
    put({0x64, 0xA3, 0, 0, 0, 0});                      // mov fs:[0], eax
    put({0x8B, 0xC3, 0x8B, 0xD6});                      // mov eax,ebx; mov edx,esi
    put({0x66, 0xC7, 0x45, 0xE0, 0x08, 0x00});          // mov word [ebp-20h], 8
    const size_t first_call = n;
    PutCall(body, n, 100);  // TVPCreateStream
    n += 5;
    put({0x6A, 0x0C});
    const size_t second_call = n;
    PutCall(body, n, 110);  // operator new
    n += 5;
    put({0xC3});

    auto any = [](uint8_t*) { return true; };
    assert(FindFirstAcceptedCallTarget(body, 0x100, any) == body + 100);

    // 调用方的校验拒绝第一个目标时，继续找下一个 call。
    auto not_first = [&](uint8_t* dest) { return dest != body + 100; };
    assert(FindFirstAcceptedCallTarget(body, 0x100, not_first) == body + 110);

    // 都拒绝：走到 ret 停下。
    auto none = [](uint8_t*) { return false; };
    assert(FindFirstAcceptedCallTarget(body, 0x100, none) == nullptr);

    // 窗口截在首个 call 之前 → 找不到，不会越界瞎扫。
    assert(FindFirstAcceptedCallTarget(body, static_cast<uint32_t>(first_call), any) == nullptr);
    assert(second_call == first_call + 7);

    // 中途出现未知指令 → 放弃（宁可不 hook 也不误 hook）。
    uint8_t broken[128];
    std::memcpy(broken, body, sizeof(broken));
    broken[6] = 0xD9;  // 把 push ebx 换成 x87 前缀
    assert(FindFirstAcceptedCallTarget(broken, 0x100, any) == nullptr);
  }

  return 0;
}
