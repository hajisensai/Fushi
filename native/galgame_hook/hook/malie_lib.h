#pragma once

// Malie LIBP parsing is adapted from GARbro's ArcFormats/Malie readers.
//
// Copyright (C) 2015-2017 by morkt
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

#include "malie_cfi.h"

namespace hibiki_voice_hook::malie {

constexpr uint32_t kLibpHeaderBytes = 16;
constexpr uint32_t kLibpEntryBytes = 32;
constexpr uint32_t kLibpNameBytes = 20;
constexpr uint32_t kLibpDataAlignment = 4096;
constexpr uint32_t kLibpMemberAlignment = 1024;
constexpr uint32_t kLibpFileMask = 0x30000;
constexpr uint32_t kMaxEntries = 1u << 20;
constexpr uint32_t kMaxVoiceBytes = 64u * 1024u * 1024u;

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

inline uint64_t AlignUp(uint64_t value, uint64_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

struct LibpHeader {
  uint32_t entry_count = 0;
  uint32_t offset_count = 0;
  uint64_t index_bytes = 0;
  uint64_t data_base = 0;
};

inline bool ParseLibpHeader(const uint8_t* decrypted, size_t size,
                            uint64_t archive_size, LibpHeader* out) {
  if (decrypted == nullptr || out == nullptr || size < kLibpHeaderBytes ||
      std::memcmp(decrypted, "LIBP", 4) != 0) {
    return false;
  }
  const uint32_t entries = ReadLe32(decrypted + 4);
  const uint32_t offsets = ReadLe32(decrypted + 8);
  if (entries == 0 || entries > kMaxEntries || offsets == 0 ||
      offsets > entries) {
    return false;
  }
  const uint64_t table_bytes =
      static_cast<uint64_t>(entries) * kLibpEntryBytes;
  const uint64_t offset_bytes = static_cast<uint64_t>(offsets) * 4;
  const uint64_t index_bytes = kLibpHeaderBytes + table_bytes + offset_bytes;
  const uint64_t data_base = AlignUp(index_bytes, kLibpDataAlignment);
  if (index_bytes > archive_size || data_base > archive_size ||
      index_bytes > SIZE_MAX) {
    return false;
  }
  out->entry_count = entries;
  out->offset_count = offsets;
  out->index_bytes = index_bytes;
  out->data_base = data_base;
  return true;
}

struct LibpEntryView {
  const uint8_t* name = nullptr;
  size_t name_length = 0;
  uint32_t flags = 0;
  uint32_t offset_index = 0;
  uint32_t size = 0;
  uint64_t member_offset = 0;
};

inline bool ParseLibpEntry(const uint8_t* decrypted_index, size_t index_size,
                           const LibpHeader& header, uint32_t entry_index,
                           uint64_t archive_size, LibpEntryView* out) {
  if (decrypted_index == nullptr || out == nullptr ||
      entry_index >= header.entry_count || header.index_bytes > index_size) {
    return false;
  }
  const uint64_t entry_at = kLibpHeaderBytes +
      static_cast<uint64_t>(entry_index) * kLibpEntryBytes;
  if (entry_at + kLibpEntryBytes > header.index_bytes) return false;
  const uint8_t* entry = decrypted_index + static_cast<size_t>(entry_at);
  size_t name_length = 0;
  while (name_length < kLibpNameBytes && entry[name_length] != 0) {
    ++name_length;
  }
  const uint32_t flags = ReadLe32(entry + 20);
  const uint32_t offset_index = ReadLe32(entry + 24);
  const uint32_t member_size = ReadLe32(entry + 28);
  uint64_t member_offset = 0;
  if ((flags & kLibpFileMask) != 0) {
    if (name_length == 0 || name_length == kLibpNameBytes ||
        offset_index >= header.offset_count || member_size == 0) {
      return false;
    }
    const uint64_t offsets_at = kLibpHeaderBytes +
        static_cast<uint64_t>(header.entry_count) * kLibpEntryBytes;
    const uint8_t* offset_bytes = decrypted_index +
        static_cast<size_t>(offsets_at) + offset_index * 4;
    member_offset = header.data_base +
        static_cast<uint64_t>(ReadLe32(offset_bytes)) * kLibpMemberAlignment;
    if (member_offset > archive_size ||
        member_size > archive_size - member_offset) {
      return false;
    }
  }
  out->name = entry;
  out->name_length = name_length;
  out->flags = flags;
  out->offset_index = offset_index;
  out->size = member_size;
  out->member_offset = member_offset;
  return true;
}

inline uint8_t AsciiLower(uint8_t value) {
  return value >= 'A' && value <= 'Z'
      ? static_cast<uint8_t>(value + ('a' - 'A'))
      : value;
}

inline bool EndsWithInsensitive(const uint8_t* text, size_t length,
                                const char* suffix) {
  if (text == nullptr || suffix == nullptr) return false;
  const size_t suffix_length = std::strlen(suffix);
  if (length < suffix_length) return false;
  for (size_t i = 0; i < suffix_length; ++i) {
    if (AsciiLower(text[length - suffix_length + i]) !=
        AsciiLower(static_cast<uint8_t>(suffix[i]))) {
      return false;
    }
  }
  return true;
}

inline bool IsVoiceOgg(const LibpEntryView& entry) {
  return (entry.flags & kLibpFileMask) != 0 &&
         entry.size <= kMaxVoiceBytes &&
         EndsWithInsensitive(entry.name, entry.name_length, ".ogg");
}

}  // namespace hibiki_voice_hook::malie
