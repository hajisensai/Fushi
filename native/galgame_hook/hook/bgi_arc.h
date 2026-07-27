#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace hibiki_voice_hook::bgi {

constexpr char kArc20Signature[] = "BURIKO ARC20";
constexpr size_t kArc20SignatureBytes = 12;
constexpr size_t kArc20HeaderBytes = 16;
constexpr size_t kArc20EntryBytes = 128;
constexpr size_t kArc20NameBytes = 96;
constexpr uint32_t kMaxEntryCount = 1u << 20;
constexpr uint32_t kMaxVoiceBytes = 64u * 1024u * 1024u;

struct Arc20Entry {
  char name[kArc20NameBytes + 1] = {0};
  uint64_t member_offset = 0;
  uint32_t member_size = 0;
};

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

inline bool IsArc20Index(const uint8_t* index, size_t index_bytes,
                         uint32_t* count_out = nullptr,
                         uint64_t* data_base_out = nullptr) {
  if (index == nullptr || index_bytes < kArc20HeaderBytes ||
      std::memcmp(index, kArc20Signature, kArc20SignatureBytes) != 0) {
    return false;
  }
  const uint32_t count = ReadLe32(index + kArc20SignatureBytes);
  if (count == 0 || count > kMaxEntryCount) return false;
  const uint64_t data_base = kArc20HeaderBytes +
      static_cast<uint64_t>(count) * kArc20EntryBytes;
  if (data_base > index_bytes) return false;
  if (count_out != nullptr) *count_out = count;
  if (data_base_out != nullptr) *data_base_out = data_base;
  return true;
}

inline bool FindEntryForRead(const uint8_t* index, size_t index_bytes,
                             uint64_t file_size, uint64_t read_offset,
                             Arc20Entry* out) {
  uint32_t count = 0;
  uint64_t data_base = 0;
  if (out == nullptr ||
      !IsArc20Index(index, index_bytes, &count, &data_base) ||
      data_base > file_size) {
    return false;
  }
  for (uint32_t i = 0; i < count; ++i) {
    const uint8_t* record = index + kArc20HeaderBytes +
                            static_cast<size_t>(i) * kArc20EntryBytes;
    const uint64_t relative = ReadLe32(record + 96);
    const uint32_t size = ReadLe32(record + 100);
    const uint64_t member = data_base + relative;
    if (size < 12 || member > file_size || size > file_size - member) {
      return false;
    }
    // BGI normally seeks either to the 64-byte `bw` wrapper or directly to
    // its embedded Ogg. Keep this window narrow so a large sequential archive
    // read cannot be mistaken for a later member.
    const uint64_t probe_end = member + (size < 4096 ? size : 4096);
    if (read_offset < member || read_offset >= probe_end) continue;
    std::memcpy(out->name, record, kArc20NameBytes);
    out->name[kArc20NameBytes] = 0;
    out->member_offset = member;
    out->member_size = size;
    return true;
  }
  return false;
}

inline bool ParseBwOggHeader(const uint8_t* header, size_t header_bytes,
                             uint32_t member_size, uint32_t* ogg_offset,
                             uint32_t* ogg_size) {
  if (header == nullptr || header_bytes < 12 || member_size < 12) return false;
  const uint32_t offset = ReadLe32(header);
  if (std::memcmp(header + 4, "bw  ", 4) != 0 || offset < 8 ||
      offset > member_size - 4 || offset + 4 > header_bytes ||
      std::memcmp(header + offset, "OggS", 4) != 0) {
    return false;
  }
  const uint32_t size = member_size - offset;
  if (size == 0 || size > kMaxVoiceBytes) return false;
  if (ogg_offset != nullptr) *ogg_offset = offset;
  if (ogg_size != nullptr) *ogg_size = size;
  return true;
}

}  // namespace hibiki_voice_hook::bgi
