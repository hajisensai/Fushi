#pragma once

#include <cstddef>
#include <cstdint>

namespace hibiki_voice_hook::siglus {

constexpr size_t kInvalidTextFunctionOffset = static_cast<size_t>(-1);

// Siglus 3 的 UTF-16 文本赋值函数内部特征。该特征来自 LunaTranslator 当前
// EmbedSiglus2 实现，但这里只移植“定位原始文本对象”这一小段；Hibiki 自己负责把
// TextUnionW 写入共享文本环，不加载/依赖 Luna 的旧引擎数据库。
//
// XX 位置是版本相关的寄存器/短跳偏移。固定字节覆盖 std::wstring 扩容到 0x100
// 字符的分支，足以避开普通 UI/容器函数的误命中。
inline bool MatchesExactTextBody(const uint8_t* bytes, size_t remaining) {
  constexpr size_t kPatternBytes = 36;
  if (bytes == nullptr || remaining < kPatternBytes) return false;

  return bytes[0] == 0x81 &&
         bytes[3] == 0x00 && bytes[4] == 0x01 && bytes[5] == 0x00 &&
         bytes[6] == 0x00 && bytes[7] == 0x7e &&
         bytes[9] == 0x8b && bytes[10] == 0x4e && bytes[11] == 0x10 &&
         bytes[12] == 0x81 && bytes[13] == 0xf9 &&
         bytes[14] == 0x00 && bytes[15] == 0x01 && bytes[16] == 0x00 &&
         bytes[17] == 0x00 && bytes[18] == 0x72 &&
         bytes[20] == 0xc7 && bytes[21] == 0x46 && bytes[22] == 0x10 &&
         bytes[23] == 0x00 && bytes[24] == 0x01 && bytes[25] == 0x00 &&
         bytes[26] == 0x00 && bytes[27] == 0x83 && bytes[28] == 0x7e &&
         bytes[29] == 0x14 && bytes[30] == 0x07 && bytes[31] == 0x76 &&
         bytes[32] == 0x02 && bytes[33] == 0x8b && bytes[34] == 0x36;
}

inline bool IsPaddingByte(uint8_t value) {
  return value == 0xcc || value == 0x90;
}

// 从函数体特征回溯到 16-byte 对齐、前方至少 4 byte INT3/NOP padding 的函数入口。
// anemoi 当前二进制的命中关系是 +0x25C8AB -> +0x25C880；不把 RVA 写死，后续
// Siglus 小版本只要保留同一容器实现即可继续匹配。
inline size_t FindExactTextFunctionOffset(const uint8_t* image,
                                          size_t image_bytes) {
  constexpr size_t kPatternBytes = 36;
  constexpr size_t kMaxFunctionBytes = 0x400;
  constexpr size_t kRequiredPadding = 4;
  if (image == nullptr || image_bytes < kPatternBytes) {
    return kInvalidTextFunctionOffset;
  }

  for (size_t body = 0; body + kPatternBytes <= image_bytes; ++body) {
    if (!MatchesExactTextBody(image + body, image_bytes - body)) continue;

    const size_t floor = body > kMaxFunctionBytes ? body - kMaxFunctionBytes : 0;
    for (size_t candidate = body; candidate > floor; --candidate) {
      if ((candidate & 0xfu) != 0 || candidate < kRequiredPadding) continue;
      bool padded = true;
      for (size_t i = 1; i <= kRequiredPadding; ++i) {
        if (!IsPaddingByte(image[candidate - i])) {
          padded = false;
          break;
        }
      }
      if (padded && !IsPaddingByte(image[candidate])) return candidate;
    }
  }
  return kInvalidTextFunctionOffset;
}

}  // namespace hibiki_voice_hook::siglus
