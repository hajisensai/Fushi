// LucaSystem (Prototype) archive formats: the `*.PAK` index and the
// `OGGPAK` voice member.  Pure parsing over caller-supplied bytes, no IO, so
// the identity probe, the HookWorker and the offline tests share one reading.
//
// PAK header (all little-endian u32):
//   +0x00 data_start   byte offset of the first member (== first entry offset)
//   +0x04 count        member count
//   +0x08 id_start     id of member 0; member i answers to id_start + i
//   +0x0C block        unit of an entry offset (0x800 for media, 4 for script)
//   +0x10..+0x1F       zero
//   +0x20 flags
//   +index             count x {u32 offset_in_blocks, u32 byte_length}
// The index starts at 0x28 or 0x2C depending on the archive kind.  The layout
// is never guessed from flags: an archive is accepted only when exactly one
// start offset reads every entry consistently (first member at data_start,
// members ordered, non-overlapping and inside the file, table before data).
//
// OGGPAK member: "OGGPAK\0" followed by one or more {u32 sample_rate,
// u32 length, <length bytes of a complete Ogg stream>} records that fill the
// member exactly.  The engine ships the same line at several sample rates.
// Music and system-sound archives use the same member format (stereo); the
// line voice archives are mono, which is what tells them apart.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace fushi_voice_hook::luca {

constexpr size_t kPakHeaderBytes = 0x28;
constexpr uint32_t kPakMaxCount = 1u << 20;
constexpr size_t kPakIndexStarts[] = {0x28u, 0x2Cu};

struct PakEntry {
  uint64_t offset = 0u;
  uint32_t length = 0u;
};

struct PakIndex {
  uint32_t data_start = 0u;
  uint32_t count = 0u;
  uint32_t id_start = 0u;
  uint32_t block = 0u;
  uint32_t flags = 0u;
  uint32_t index_start = 0u;
};

inline uint32_t ReadU32(const uint8_t* p) {
  uint32_t value = 0u;
  std::memcpy(&value, p, sizeof(value));
  return value;
}

// Header fields that every layout shares.  `head` covers at least the header.
inline bool ParsePakHeader(const uint8_t* head, size_t head_bytes,
                           uint64_t file_size, PakIndex* out) {
  if (head == nullptr || out == nullptr || head_bytes < kPakHeaderBytes) {
    return false;
  }
  PakIndex index;
  index.data_start = ReadU32(head + 0x00);
  index.count = ReadU32(head + 0x04);
  index.id_start = ReadU32(head + 0x08);
  index.block = ReadU32(head + 0x0C);
  index.flags = ReadU32(head + 0x20);
  for (size_t i = 0x10; i < 0x20; ++i) {
    if (head[i] != 0u) return false;
  }
  if (index.count == 0u || index.count > kPakMaxCount) return false;
  if (index.block == 0u || index.block > 0x10000u ||
      (index.block & (index.block - 1u)) != 0u) {
    return false;
  }
  if (index.data_start < kPakHeaderBytes + 8u * uint64_t{index.count} ||
      index.data_start > file_size) {
    return false;
  }
  *out = index;
  return true;
}

// Reads every entry under one index start.  `head` must hold the file from
// offset 0 through at least the end of that table.
inline bool ReadPakEntries(const uint8_t* head, size_t head_bytes,
                           uint64_t file_size, const PakIndex& header,
                           uint32_t index_start, std::vector<PakEntry>* out) {
  const uint64_t table_end = index_start + 8u * uint64_t{header.count};
  if (table_end > header.data_start || table_end > head_bytes) return false;
  uint64_t previous_end = header.data_start;
  if (out != nullptr) {
    out->clear();
    out->reserve(header.count);
  }
  for (uint32_t i = 0; i < header.count; ++i) {
    const uint8_t* entry = head + index_start + 8u * uint64_t{i};
    const uint64_t offset = uint64_t{ReadU32(entry)} * header.block;
    const uint32_t length = ReadU32(entry + 4);
    if (i == 0u ? offset != header.data_start : offset < previous_end) {
      return false;
    }
    if (offset + length > file_size) return false;
    previous_end = offset + length;
    if (out != nullptr) out->push_back({offset, length});
  }
  return true;
}

// Bytes of the file prefix that ParsePakIndex may need for this header.
inline uint64_t PakIndexBytes(const PakIndex& header) {
  return header.data_start;
}

enum class PakIndexResult : uint8_t {
  kValid = 0,
  kBadHeader,
  kNoLayout,
  kAmbiguousLayout,
};

// `head` is the file from offset 0 through data_start.  Exactly one index
// start must read every entry; two passing readings are ambiguous only when
// they disagree.
inline PakIndexResult ParsePakIndex(const uint8_t* head, size_t head_bytes,
                                    uint64_t file_size, PakIndex* index_out,
                                    std::vector<PakEntry>* entries_out) {
  PakIndex header;
  if (!ParsePakHeader(head, head_bytes, file_size, &header)) {
    return PakIndexResult::kBadHeader;
  }
  std::vector<PakEntry> chosen;
  uint32_t chosen_start = 0u;
  for (const size_t start : kPakIndexStarts) {
    std::vector<PakEntry> entries;
    if (!ReadPakEntries(head, head_bytes, file_size, header,
                        static_cast<uint32_t>(start), &entries)) {
      continue;
    }
    if (chosen_start != 0u) {
      bool same = chosen.size() == entries.size();
      for (size_t i = 0; same && i < entries.size(); ++i) {
        same = chosen[i].offset == entries[i].offset &&
               chosen[i].length == entries[i].length;
      }
      if (!same) return PakIndexResult::kAmbiguousLayout;
      continue;
    }
    chosen_start = static_cast<uint32_t>(start);
    chosen = std::move(entries);
  }
  if (chosen_start == 0u) return PakIndexResult::kNoLayout;
  header.index_start = chosen_start;
  if (index_out != nullptr) *index_out = header;
  if (entries_out != nullptr) *entries_out = std::move(chosen);
  return PakIndexResult::kValid;
}

// Member index of `id`, or -1 when the archive does not hold it.
inline int64_t PakMemberForId(const PakIndex& index, uint32_t id) {
  if (id < index.id_start) return -1;
  const uint64_t member = uint64_t{id} - index.id_start;
  return member < index.count ? static_cast<int64_t>(member) : -1;
}

constexpr char kOggPakMagic[] = "OGGPAK";  // followed by a NUL byte
constexpr size_t kOggPakMagicBytes = 7u;

inline bool IsOggPakMember(const uint8_t* data, size_t bytes) {
  return data != nullptr && bytes >= kOggPakMagicBytes &&
         std::memcmp(data, kOggPakMagic, kOggPakMagicBytes) == 0;
}

struct OggPakStream {
  uint32_t sample_rate = 0u;
  size_t offset = 0u;  // of the Ogg stream inside the member
  uint32_t length = 0u;
};

// Ogg page walk: the stream is one logical bitstream from a BOS page to an
// EOS page that ends exactly at `bytes`.
inline bool IsCompleteOggStream(const uint8_t* data, size_t bytes) {
  size_t at = 0u;
  bool first = true;
  uint32_t serial = 0u;
  while (at < bytes) {
    if (bytes - at < 27u || std::memcmp(data + at, "OggS", 4) != 0 ||
        data[at + 4] != 0u) {
      return false;
    }
    const uint8_t type = data[at + 5];
    const uint32_t page_serial = ReadU32(data + at + 14);
    if (first) {
      if ((type & 0x02u) == 0u) return false;
      serial = page_serial;
      first = false;
    } else if (page_serial != serial) {
      return false;
    }
    const uint8_t segments = data[at + 26];
    if (bytes - at < 27u + size_t{segments}) return false;
    size_t body = 0u;
    for (uint8_t i = 0; i < segments; ++i) body += data[at + 27 + i];
    const size_t page = 27u + size_t{segments} + body;
    if (bytes - at < page) return false;
    at += page;
    if ((type & 0x04u) != 0u) return at == bytes;
  }
  return false;
}

// Channel count from the Vorbis identification header on the stream's first
// page, or 0 when the stream does not start with one.  `bytes` may be a
// prefix of the stream that covers the first page.
inline uint32_t OggVorbisChannels(const uint8_t* data, size_t bytes) {
  if (data == nullptr || bytes < 28u || std::memcmp(data, "OggS", 4) != 0) {
    return 0u;
  }
  const uint8_t segments = data[26];
  const size_t body = 27u + size_t{segments};
  // packet type 1, "vorbis", u32 version, u8 channels
  if (bytes < body + 12u || data[body] != 0x01u ||
      std::memcmp(data + body + 1u, "vorbis", 6) != 0 ||
      ReadU32(data + body + 7u) != 0u) {
    return 0u;
  }
  return data[body + 11u];
}

// Every record must be a complete Ogg stream and the records must fill the
// member exactly; anything else is not an OGGPAK member.
inline bool ParseOggPakMember(const uint8_t* data, size_t bytes,
                              std::vector<OggPakStream>* out) {
  if (!IsOggPakMember(data, bytes) || out == nullptr) return false;
  out->clear();
  size_t at = kOggPakMagicBytes;
  while (at < bytes) {
    if (bytes - at < 8u) return false;
    OggPakStream stream;
    stream.sample_rate = ReadU32(data + at);
    stream.length = ReadU32(data + at + 4);
    stream.offset = at + 8u;
    if (stream.sample_rate < 8000u || stream.sample_rate > 192000u ||
        stream.length == 0u || bytes - stream.offset < stream.length ||
        !IsCompleteOggStream(data + stream.offset, stream.length)) {
      return false;
    }
    out->push_back(stream);
    at = stream.offset + stream.length;
  }
  return !out->empty() && at == bytes;
}

// The copy to export: the rate the mixer runs at when the member carries it,
// else the highest rate shipped.
inline const OggPakStream* PickOggPakStream(
    const std::vector<OggPakStream>& streams, uint32_t mixer_rate) {
  const OggPakStream* best = nullptr;
  for (const OggPakStream& stream : streams) {
    if (mixer_rate != 0u && stream.sample_rate == mixer_rate) return &stream;
    if (best == nullptr || stream.sample_rate > best->sample_rate) {
      best = &stream;
    }
  }
  return best;
}

}  // namespace fushi_voice_hook::luca
