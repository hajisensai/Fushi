#pragma once

// Malie CFI decryption is adapted from GARbro's MalieEncryption.cs.
//
// Copyright (C) 2017 by morkt
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace hibiki_voice_hook::malie {

inline constexpr uint8_t kDiesAmantesCfiKey[32] = {
    0xA4, 0xA7, 0xA6, 0xA1, 0xA0, 0xA3, 0xA2, 0xAC,
    0xAF, 0xAE, 0xA9, 0xA8, 0xAB, 0xAA, 0xB4, 0xB7,
    0xB6, 0xB1, 0xB0, 0xB3, 0xB2, 0xBC, 0xBF, 0xBE,
    0xB9, 0xB8, 0xBB, 0xBA, 0xA1, 0xA9, 0xB1, 0xB9,
};

inline constexpr uint32_t kDiesAmantesCfiRotateKey[4] = {
    0x39653542, 0x76706367, 0x69454462, 0x71334334,
};

inline uint32_t RotateRight(uint32_t value, uint32_t count) {
  count &= 31;
  return count == 0 ? value : (value >> count) | (value << (32 - count));
}

inline uint32_t RotateLeft(uint32_t value, uint32_t count) {
  count &= 31;
  return count == 0 ? value : (value << count) | (value >> (32 - count));
}

inline void DecryptCfiBlock(uint64_t block_offset, const uint8_t* encrypted,
                            uint8_t* decrypted) {
  std::memcpy(decrypted, encrypted, 16);
  const uint32_t byte_offset = static_cast<uint32_t>(block_offset);
  const uint32_t pivot_index = byte_offset & 0xF;
  const uint8_t pivot = decrypted[pivot_index];
  for (uint32_t i = 0; i < 16; ++i) {
    if (i != pivot_index) decrypted[i] ^= pivot;
  }

  const uint32_t block_index = byte_offset >> 4;
  uint32_t words[4] = {};
  std::memcpy(words, decrypted, sizeof(words));
  uint32_t key = RotateRight(
      kDiesAmantesCfiRotateKey[0],
      kDiesAmantesCfiKey[block_index & 0x1F] ^ 0xA5);
  words[0] = RotateRight(
      words[0] ^ key,
      kDiesAmantesCfiKey[(block_index + 12) & 0x1F] ^ 0xA5);
  key = RotateLeft(
      kDiesAmantesCfiRotateKey[1],
      kDiesAmantesCfiKey[(block_index + 3) & 0x1F] ^ 0xA5);
  words[1] = RotateLeft(
      words[1] ^ key,
      kDiesAmantesCfiKey[(block_index + 15) & 0x1F] ^ 0xA5);
  key = RotateRight(
      kDiesAmantesCfiRotateKey[2],
      kDiesAmantesCfiKey[(block_index + 6) & 0x1F] ^ 0xA5);
  words[2] = RotateRight(
      words[2] ^ key,
      kDiesAmantesCfiKey[(block_index + 18) & 0x1F] ^ 0xA5);
  key = RotateLeft(
      kDiesAmantesCfiRotateKey[3],
      kDiesAmantesCfiKey[(block_index + 9) & 0x1F] ^ 0xA5);
  words[3] = RotateLeft(
      words[3] ^ key,
      kDiesAmantesCfiKey[(block_index + 21) & 0x1F] ^ 0xA5);
  std::memcpy(decrypted, words, sizeof(words));
}

inline bool DecryptCfiRange(uint64_t offset, const uint8_t* encrypted,
                            size_t size, uint8_t* decrypted) {
  if (encrypted == nullptr || decrypted == nullptr || (offset & 0xF) != 0 ||
      (size & 0xF) != 0) {
    return false;
  }
  for (size_t at = 0; at < size; at += 16) {
    DecryptCfiBlock(offset + at, encrypted + at, decrypted + at);
  }
  return true;
}

}  // namespace hibiki_voice_hook::malie
