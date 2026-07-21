#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace hibiki_voice_hook::siglus {

constexpr uint32_t kOvkEntryBytes = 16;
constexpr uint32_t kMaxEntryBytes = 32u * 1024u * 1024u;
constexpr uint32_t kMaxEntryCount = 1u << 20;

struct OvkEntry {
  uint32_t byte_len = 0;
  uint32_t offset = 0;
  uint32_t duration = 0;
  uint32_t id = 0;
};

inline uint32_t ReadLe32(const uint8_t* data) {
  uint32_t value = 0;
  std::memcpy(&value, data, sizeof(value));
  return value;
}

// Siglus 的 koe/*.ovk：u32 count，随后 count 个 16-byte 索引项；每项前两列分别是
// OGG 字节数与绝对文件偏移。只接受索引内精确命中的 Ogg 起点，避免把 BGM/SE 或随机数据
// 当作角色语音导出。
inline bool FindEntryAtOffset(const uint8_t* index, size_t index_bytes,
                              uint64_t file_bytes, uint64_t wanted_offset,
                              OvkEntry* out) {
  if (index == nullptr || out == nullptr || index_bytes < sizeof(uint32_t)) {
    return false;
  }
  const uint32_t count = ReadLe32(index);
  if (count == 0 || count > kMaxEntryCount) {
    return false;
  }
  const uint64_t table_bytes = sizeof(uint32_t) +
                               static_cast<uint64_t>(count) * kOvkEntryBytes;
  if (table_bytes > index_bytes || table_bytes > file_bytes) {
    return false;
  }
  for (uint32_t i = 0; i < count; ++i) {
    const uint8_t* row = index + sizeof(uint32_t) +
                         static_cast<size_t>(i) * kOvkEntryBytes;
    OvkEntry entry;
    entry.byte_len = ReadLe32(row);
    entry.offset = ReadLe32(row + 4);
    entry.duration = ReadLe32(row + 8);
    entry.id = ReadLe32(row + 12);
    if (entry.offset != wanted_offset) {
      continue;
    }
    const uint64_t end = static_cast<uint64_t>(entry.offset) + entry.byte_len;
    if (entry.byte_len == 0 || entry.byte_len > kMaxEntryBytes ||
        entry.offset < table_bytes || end > file_bytes) {
      return false;
    }
    *out = entry;
    return true;
  }
  return false;
}

// 返回 buffer 中首个完整 Ogg logical bitstream 的长度；缺页/EOS/越界时返回 0。
// OVK 索引给的是精确 entry 长度，但仍验 Ogg 页结构，防损坏归档诱导任意大文件落盘。
inline uint32_t CompleteOggBytes(const uint8_t* data, uint32_t bytes) {
  if (data == nullptr || bytes < 27 || bytes > kMaxEntryBytes ||
      std::memcmp(data, "OggS", 4) != 0 || data[4] != 0) {
    return 0;
  }
  uint32_t at = 0;
  uint32_t serial = 0;
  bool have_serial = false;
  while (at < bytes) {
    if (bytes - at < 27 || std::memcmp(data + at, "OggS", 4) != 0 ||
        data[at + 4] != 0) {
      return 0;
    }
    const uint32_t page_serial = ReadLe32(data + at + 14);
    if (!have_serial) {
      serial = page_serial;
      have_serial = true;
    } else if (page_serial != serial) {
      return 0;
    }
    const uint8_t flags = data[at + 5];
    const uint32_t segment_count = data[at + 26];
    const uint32_t header_bytes = 27 + segment_count;
    if (header_bytes > bytes - at) {
      return 0;
    }
    uint32_t payload_bytes = 0;
    for (uint32_t i = 0; i < segment_count; ++i) {
      payload_bytes += data[at + 27 + i];
    }
    const uint64_t page_bytes =
        static_cast<uint64_t>(header_bytes) + payload_bytes;
    if (page_bytes > bytes - at) {
      return 0;
    }
    at += static_cast<uint32_t>(page_bytes);
    if ((flags & 0x04u) != 0) {
      return at;
    }
  }
  return 0;
}

}  // namespace hibiki_voice_hook::siglus
