#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace hibiki_voice_hook::elf_ai6 {

constexpr size_t kHeaderBytes = 4;
constexpr size_t kEntryBytes = 272;
constexpr size_t kNameBytes = 256;
constexpr uint32_t kMaxEntryCount = 1u << 20;
constexpr uint32_t kMaxVoiceBytes = 64u * 1024u * 1024u;

struct ArcEntry {
  char name[kNameBytes + 1] = {0};
  uint64_t offset = 0;
  uint32_t size = 0;
};

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

inline uint32_t ReadBe32(const uint8_t* bytes) {
  return (static_cast<uint32_t>(bytes[0]) << 24) |
         (static_cast<uint32_t>(bytes[1]) << 16) |
         (static_cast<uint32_t>(bytes[2]) << 8) |
         static_cast<uint32_t>(bytes[3]);
}

inline bool IndexSize(const uint8_t* prefix, size_t prefix_bytes,
                      uint32_t* count_out, uint64_t* index_bytes_out) {
  if (prefix == nullptr || prefix_bytes < kHeaderBytes) return false;
  const uint32_t count = ReadLe32(prefix);
  if (count == 0 || count > kMaxEntryCount) return false;
  const uint64_t index_bytes = kHeaderBytes +
      static_cast<uint64_t>(count) * kEntryBytes;
  if (count_out != nullptr) *count_out = count;
  if (index_bytes_out != nullptr) *index_bytes_out = index_bytes;
  return true;
}

inline bool ParseEntry(const uint8_t* index, size_t index_bytes,
                       uint64_t file_size, uint32_t entry_index,
                       ArcEntry* out) {
  uint32_t count = 0;
  uint64_t expected_index_bytes = 0;
  if (out == nullptr ||
      !IndexSize(index, index_bytes, &count, &expected_index_bytes) ||
      entry_index >= count || expected_index_bytes > index_bytes ||
      expected_index_bytes > file_size) {
    return false;
  }
  const uint8_t* record = index + kHeaderBytes +
      static_cast<size_t>(entry_index) * kEntryBytes;
  const uint32_t packed_size = ReadBe32(record + kNameBytes + 4);
  const uint32_t unpacked_size = ReadBe32(record + kNameBytes + 8);
  const uint64_t offset = ReadBe32(record + kNameBytes + 12);
  if (packed_size < 4 || packed_size > kMaxVoiceBytes ||
      packed_size != unpacked_size || offset < expected_index_bytes ||
      offset > file_size || packed_size > file_size - offset) {
    return false;
  }
  std::memcpy(out->name, record, kNameBytes);
  out->name[kNameBytes] = 0;
  out->offset = offset;
  out->size = packed_size;
  return true;
}

inline bool FindEntryForRead(const uint8_t* index, size_t index_bytes,
                             uint64_t file_size, uint64_t read_offset,
                             ArcEntry* out) {
  uint32_t count = 0;
  if (out == nullptr || !IndexSize(index, index_bytes, &count, nullptr)) {
    return false;
  }
  uint32_t low = 0;
  uint32_t high = count;
  while (low < high) {
    const uint32_t mid = low + (high - low) / 2;
    ArcEntry candidate;
    if (!ParseEntry(index, index_bytes, file_size, mid, &candidate)) {
      return false;
    }
    if (read_offset < candidate.offset) {
      high = mid;
      continue;
    }
    if (read_offset >= candidate.offset + candidate.size) {
      low = mid + 1;
      continue;
    }
    *out = candidate;
    return true;
  }
  return false;
}

}  // namespace hibiki_voice_hook::elf_ai6
