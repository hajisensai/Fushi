#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

namespace fushi_voice_hook::hunex {

inline constexpr char kHunexHfaMagic[] = "HUNEXGGEFA10";
inline constexpr uint32_t kHunexHfaHeaderBytes = 16u;
inline constexpr uint32_t kHunexHfaRecordBytes = 0x80u;
inline constexpr uint32_t kHunexHfaNameBytes = 0x60u;
inline constexpr uint32_t kHunexHwHeaderBytes = 64u;
inline constexpr uint32_t kMaxHunexHfaEntries = 1u << 20;
inline constexpr uint32_t kMaxHunexHwBytes = 128u * 1024u * 1024u;

struct HunexHfaArchiveInfo {
  uint32_t count = 0u;
  size_t index_bytes = 0u;
  uint64_t data_base = 0u;
};

struct HunexHfaEntry {
  uint32_t id = 0u;
  uint32_t relative_offset = 0u;
  uint64_t absolute_offset = 0u;
  uint32_t size = 0u;
  char name[kHunexHfaNameBytes + 1u] = {};
};

struct HunexHwOggInfo {
  uint32_t payload_offset = kHunexHwHeaderBytes;
  uint32_t payload_bytes = 0u;
  uint32_t sample_count = 0u;
  uint32_t sample_rate = 0u;
  uint32_t channels = 0u;
  uint64_t final_granule = 0u;
};

enum class HunexVoiceReadKind : uint8_t {
  kNone = 0u,
  kMemberStart,
  kOggPayloadStart,
};

inline uint32_t ReadHunexLe32(const uint8_t* data) {
  uint32_t value = 0u;
  std::memcpy(&value, data, sizeof(value));
  return value;
}

inline uint64_t ReadHunexLe64(const uint8_t* data) {
  uint64_t value = 0u;
  std::memcpy(&value, data, sizeof(value));
  return value;
}

namespace detail {

inline bool IsValidUtf8(const uint8_t* data, size_t bytes) {
  if (data == nullptr) {
    return false;
  }
  size_t at = 0u;
  while (at < bytes) {
    const uint8_t first = data[at++];
    if (first <= 0x7fu) {
      continue;
    }

    uint32_t codepoint = 0u;
    uint32_t minimum = 0u;
    size_t continuation_count = 0u;
    if (first >= 0xc2u && first <= 0xdfu) {
      codepoint = first & 0x1fu;
      minimum = 0x80u;
      continuation_count = 1u;
    } else if (first >= 0xe0u && first <= 0xefu) {
      codepoint = first & 0x0fu;
      minimum = 0x800u;
      continuation_count = 2u;
    } else if (first >= 0xf0u && first <= 0xf4u) {
      codepoint = first & 0x07u;
      minimum = 0x10000u;
      continuation_count = 3u;
    } else {
      return false;
    }
    if (continuation_count > bytes - at) {
      return false;
    }
    for (size_t index = 0u; index < continuation_count; ++index) {
      const uint8_t next = data[at++];
      if ((next & 0xc0u) != 0x80u) {
        return false;
      }
      codepoint = (codepoint << 6u) | (next & 0x3fu);
    }
    if (codepoint < minimum || codepoint > 0x10ffffu ||
        (codepoint >= 0xd800u && codepoint <= 0xdfffu)) {
      return false;
    }
  }
  return true;
}

inline bool ReadArchiveHeader(const uint8_t* index, size_t index_bytes,
                              uint64_t file_bytes,
                              HunexHfaArchiveInfo* out) {
  if (index == nullptr || out == nullptr ||
      index_bytes < kHunexHfaHeaderBytes ||
      file_bytes < kHunexHfaHeaderBytes ||
      std::memcmp(index, kHunexHfaMagic, sizeof(kHunexHfaMagic) - 1u) != 0) {
    return false;
  }
  const uint32_t count = ReadHunexLe32(index + 12u);
  if (count == 0u || count > kMaxHunexHfaEntries) {
    return false;
  }
  const uint64_t table_bytes =
      static_cast<uint64_t>(kHunexHfaHeaderBytes) +
      static_cast<uint64_t>(count) * kHunexHfaRecordBytes;
  if (table_bytes > file_bytes ||
      table_bytes > std::numeric_limits<size_t>::max() ||
      table_bytes != index_bytes) {
    return false;
  }
  out->count = count;
  out->index_bytes = static_cast<size_t>(table_bytes);
  out->data_base = table_bytes;
  return true;
}

inline bool ReadEntryUnchecked(const uint8_t* index,
                               const HunexHfaArchiveInfo& info,
                               uint64_t file_bytes, uint32_t id,
                               HunexHfaEntry* out) {
  if (index == nullptr || out == nullptr || id >= info.count) {
    return false;
  }
  const size_t record_at = static_cast<size_t>(kHunexHfaHeaderBytes) +
                           static_cast<size_t>(id) * kHunexHfaRecordBytes;
  const uint8_t* record = index + record_at;
  size_t name_bytes = 0u;
  while (name_bytes < kHunexHfaNameBytes && record[name_bytes] != 0u) {
    ++name_bytes;
  }
  if (name_bytes == 0u || name_bytes == kHunexHfaNameBytes ||
      !IsValidUtf8(record, name_bytes)) {
    return false;
  }

  HunexHfaEntry entry;
  entry.id = id;
  entry.relative_offset = ReadHunexLe32(record + kHunexHfaNameBytes);
  entry.size = ReadHunexLe32(record + kHunexHfaNameBytes + 4u);
  entry.absolute_offset =
      info.data_base + static_cast<uint64_t>(entry.relative_offset);
  if (entry.size == 0u || entry.size > kMaxHunexHwBytes ||
      entry.absolute_offset >
          std::numeric_limits<uint64_t>::max() - entry.size ||
      entry.absolute_offset + entry.size > file_bytes) {
    return false;
  }
  std::memcpy(entry.name, record, name_bytes);
  entry.name[name_bytes] = '\0';
  *out = entry;
  return true;
}

inline bool HasHwSuffix(const char* name) {
  if (name == nullptr) {
    return false;
  }
  const size_t chars = std::strlen(name);
  if (chars < 3u) {
    return false;
  }
  const char* suffix = name + chars - 3u;
  return suffix[0] == '.' && (suffix[1] == 'h' || suffix[1] == 'H') &&
         (suffix[2] == 'w' || suffix[2] == 'W');
}

inline bool ParseCompleteOgg(const uint8_t* ogg, size_t ogg_bytes,
                             uint64_t* final_granule) {
  if (ogg == nullptr || final_granule == nullptr || ogg_bytes < 28u ||
      std::memcmp(ogg, "OggS", 4u) != 0 || ogg[4u] != 0u) {
    return false;
  }

  size_t at = 0u;
  uint32_t serial = 0u;
  uint32_t expected_sequence = 0u;
  bool first_page = true;
  while (at < ogg_bytes) {
    if (ogg_bytes - at < 27u ||
        std::memcmp(ogg + at, "OggS", 4u) != 0 || ogg[at + 4u] != 0u) {
      return false;
    }
    const uint8_t flags = ogg[at + 5u];
    if ((flags & 0xf8u) != 0u) {
      return false;
    }
    const uint32_t page_serial = ReadHunexLe32(ogg + at + 14u);
    const uint32_t page_sequence = ReadHunexLe32(ogg + at + 18u);
    if (first_page) {
      if ((flags & 0x02u) == 0u || (flags & 0x01u) != 0u ||
          page_sequence != 0u) {
        return false;
      }
      serial = page_serial;
      expected_sequence = 0u;
      first_page = false;
    } else if ((flags & 0x02u) != 0u || page_serial != serial ||
               page_sequence != expected_sequence) {
      return false;
    }

    const size_t segment_count = ogg[at + 26u];
    const size_t header_bytes = 27u + segment_count;
    if (header_bytes > ogg_bytes - at) {
      return false;
    }
    size_t payload_bytes = 0u;
    for (size_t segment = 0u; segment < segment_count; ++segment) {
      payload_bytes += ogg[at + 27u + segment];
    }
    if (payload_bytes > ogg_bytes - at - header_bytes) {
      return false;
    }
    const size_t page_bytes = header_bytes + payload_bytes;
    at += page_bytes;
    ++expected_sequence;
    if ((flags & 0x04u) != 0u) {
      if (at != ogg_bytes) {
        return false;
      }
      *final_granule = ReadHunexLe64(ogg + at - page_bytes + 6u);
      return true;
    }
  }
  return false;
}

}  // namespace detail

// The caller supplies exactly the 16-byte header plus count * 0x80 directory
// bytes. Member offsets are relative to the first byte after that directory.
// Directory order and gaps are not semantic; ambiguous overlaps are rejected.
// This parser allocates scratch storage and therefore belongs on HookWorker,
// never in a CreateFile/ReadFile detour.
inline bool ParseHunexHfaIndex(const uint8_t* index, size_t index_bytes,
                               uint64_t file_bytes,
                               HunexHfaArchiveInfo* out) {
  if (out == nullptr) {
    return false;
  }
  HunexHfaArchiveInfo info;
  if (!detail::ReadArchiveHeader(index, index_bytes, file_bytes, &info)) {
    return false;
  }
  std::vector<std::pair<uint64_t, uint64_t>> ranges;
  ranges.reserve(info.count);
  for (uint32_t id = 0u; id < info.count; ++id) {
    HunexHfaEntry entry;
    if (!detail::ReadEntryUnchecked(index, info, file_bytes, id, &entry)) {
      return false;
    }
    ranges.emplace_back(entry.absolute_offset,
                        entry.absolute_offset + entry.size);
  }
  std::sort(ranges.begin(), ranges.end());
  for (size_t index_value = 1u; index_value < ranges.size(); ++index_value) {
    if (ranges[index_value].first < ranges[index_value - 1u].second) {
      return false;
    }
  }
  *out = info;
  return true;
}

// O(1) selected-row decode after ParseHunexHfaIndex has validated the complete
// directory. This repeats all selected-row bounds and UTF-8 checks but does not
// rescan neighbouring records for overlaps.
inline bool ReadHunexHfaEntryAtIndex(const uint8_t* index, size_t index_bytes,
                                     uint64_t file_bytes, uint32_t id,
                                     HunexHfaEntry* out) {
  HunexHfaArchiveInfo info;
  return detail::ReadArchiveHeader(index, index_bytes, file_bytes, &info) &&
         detail::ReadEntryUnchecked(index, info, file_bytes, id, out);
}

// A HUNEX HW member is a fixed 64-byte metadata wrapper followed by exactly
// one complete Ogg logical stream. Bytes 0x18..0x3f are intentionally opaque.
// Channel count is metadata, not a voice-role classifier: both mono and stereo
// (and other non-zero values) are admitted by this structural parser.
inline bool ParseHunexHwOgg(const uint8_t* member, size_t member_bytes,
                            HunexHwOggInfo* out) {
  if (member == nullptr || out == nullptr ||
      member_bytes < kHunexHwHeaderBytes + 28u ||
      member_bytes > kMaxHunexHwBytes ||
      ReadHunexLe32(member) != kHunexHwHeaderBytes ||
      std::memcmp(member + 4u, "hw  ", 4u) != 0) {
    return false;
  }
  const uint32_t payload_bytes = ReadHunexLe32(member + 8u);
  const uint32_t sample_count = ReadHunexLe32(member + 12u);
  const uint32_t sample_rate = ReadHunexLe32(member + 16u);
  const uint32_t channels = ReadHunexLe32(member + 20u);
  if (payload_bytes != member_bytes - kHunexHwHeaderBytes ||
      sample_count == 0u || sample_rate == 0u || channels == 0u) {
    return false;
  }
  uint64_t final_granule = 0u;
  if (!detail::ParseCompleteOgg(member + kHunexHwHeaderBytes, payload_bytes,
                                &final_granule) ||
      final_granule != sample_count) {
    return false;
  }
  out->payload_offset = kHunexHwHeaderBytes;
  out->payload_bytes = payload_bytes;
  out->sample_count = sample_count;
  out->sample_rate = sample_rate;
  out->channels = channels;
  out->final_granule = final_granule;
  return true;
}

// Classifies only exact member and Ogg-payload starts. Interior, index/preload,
// cross-member and overflowing reads are rejected. The first four returned
// bytes are part of the contract so a worker never promotes a mere offset hit.
inline HunexVoiceReadKind ClassifyHunexVoiceRead(
    const uint8_t* index, size_t index_bytes, uint64_t file_bytes,
    uint64_t read_offset, uint32_t read_bytes, const uint8_t* read_prefix,
    size_t prefix_bytes, HunexHfaEntry* out) {
  if (out == nullptr || read_prefix == nullptr || prefix_bytes < 4u ||
      read_bytes < 4u ||
      read_offset > std::numeric_limits<uint64_t>::max() - read_bytes) {
    return HunexVoiceReadKind::kNone;
  }
  HunexHfaArchiveInfo info;
  if (!ParseHunexHfaIndex(index, index_bytes, file_bytes, &info)) {
    return HunexVoiceReadKind::kNone;
  }
  for (uint32_t id = 0u; id < info.count; ++id) {
    HunexHfaEntry entry;
    if (!detail::ReadEntryUnchecked(index, info, file_bytes, id, &entry) ||
        !detail::HasHwSuffix(entry.name) ||
        entry.size <= kHunexHwHeaderBytes) {
      continue;
    }
    const uint64_t entry_end = entry.absolute_offset + entry.size;
    if (read_offset + read_bytes > entry_end) {
      continue;
    }
    if (read_offset == entry.absolute_offset &&
        ReadHunexLe32(read_prefix) == kHunexHwHeaderBytes) {
      *out = entry;
      return HunexVoiceReadKind::kMemberStart;
    }
    if (read_offset == entry.absolute_offset + kHunexHwHeaderBytes &&
        std::memcmp(read_prefix, "OggS", 4u) == 0) {
      *out = entry;
      return HunexVoiceReadKind::kOggPayloadStart;
    }
  }
  return HunexVoiceReadKind::kNone;
}

}  // namespace fushi_voice_hook::hunex
