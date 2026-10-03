#pragma once

// YU-RIS `YPF` archive index: pure parsing, no Windows dependency.
//
// Layout (all little endian; read byte by byte from two generations of real
// archives, a 2011 v500 title and a 2017 v481 title):
//
//   +0  "YPF\0"   +4 u32 version   +8 u32 count   +12 u32 index_end
//   +16 16 zero bytes
//   +32 count entries, back to back, up to index_end (absolute):
//       u32 name_hash
//       u8  encoded name length: L = table[byte ^ 0xff]
//       L   name bytes, each XOR 0xff (CP932 path, e.g. `voice\xxx.ogg`)
//       u8  type        u8 packed (0 stored, 1 zlib)
//       u32 unpacked size   u32 stored size
//       u32 or u64 member offset (absolute)      <- width differs per build
//       u32 check (Adler-32 of the stored bytes, or 0 when the build omits it)
//
// The engine builds `table` at start-up as the identity with twelve fixed
// pairs swapped; older builds may not swap.  Neither the table variant nor the
// offset width is predictable from the version number (v500 uses 32-bit
// offsets, the later v481 build 64-bit), so both are decided structurally: a
// layout is accepted only when every one of `count` entries parses, every
// member lies after the index and inside the file, stored members have equal
// sizes, and the last entry ends exactly at index_end.  Two layouts that both
// pass but disagree on any entry reject the archive (fail closed).

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook::yuris {

constexpr uint32_t kYpfMagic = 0x00465059u;  // "YPF\0"
constexpr size_t kYpfHeaderBytes = 32u;
constexpr uint32_t kYpfMaxEntries = 1u << 20;
constexpr uint32_t kYpfMaxIndexBytes = 64u << 20;
constexpr size_t kYpfMaxNameBytes = 255u;

// Name-length pairs the engine swaps in its decode table (identity elsewhere).
constexpr uint8_t kYpfLengthSwaps[][2] = {
    {3, 72},  {6, 53},  {9, 11},  {12, 16}, {13, 19}, {17, 25},
    {21, 27}, {28, 30}, {32, 35}, {38, 41}, {44, 47}, {46, 50}};

inline uint32_t Le32(const uint8_t* p) {
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
         (static_cast<uint32_t>(p[2]) << 16) |
         (static_cast<uint32_t>(p[3]) << 24);
}

inline uint64_t Le64(const uint8_t* p) {
  return static_cast<uint64_t>(Le32(p)) |
         (static_cast<uint64_t>(Le32(p + 4)) << 32);
}

struct YpfHeader {
  uint32_t version = 0u;
  uint32_t count = 0u;
  uint32_t index_end = 0u;  // absolute offset where member data may begin
};

inline bool ParseYpfHeader(const uint8_t* bytes, size_t size,
                           uint64_t file_size, YpfHeader* out) {
  if (bytes == nullptr || size < kYpfHeaderBytes || Le32(bytes) != kYpfMagic) {
    return false;
  }
  YpfHeader header;
  header.version = Le32(bytes + 4);
  header.count = Le32(bytes + 8);
  header.index_end = Le32(bytes + 12);
  if (header.count == 0u || header.count > kYpfMaxEntries ||
      header.index_end <= kYpfHeaderBytes ||
      header.index_end - kYpfHeaderBytes > kYpfMaxIndexBytes ||
      (file_size != 0u && header.index_end > file_size)) {
    return false;
  }
  for (size_t i = 16u; i < kYpfHeaderBytes; ++i) {
    if (bytes[i] != 0u) return false;
  }
  if (out != nullptr) *out = header;
  return true;
}

struct YpfLayout {
  bool swapped_lengths = false;
  uint32_t offset_bytes = 0u;  // 4 or 8; 0 = no layout
};

struct YpfEntry {
  uint32_t name_hash = 0u;
  uint32_t name_bytes = 0u;
  char name[kYpfMaxNameBytes + 1u] = {};  // decoded CP932, NUL-terminated
  uint8_t type = 0u;
  bool packed = false;
  uint32_t unpacked_size = 0u;
  uint32_t stored_size = 0u;
  uint64_t offset = 0u;
  uint32_t check = 0u;
};

inline uint8_t DecodeYpfNameLength(uint8_t encoded, bool swapped) {
  const uint8_t value = static_cast<uint8_t>(encoded ^ 0xffu);
  if (!swapped) return value;
  for (const auto& pair : kYpfLengthSwaps) {
    if (value == pair[0]) return pair[1];
    if (value == pair[1]) return pair[0];
  }
  return value;
}

// Parses the entry at *cursor (relative to `index`, which holds the bytes
// from absolute offset 32 up to index_end) and advances the cursor.
inline bool ReadYpfEntry(const uint8_t* index, size_t index_bytes,
                         const YpfHeader& header, const YpfLayout& layout,
                         uint64_t file_size, size_t* cursor, YpfEntry* out) {
  if (index == nullptr || cursor == nullptr || layout.offset_bytes == 0u) {
    return false;
  }
  size_t p = *cursor;
  if (p > index_bytes || index_bytes - p < 5u) return false;
  const uint32_t length = DecodeYpfNameLength(index[p + 4], layout.swapped_lengths);
  const size_t tail = 10u + layout.offset_bytes + 4u;
  if (length == 0u || index_bytes - p - 5u < length + tail) return false;
  const uint8_t* name = index + p + 5u;
  const uint8_t* fields = name + length;
  const uint8_t packed = fields[1];
  const uint32_t unpacked = Le32(fields + 2);
  const uint32_t stored = Le32(fields + 6);
  const uint64_t offset = layout.offset_bytes == 8u ? Le64(fields + 10)
                                                    : Le32(fields + 10);
  if (packed > 1u || offset < header.index_end ||
      (file_size != 0u &&
       (offset > file_size || stored > file_size - offset)) ||
      (packed == 0u && unpacked != stored)) {
    return false;
  }
  if (out != nullptr) {
    out->name_hash = Le32(index + p);
    out->name_bytes = length;
    for (uint32_t i = 0; i < length; ++i) {
      out->name[i] = static_cast<char>(name[i] ^ 0xffu);
    }
    out->name[length] = '\0';
    out->type = fields[0];
    out->packed = packed != 0u;
    out->unpacked_size = unpacked;
    out->stored_size = stored;
    out->offset = offset;
    out->check = Le32(fields + 10 + layout.offset_bytes);
  }
  *cursor = p + 5u + length + tail;
  return true;
}

}  // namespace fushi_voice_hook::yuris
