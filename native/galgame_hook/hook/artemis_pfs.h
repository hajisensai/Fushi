#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook::artemis {

constexpr size_t kMagicBytes = 3;
constexpr size_t kMinimumHeaderBytes = 11;
constexpr size_t kIndexDataStart = 7;
constexpr size_t kEntriesStart = 11;
constexpr uint32_t kMaxIndexBytes = 32u * 1024u * 1024u;
constexpr uint32_t kMaxEntryCount = 1u << 20;
constexpr uint32_t kMaxVoiceBytes = 64u * 1024u * 1024u;
constexpr size_t kMaxNameBytes = 1024;

enum class Format : uint8_t { kInvalid, kPf6, kPf8 };

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

struct IndexInfo {
  Format format = Format::kInvalid;
  uint32_t index_size = 0;
  uint32_t entry_count = 0;
  size_t total_bytes = 0;
};

inline bool ParseIndexInfo(const uint8_t* bytes, size_t size, IndexInfo* out) {
  if (bytes == nullptr || out == nullptr || size < kMinimumHeaderBytes) {
    return false;
  }
  Format format = Format::kInvalid;
  if (std::memcmp(bytes, "pf6", kMagicBytes) == 0) {
    format = Format::kPf6;
  } else if (std::memcmp(bytes, "pf8", kMagicBytes) == 0) {
    format = Format::kPf8;
  } else {
    return false;
  }
  const uint32_t index_size = ReadLe32(bytes + 3);
  const uint32_t entry_count = ReadLe32(bytes + 7);
  const uint64_t total = kIndexDataStart + static_cast<uint64_t>(index_size);
  if (index_size < 4 || index_size > kMaxIndexBytes || entry_count == 0 ||
      entry_count > kMaxEntryCount || total > SIZE_MAX) {
    return false;
  }
  out->format = format;
  out->index_size = index_size;
  out->entry_count = entry_count;
  out->total_bytes = static_cast<size_t>(total);
  return true;
}

struct EntryView {
  const uint8_t* name = nullptr;
  uint32_t name_length = 0;
  uint32_t offset = 0;
  uint32_t size = 0;
};

struct EntryCursor {
  const uint8_t* bytes = nullptr;
  size_t index_end = 0;
  size_t position = kEntriesStart;
  uint32_t expected = 0;
  uint32_t seen = 0;
};

inline bool BeginEntries(const uint8_t* bytes, size_t size,
                         EntryCursor* cursor, IndexInfo* info_out = nullptr) {
  IndexInfo info;
  if (cursor == nullptr || !ParseIndexInfo(bytes, size, &info) ||
      info.total_bytes > size) {
    return false;
  }
  cursor->bytes = bytes;
  cursor->index_end = info.total_bytes;
  cursor->position = kEntriesStart;
  cursor->expected = info.entry_count;
  cursor->seen = 0;
  if (info_out != nullptr) *info_out = info;
  return true;
}

inline bool NextEntry(EntryCursor* cursor, uint64_t archive_size,
                      EntryView* out) {
  if (cursor == nullptr || out == nullptr || cursor->bytes == nullptr ||
      cursor->seen >= cursor->expected || cursor->position + 4 > cursor->index_end) {
    return false;
  }
  const uint8_t* bytes = cursor->bytes;
  const uint32_t name_length = ReadLe32(bytes + cursor->position);
  cursor->position += 4;
  if (name_length == 0 || name_length > kMaxNameBytes ||
      cursor->position + static_cast<size_t>(name_length) + 12 >
          cursor->index_end) {
    return false;
  }
  const uint8_t* name = bytes + cursor->position;
  cursor->position += name_length + 4;
  const uint32_t offset = ReadLe32(bytes + cursor->position);
  const uint32_t entry_size = ReadLe32(bytes + cursor->position + 4);
  cursor->position += 8;
  if (entry_size == 0 || offset > archive_size ||
      entry_size > archive_size - offset) {
    return false;
  }
  out->name = name;
  out->name_length = name_length;
  out->offset = offset;
  out->size = entry_size;
  ++cursor->seen;
  return true;
}

inline uint8_t AsciiLower(uint8_t c) {
  return c >= 'A' && c <= 'Z' ? static_cast<uint8_t>(c + ('a' - 'A')) : c;
}

inline bool StartsWithInsensitive(const uint8_t* text, size_t length,
                                  const char* prefix) {
  const size_t prefix_length = std::strlen(prefix);
  if (text == nullptr || length < prefix_length) return false;
  for (size_t i = 0; i < prefix_length; ++i) {
    if (AsciiLower(text[i]) != AsciiLower(static_cast<uint8_t>(prefix[i]))) {
      return false;
    }
  }
  return true;
}

inline bool EndsWithInsensitive(const uint8_t* text, size_t length,
                                const char* suffix) {
  const size_t suffix_length = std::strlen(suffix);
  if (text == nullptr || length < suffix_length) return false;
  const size_t start = length - suffix_length;
  for (size_t i = 0; i < suffix_length; ++i) {
    if (AsciiLower(text[start + i]) !=
        AsciiLower(static_cast<uint8_t>(suffix[i]))) {
      return false;
    }
  }
  return true;
}

inline size_t TrimmedNameLength(const EntryView& entry) {
  size_t length = entry.name_length;
  while (length > 0 && entry.name[length - 1] == 0) --length;
  return length;
}

// Artemis splits a game's data into one archive set: `<name>.pfs` plus
// numbered continuations `<name>.pfs.000`, `.001`, ... (each a complete
// PF6/PF8 archive with its own index and key; measured: アマカノ3 keeps 158
// system voices in .pfs and all 20057 dialogue voices in .pfs.000).  True for
// a file leaf that belongs to such a set.
inline bool IsArchiveSetLeaf(const wchar_t* leaf) {
  if (leaf == nullptr) return false;
  const wchar_t* dot = nullptr;
  for (const wchar_t* at = leaf; *at != 0; ++at) {
    if ((at[0] == L'.') && (at[1] == L'p' || at[1] == L'P') &&
        (at[2] == L'f' || at[2] == L'F') && (at[3] == L's' || at[3] == L'S') &&
        (at[4] == 0 || at[4] == L'.')) {
      dot = at;
    }
  }
  if (dot == nullptr || dot == leaf) return false;
  const wchar_t* suffix = dot + 4;
  if (*suffix == 0) return true;
  size_t digits = 0;
  for (++suffix; *suffix != 0; ++suffix, ++digits) {
    if (*suffix < L'0' || *suffix > L'9' || digits == 3) return false;
  }
  return digits != 0;
}

// Index of the voice range a read starting at archive byte `at` begins, or
// -1.  `ranges` is sorted by offset (`Range` has `offset`).  Artemis starts a
// voice by seeking to its entry, so only a read whose first byte is the
// entry's first byte is a playback start.  Two other reads land on voices and
// must not count (measured アマカノ3):
//  - the small sidecars laid out between voices (`X.ogg`, `X.vol.csv`,
//    `X+1.ogg`) are read through a buffer that runs on into X+1, which
//    captured X+1 alongside every X so neither paired;
//  - a voice over one read buffer is streamed: its next chunk arrives seconds
//    into playback and re-published the same voice too late to own a line.
template <typename Range>
long FindRangeStartingAt(const Range* ranges, long count, uint64_t at) {
  if (ranges == nullptr || count <= 0) return -1;
  long low = 0;
  long high = count;
  while (low < high) {
    const long middle = low + (high - low) / 2;
    if (ranges[middle].offset < at) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low < count && ranges[low].offset == at ? low : -1;
}

inline bool IsVoiceOgg(const EntryView& entry) {
  const size_t length = TrimmedNameLength(entry);
  const bool voice_directory =
      StartsWithInsensitive(entry.name, length, "sound\\vo\\") ||
      StartsWithInsensitive(entry.name, length, "sound\\sysse\\vo\\");
  return voice_directory && EndsWithInsensitive(entry.name, length, ".ogg") &&
         entry.size <= kMaxVoiceBytes;
}

}  // namespace fushi_voice_hook::artemis
