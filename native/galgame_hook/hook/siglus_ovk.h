#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace fushi_voice_hook::siglus {

constexpr uint32_t kOvkEntryBytes = 16;
constexpr uint32_t kMaxEntryBytes = 32u * 1024u * 1024u;
constexpr uint32_t kMaxEntryCount = 1u << 20;

struct OvkEntry {
  uint32_t byte_len = 0;
  uint32_t offset = 0;
  uint32_t member_id = 0;
  uint32_t sample_count = 0;
};

// The member key is archive-local. Equal-length voices may have the same
// sample count, so that count must never identify an exported resource.
inline std::wstring BuildOvkVoiceStorageName(const wchar_t* archive_basename,
                                            const OvkEntry& entry) {
  return std::wstring(archive_basename) + L"_" +
         std::to_wstring(entry.member_id) + L".ogg";
}

inline uint32_t ReadLe32(const uint8_t* data) {
  uint32_t value = 0;
  std::memcpy(&value, data, sizeof(value));
  return value;
}

constexpr uint32_t kVoiceMemberIndexDomain = 100000;
constexpr size_t kVoiceMemberIndexScratchBytes =
    (kVoiceMemberIndexDomain + 7u) / 8u;

// Additional worker-only gate for the proved archive*100000+member voice ABI.
// Keep legacy offset lookup below unchanged. The caller supplies a separate
// heap/static scratch buffer (12.5 KB), never a large hook-stack allocation.
// Scratch is reset on each call; its contents after failure are unspecified.
// This validates every row and unique member identity, not Ogg payloads, file
// identity, playback role, or a binding to a committed dialogue event.
inline bool ValidateUniqueVoiceMemberIndex(const uint8_t* index,
                                          size_t index_bytes,
                                          uint64_t file_bytes,
                                          uint8_t* member_scratch,
                                          size_t scratch_bytes) {
  if (index == nullptr || index_bytes < sizeof(uint32_t) ||
      member_scratch == nullptr ||
      scratch_bytes < kVoiceMemberIndexScratchBytes) return false;
  const uint32_t count = ReadLe32(index);
  if (count == 0 || count > kMaxEntryCount ||
      count > kVoiceMemberIndexDomain) return false;
  const uint64_t table_bytes = sizeof(uint32_t) +
      static_cast<uint64_t>(count) * kOvkEntryBytes;
  if (table_bytes > index_bytes || table_bytes > file_bytes) return false;
  // Reject aliasing before clearing scratch, so validation cannot mutate its
  // own input. Difference comparisons also avoid pointer-range overflow.
  const uintptr_t source = reinterpret_cast<uintptr_t>(index);
  const uintptr_t scratch = reinterpret_cast<uintptr_t>(member_scratch);
  if ((scratch >= source && scratch - source < table_bytes) ||
      (source > scratch && source - scratch < kVoiceMemberIndexScratchBytes))
    return false;
  std::memset(member_scratch, 0, kVoiceMemberIndexScratchBytes);
  for (uint32_t i = 0; i < count; ++i) {
    const uint8_t* row = index + sizeof(uint32_t) +
        static_cast<size_t>(i) * kOvkEntryBytes;
    const uint32_t length = ReadLe32(row);
    const uint32_t offset = ReadLe32(row + 4);
    const uint32_t member = ReadLe32(row + 8);
    if (length == 0 || length > kMaxEntryBytes || offset < table_bytes ||
        static_cast<uint64_t>(offset) + length > file_bytes ||
        member >= kVoiceMemberIndexDomain) return false;
    const uint8_t bit = static_cast<uint8_t>(1u << (member % 8u));
    uint8_t& seen = member_scratch[member / 8u];
    if ((seen & bit) != 0) return false;
    seen |= bit;
  }
  return true;
}

// Siglus 的 koe/*.ovk：u32 count，随后 count 个 16-byte 索引项；每项前两列分别是
// Ogg 字节数、绝对文件偏移、归档内成员 ID、PCM sample count。成员 ID 是引擎查找
// 的键；sample count 对应 Vorbis EOS granule，不是 ID 或毫秒时长。精确起点与边界
// 校验只证明资源结构，不证明声道角色、播放事件或正文归属。
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
    entry.member_id = ReadLe32(row + 8);
    entry.sample_count = ReadLe32(row + 12);
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

}  // namespace fushi_voice_hook::siglus
