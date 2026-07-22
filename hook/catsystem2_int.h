#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace hibiki_voice_hook::catsystem2 {

constexpr size_t kHeaderBytes = 8;
constexpr size_t kEntryBytes = 72;
constexpr size_t kNameBytes = 64;
constexpr uint32_t kMaxEntries = 1u << 20;
constexpr uint32_t kMaxVoiceBytes = 64u * 1024u * 1024u;

inline uint32_t ReadLe32(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

struct Header {
  uint32_t entry_count = 0;
  size_t index_bytes = 0;
};

inline bool ParseHeader(const uint8_t* bytes, size_t size, Header* out) {
  if (bytes == nullptr || out == nullptr || size < kHeaderBytes ||
      std::memcmp(bytes, "KIF\0", 4) != 0) {
    return false;
  }
  const uint32_t count = ReadLe32(bytes + 4);
  const uint64_t index = kHeaderBytes +
                         static_cast<uint64_t>(count) * kEntryBytes;
  if (count == 0 || count > kMaxEntries || index > SIZE_MAX) return false;
  out->entry_count = count;
  out->index_bytes = static_cast<size_t>(index);
  return true;
}

struct EntryView {
  const uint8_t* name = nullptr;
  size_t name_length = 0;
  uint32_t offset = 0;
  uint32_t size = 0;
};

inline bool ParseEntry(const uint8_t* index, size_t index_size,
                       uint32_t entry_index, uint64_t archive_size,
                       EntryView* out) {
  if (index == nullptr || out == nullptr || index_size < kHeaderBytes) {
    return false;
  }
  const uint64_t at = kHeaderBytes +
                      static_cast<uint64_t>(entry_index) * kEntryBytes;
  if (at + kEntryBytes > index_size) return false;
  const uint8_t* entry = index + static_cast<size_t>(at);
  size_t name_length = 0;
  while (name_length < kNameBytes && entry[name_length] != 0) ++name_length;
  if (name_length == 0 || name_length == kNameBytes) return false;
  const uint32_t offset = ReadLe32(entry + kNameBytes);
  const uint32_t length = ReadLe32(entry + kNameBytes + 4);
  if (length == 0 || offset > archive_size || length > archive_size - offset) {
    return false;
  }
  out->name = entry;
  out->name_length = name_length;
  out->offset = offset;
  out->size = length;
  return true;
}

inline uint8_t AsciiLower(uint8_t c) {
  return c >= 'A' && c <= 'Z' ? static_cast<uint8_t>(c + ('a' - 'A')) : c;
}

inline bool EqualsInsensitive(const uint8_t* text, size_t length,
                              const char* expected) {
  const size_t expected_length = std::strlen(expected);
  if (text == nullptr || length != expected_length) return false;
  for (size_t i = 0; i < length; ++i) {
    if (AsciiLower(text[i]) !=
        AsciiLower(static_cast<uint8_t>(expected[i]))) {
      return false;
    }
  }
  return true;
}

inline bool EndsWithInsensitive(const uint8_t* text, size_t length,
                                const char* suffix) {
  const size_t suffix_length = std::strlen(suffix);
  if (text == nullptr || length < suffix_length) return false;
  return EqualsInsensitive(text + length - suffix_length, suffix_length,
                           suffix);
}

inline bool IsEncryptionKey(const EntryView& entry) {
  return EqualsInsensitive(entry.name, entry.name_length, "__key__.dat");
}

inline bool IsVoiceOgg(const EntryView& entry) {
  return entry.size <= kMaxVoiceBytes &&
         EndsWithInsensitive(entry.name, entry.name_length, ".ogg");
}

}  // namespace hibiki_voice_hook::catsystem2
