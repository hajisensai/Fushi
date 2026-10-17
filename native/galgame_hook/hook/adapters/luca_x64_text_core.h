// LucaSystem x64 MESSAGE operand sites. Addresses and stack displacements
// are resolved from the loaded engine, never from an executable identity.
#pragma once

#include "luca_text_core.h"

namespace fushi_voice_hook::luca {

inline constexpr uint32_t kMaxMessageRecords = 8u;

// The engine's language count lives in zero-initialised .data and is filled
// during boot, after a launch-time injection has already resolved the sites.
// Zero therefore means "not yet known" (that message is withheld), never a
// reason to reject the sites; it is re-read for every MESSAGE.
inline constexpr uint32_t X64AdmittedRecordCount(uint32_t raw) {
  return raw >= 1u && raw <= kMaxMessageRecords ? raw : 0u;
}

struct X64MessageSites {
  MessageSites readers;
  uint32_t record_count_rva = 0u;
};

inline constexpr int16_t kX64VoiceShape[] = {
    0x33, 0xD2, 0x48, 0x8B, 0x7C, 0x24, -1,
    0x48, 0x8B, 0xCF, 0xE8, -1, -1, -1, -1,
    0x8B, 0xD8, 0x89, 0x44, 0x24, -1,
    0xBA, -1, -1, -1, -1, 0x48, 0x8B, 0xCF,
    0xE8, -1, -1, -1, -1,
};

inline constexpr int16_t kX64RecordShape[] = {
    0x49, 0x63, 0xDC, 0x48, 0x8B, 0xD3,
    0x48, 0x8D, 0x8D, -1, -1, -1, -1,
    0xE8, -1, -1, -1, -1, 0x4C, 0x8B, 0xC0,
    0x48, 0x8D, 0x95, -1, -1, -1, -1,
    0x48, 0x8B, 0xCF, 0xE8, -1, -1, -1, -1,
};

template <size_t N>
inline bool X64ShapeMatches(const uint8_t* bytes,
                            const int16_t (&shape)[N]) {
  for (size_t i = 0u; i < N; ++i) {
    if (shape[i] >= 0 && bytes[i] != static_cast<uint8_t>(shape[i])) {
      return false;
    }
  }
  return true;
}

inline bool X64RelativeRva(uint32_t next, const uint8_t* displacement,
                           uint32_t* out) {
  const int64_t rva = int64_t{next} + ReadRel32(displacement);
  if (rva <= 0 || rva > UINT32_MAX) return false;
  *out = static_cast<uint32_t>(rva);
  return true;
}

// The two operand readers must read the same VM cursor. The unsigned reader
// additionally advances by two and returns the loaded word without sign
// extension; the string reader returns a view carrying its encoding.
inline bool X64ReadersShareCursor(const CodeSpan* spans, size_t count,
                                  uint32_t u16, uint32_t string) {
  for (size_t a = 0; a < count; ++a) {
    const CodeSpan& us = spans[a];
    if (us.bytes == nullptr || u16 < us.rva ||
        uint64_t{u16 - us.rva} + 110u > us.size) continue;
    const uint8_t* ub = us.bytes + u16 - us.rva;
    uint32_t cursor = 0u;
    bool found = false;
    for (size_t i = 0; i + 7u <= 72u; ++i) {
      if (std::memcmp(ub + i, "\x48\x8B\x81", 3u) == 0) {
        std::memcpy(&cursor, ub + i + 3u, sizeof(cursor));
        found = true;
        break;
      }
    }
    if (!found || cursor == 0u || cursor > 0x10000u) return false;
    bool unsigned_return = false;
    for (size_t i = 0; i + 7u <= 110u; ++i) {
      if (std::memcmp(ub + i, "\x0F\xB7\xC0\x48\x83\xC4", 6u) == 0) {
        unsigned_return = true;
      }
    }
    if (!unsigned_return) return false;
    bool advances_two = false;
    bool writes_cursor = false;
    bool reads_word = false;
    for (size_t i = 0; i + 7u <= 110u; ++i) {
      advances_two |= std::memcmp(ub + i, "\x4C\x8D\x40\x02", 4u) == 0;
      reads_word |= std::memcmp(ub + i, "\x0F\xB7\x00", 3u) == 0;
      writes_cursor |= std::memcmp(ub + i, "\x4C\x89\x81", 3u) == 0 &&
          ReadRel32(ub + i + 3u) == static_cast<int32_t>(cursor);
    }
    if (!advances_two || !writes_cursor || !reads_word) return false;
    for (size_t b = 0; b < count; ++b) {
      const CodeSpan& ss = spans[b];
      if (ss.bytes == nullptr || string < ss.rva ||
          uint64_t{string - ss.rva} + 0x240u > ss.size) continue;
      const uint8_t* sb = ss.bytes + string - ss.rva;
      bool utf8 = false;
      bool utf16 = false;
      for (size_t i = 0; i + 4u <= 0x240u; ++i) {
        utf8 |= std::memcmp(sb + i, "\xC6\x43\x10\x02", 4u) == 0;
        utf16 |= std::memcmp(sb + i, "\xC6\x43\x10\x03", 4u) == 0;
      }
      if (!utf8 || !utf16) return false;
      for (size_t i = 0; i + 7u <= 64u; ++i) {
        if (std::memcmp(sb + i, "\x48\x8B\x81", 3u) == 0 &&
            ReadRel32(sb + i + 3u) == static_cast<int32_t>(cursor)) {
          return true;
        }
      }
    }
    return false;
  }
  return false;
}

inline MessageSiteResult ResolveX64MessageSites(const CodeSpan* spans,
                                                size_t count,
                                                X64MessageSites* out) {
  if (spans == nullptr || out == nullptr) return MessageSiteResult::kMissing;
  const CodeSpan* voice_span = nullptr;
  const CodeSpan* record_span = nullptr;
  size_t voice_at = 0u;
  size_t record_at = 0u;
  size_t voices = 0u;
  size_t records = 0u;
  for (size_t s = 0; s < count; ++s) {
    const CodeSpan& span = spans[s];
    if (span.bytes == nullptr) continue;
    for (size_t i = 0; i < span.size; ++i) {
      if (span.size - i >= sizeof(kX64VoiceShape) / sizeof(int16_t) &&
          X64ShapeMatches(span.bytes + i, kX64VoiceShape)) {
        if (++voices > 1u) return MessageSiteResult::kAmbiguous;
        voice_span = &span;
        voice_at = i;
      }
      if (span.size - i >= sizeof(kX64RecordShape) / sizeof(int16_t) &&
          X64ShapeMatches(span.bytes + i, kX64RecordShape)) {
        if (++records > 1u) return MessageSiteResult::kAmbiguous;
        record_span = &span;
        record_at = i;
      }
    }
  }
  if (voices == 0u || records == 0u) return MessageSiteResult::kMissing;
  if (voice_span != record_span || record_at <= voice_at ||
      record_at - voice_at > 0x1000u || record_at < 15u) {
    return MessageSiteResult::kBadTarget;
  }
  const uint8_t* voice = voice_span->bytes + voice_at;
  const uint8_t* record = record_span->bytes + record_at;
  X64MessageSites sites;
  sites.readers.voice_return = voice_span->rva + static_cast<uint32_t>(voice_at) + 15u;
  sites.readers.record_return = record_span->rva + static_cast<uint32_t>(record_at) + 36u;
  if (!X64RelativeRva(sites.readers.voice_return, voice + 11u,
                      &sites.readers.read_u16) ||
      !X64RelativeRva(sites.readers.record_return, record + 32u,
                      &sites.readers.read_string) ||
      !X64ReadersShareCursor(spans, count, sites.readers.read_u16,
                             sites.readers.read_string)) {
    return MessageSiteResult::kBadTarget;
  }
  // r12d starts at the same zero used by the loop's admission; both bounds
  // must reference the very same engine language count.
  if (record_at < 18u) return MessageSiteResult::kBadTarget;
  const uint8_t* prefix = record - 18u;
  if (
      std::memcmp(prefix, "\x44\x8B\xE6\x39\x35", 5u) != 0 ||
      prefix[9] != 0x0Fu || prefix[10] != 0x8Eu ||
      !X64RelativeRva(record_span->rva + static_cast<uint32_t>(record_at) - 9u,
                      prefix + 5u, &sites.record_count_rva)) {
    return MessageSiteResult::kBadTarget;
  }
  const size_t end = (std::min)(record_span->size, record_at + 0x200u);
  bool bounded_loop = false;
  for (size_t i = record_at + 36u; i + 16u <= end; ++i) {
    const uint8_t* tail = record_span->bytes + i;
    if (std::memcmp(tail, "\x41\xFF\xC4\x44\x3B\x25", 6u) != 0 ||
        tail[10] != 0x0Fu || tail[11] != 0x8Cu) continue;
    uint32_t count_rva = 0u;
    uint32_t loop_rva = 0u;
    if (X64RelativeRva(record_span->rva + static_cast<uint32_t>(i) + 10u,
                       tail + 6u, &count_rva) &&
        X64RelativeRva(record_span->rva + static_cast<uint32_t>(i) + 16u,
                       tail + 12u, &loop_rva) &&
        count_rva == sites.record_count_rva &&
        loop_rva == record_span->rva + record_at) {
      bounded_loop = true;
      break;
    }
  }
  if (!bounded_loop) return MessageSiteResult::kBadTarget;
  *out = sites;
  return MessageSiteResult::kResolved;
}

// String view: [begin,end), byte +0x10 is the engine encoding (2 UTF-8,
// 3 UTF-16LE). Packed script views may start at odd addresses; UTF-16 needs
// an even byte length, not an aligned source pointer. Caller checks memory
// readability and copies into bounded slots.
inline bool X64RecordByteCount(uint64_t begin, uint64_t end, uint8_t encoding,
                                uint32_t limit, uint32_t* bytes) {
  if (bytes == nullptr || begin == 0u || end < begin ||
      end - begin > limit || (encoding != 2u && encoding != 3u) ||
      (encoding == 3u && ((end - begin) & 1u) != 0u)) return false;
  *bytes = static_cast<uint32_t>(end - begin);
  return true;
}

// Worker-owned calibration; the owner resets it at session end. A unique
// kana-bearing body establishes the Japanese slot for this VM and language
// count. Later ideograph-only or punctuation-only bodies use that same slot.
// Conflicting evidence clears calibration instead of choosing Chinese CJK
// or pinning a slot number from an executable/game identity.
class X64JapaneseRecordSelector {
 public:
  void Reset() {
    vm_ = 0u;
    count_ = 0u;
    selected_ = kMaxMessageRecords;
  }

  // Returns count when there is no unique, calibrated Japanese record.
  uint32_t Select(const std::wstring* records, uint32_t count,
                   uint64_t vm_identity) {
    if (records == nullptr || count == 0u || count > kMaxMessageRecords ||
        vm_identity == 0u) {
      Reset();
      return count;
    }
    if (vm_ != vm_identity || count_ != count) {
      vm_ = vm_identity;
      count_ = count;
      selected_ = count;
    }
    uint32_t candidate = count;
    for (uint32_t i = 0u; i < count; ++i) {
      // Speaker names may be untranslated; only body kana calibrate language.
      const std::wstring body = DecodeMessageRecord(records[i], true).body;
      bool kana = false;
      for (const wchar_t unit : body) {
        kana |= (unit >= 0x3040 && unit <= 0x30FF) ||
                (unit >= 0xFF66 && unit <= 0xFF9F);
      }
      if (!kana) continue;
      if (candidate != count) {
        selected_ = count;
        return count;
      }
      candidate = i;
    }
    if (candidate != count) {
      if (selected_ < count && selected_ != candidate) {
        selected_ = count;
        return count;
      }
      selected_ = candidate;
    }
    return selected_;
  }

 private:
  uint64_t vm_ = 0u;
  uint32_t count_ = 0u;
  uint32_t selected_ = kMaxMessageRecords;
};

}  // namespace fushi_voice_hook::luca
