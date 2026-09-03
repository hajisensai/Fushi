#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace fushi_voice_hook::leaf_aquaplus {

inline constexpr uint32_t kLacHeaderBytes = 8u;
inline constexpr uint32_t kLacEntryBytes = 0x28u;
inline constexpr uint32_t kLacStoredNameBytes = 0x20u;
inline constexpr uint32_t kMaxEntryCount = 1u << 20;
inline constexpr uint32_t kMaxEntryBytes = 32u * 1024u * 1024u;

struct LacArchiveInfo {
  uint32_t count = 0;
  size_t index_bytes = 0;
};

struct LacEntry {
  uint32_t byte_len = 0;
  uint32_t offset = 0;
  uint32_t id = 0;
  char storage_name[kLacStoredNameBytes + 1u] = {};
};

inline uint32_t ReadLe32(const uint8_t *data) {
  uint32_t value = 0;
  std::memcpy(&value, data, sizeof(value));
  return value;
}

namespace detail {

inline bool HasOggSuffix(const char *name, size_t chars) {
  if (name == nullptr || chars < 4u)
    return false;
  const char *suffix = name + chars - 4u;
  return suffix[0] == '.' && (suffix[1] == 'o' || suffix[1] == 'O') &&
         (suffix[2] == 'g' || suffix[2] == 'G') &&
         (suffix[3] == 'g' || suffix[3] == 'G');
}

inline bool DecodeStorageName(const uint8_t *stored, char *decoded,
                              size_t decoded_chars) {
  if (stored == nullptr || decoded == nullptr ||
      decoded_chars < kLacStoredNameBytes + 1u) {
    return false;
  }
  size_t chars = 0;
  while (chars < kLacStoredNameBytes && stored[chars] != 0u) {
    const uint8_t value = static_cast<uint8_t>(~stored[chars]);
    if (value == 0u)
      return false;
    decoded[chars] = static_cast<char>(value);
    ++chars;
  }
  decoded[chars] = 0;
  return chars != 0u && HasOggSuffix(decoded, chars);
}

inline bool ReadArchiveHeader(const uint8_t *index, size_t index_bytes,
                              uint64_t file_bytes, LacArchiveInfo *out) {
  if (index == nullptr || out == nullptr || index_bytes < kLacHeaderBytes ||
      file_bytes < kLacHeaderBytes || std::memcmp(index, "LAC\0", 4) != 0) {
    return false;
  }
  const uint32_t count = ReadLe32(index + 4u);
  if (count == 0u || count > kMaxEntryCount) {
    return false;
  }
  const uint64_t table_bytes = static_cast<uint64_t>(kLacHeaderBytes) +
                               static_cast<uint64_t>(count) * kLacEntryBytes;
  if (table_bytes > file_bytes || table_bytes != index_bytes ||
      table_bytes > std::numeric_limits<size_t>::max()) {
    return false;
  }
  out->count = count;
  out->index_bytes = static_cast<size_t>(table_bytes);
  return true;
}

inline bool ReadEntryUnchecked(const uint8_t *index, const LacArchiveInfo &info,
                               uint64_t file_bytes, uint32_t id,
                               LacEntry *out) {
  if (index == nullptr || out == nullptr || id >= info.count) {
    return false;
  }
  const size_t at = static_cast<size_t>(kLacHeaderBytes) +
                    static_cast<size_t>(id) * kLacEntryBytes;
  LacEntry entry;
  entry.byte_len = ReadLe32(index + at + kLacStoredNameBytes);
  entry.offset = ReadLe32(index + at + kLacStoredNameBytes + sizeof(uint32_t));
  entry.id = id;
  const uint64_t end = static_cast<uint64_t>(entry.offset) + entry.byte_len;
  if (!DecodeStorageName(index + at, entry.storage_name,
                         sizeof(entry.storage_name)) ||
      entry.byte_len == 0u || entry.byte_len > kMaxEntryBytes ||
      entry.offset < info.index_bytes || end > file_bytes) {
    return false;
  }
  *out = entry;
  return true;
}

} // namespace detail

// Validates the complete LAC directory. The caller supplies exactly the
// 8-byte header plus count * 0x28 directory bytes, not member data. Entries
// must be ordered and non-overlapping; the first member starts after the
// directory and the final member ends at EOF. Gaps between members are valid.
inline bool ParseVoiceArchiveIndex(const uint8_t *index, size_t index_bytes,
                                   uint64_t file_bytes, LacArchiveInfo *out) {
  if (out == nullptr)
    return false;
  LacArchiveInfo info;
  if (!detail::ReadArchiveHeader(index, index_bytes, file_bytes, &info)) {
    return false;
  }
  uint64_t previous_offset = 0u;
  uint64_t previous_end = info.index_bytes;
  for (uint32_t id = 0; id < info.count; ++id) {
    LacEntry entry;
    if (!detail::ReadEntryUnchecked(index, info, file_bytes, id, &entry)) {
      return false;
    }
    const uint64_t offset = entry.offset;
    const uint64_t end = offset + entry.byte_len;
    if ((id == 0u && offset != info.index_bytes) ||
        (id != 0u && offset < previous_offset) || offset < previous_end) {
      return false;
    }
    previous_offset = offset;
    previous_end = end;
  }
  if (previous_end != file_bytes) {
    return false;
  }
  *out = info;
  return true;
}

// O(1) after ParseVoiceArchiveIndex has admitted the directory. It repeats the
// bounded header and selected-row checks so callers cannot read outside an
// untrusted buffer, but deliberately does not rescan neighbouring rows.
inline bool ReadVoiceEntryAtIndex(const uint8_t *index, size_t index_bytes,
                                  uint64_t file_bytes, uint32_t id,
                                  LacEntry *out) {
  LacArchiveInfo info;
  return detail::ReadArchiveHeader(index, index_bytes, file_bytes, &info) &&
         detail::ReadEntryUnchecked(index, info, file_bytes, id, out);
}

// Exact entry starts only. A continuation read inside an Ogg, an index read,
// or a gap between members cannot be classified as a voice resource.
inline bool FindVoiceEntryAtOffset(const uint8_t *index, size_t index_bytes,
                                   uint64_t file_bytes, uint64_t wanted_offset,
                                   LacEntry *out) {
  LacArchiveInfo info;
  if (out == nullptr ||
      !ParseVoiceArchiveIndex(index, index_bytes, file_bytes, &info) ||
      wanted_offset > std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  uint32_t first = 0u;
  uint32_t last = info.count;
  while (first < last) {
    const uint32_t middle = first + (last - first) / 2u;
    LacEntry entry;
    if (!detail::ReadEntryUnchecked(index, info, file_bytes, middle, &entry)) {
      return false;
    }
    if (wanted_offset < entry.offset) {
      last = middle;
    } else if (wanted_offset > entry.offset) {
      first = middle + 1u;
    } else {
      *out = entry;
      return true;
    }
  }
  return false;
}

// Returns the byte length through the first EOS page of one Ogg logical
// bitstream. Callers must require the result to equal LacEntry::byte_len; that
// rejects truncation, trailing bytes and concatenated resources without ever
// modifying the source bytes.
inline uint32_t CompleteOggBytes(const uint8_t *data, uint32_t bytes) {
  if (data == nullptr || bytes < 27u || bytes > kMaxEntryBytes ||
      std::memcmp(data, "OggS", 4) != 0 || data[4] != 0u) {
    return 0u;
  }
  uint32_t at = 0u;
  uint32_t serial = 0u;
  bool have_serial = false;
  while (at < bytes) {
    if (bytes - at < 27u || std::memcmp(data + at, "OggS", 4) != 0 ||
        data[at + 4u] != 0u) {
      return 0u;
    }
    const uint32_t page_serial = ReadLe32(data + at + 14u);
    if (!have_serial) {
      serial = page_serial;
      have_serial = true;
    } else if (page_serial != serial) {
      return 0u;
    }
    const uint8_t flags = data[at + 5u];
    const uint32_t segment_count = data[at + 26u];
    const uint32_t header_bytes = 27u + segment_count;
    if (header_bytes > bytes - at) {
      return 0u;
    }
    uint32_t payload_bytes = 0u;
    for (uint32_t segment = 0u; segment < segment_count; ++segment) {
      payload_bytes += data[at + 27u + segment];
    }
    const uint64_t page_bytes =
        static_cast<uint64_t>(header_bytes) + payload_bytes;
    if (page_bytes > bytes - at) {
      return 0u;
    }
    at += static_cast<uint32_t>(page_bytes);
    if ((flags & 0x04u) != 0u) {
      return at;
    }
  }
  return 0u;
}

} // namespace fushi_voice_hook::leaf_aquaplus
