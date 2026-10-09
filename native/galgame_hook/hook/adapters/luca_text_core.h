// LucaSystem (Prototype) scenario text: pure rules shared by the adapter and
// the offline tests.
//
// The scenario VM interprets one opcode per call; its MESSAGE handler reads
// the operands in a fixed order through the VM's own operand readers (all
// __thiscall on the VM object, one stack argument, `ret 4`):
//
//   call ReadU16                  ; voice id (0 = the line has no voice)
//   mov  edi, eax
//   mov  [ebp+voice_slot], eax
//   xor  esi, esi
// L:push imm32                    ; reader argument
//   mov  ecx, ebx                 ; VM object
//   call ReadString               ; -> NUL-terminated UTF-16 record
//   mov  [ebp+esi*4+text_slots], eax
//   inc  esi
//   cmp  esi, 2                   ; one record per script language
//   jl   L
//
// The site is that code shape, found in the image's executable sections after
// the loader (or a DRM stub) has finished hydrating them.  Only rel32/imm32/
// disp32 operands are wildcards; the shape must occur exactly once.  The
// adapter hooks the two reader functions and keys on the return addresses
// that belong to this one site, so the readers' other callers are untouched.
//
// A record is `[`speaker]@body` (speaker optional, `@` alone for an unnamed
// speaker) or a plain narration body.  `$K<n>` ... `$K0` bracket glossary
// keywords and are not display text.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace fushi_voice_hook::luca {

// One byte value per position; -1 is a wildcard.
inline constexpr int16_t kMessageOperandShape[] = {
    0xE8, -1,   -1,   -1,   -1,             // call ReadU16
    0x8B, 0xF8,                             // mov edi, eax
    0x89, 0x85, -1,   -1,   -1,   -1,       // mov [ebp+disp32], eax
    0x33, 0xF6,                             // xor esi, esi
    0x68, -1,   -1,   -1,   -1,             // push imm32
    0x8B, 0xCB,                             // mov ecx, ebx
    0xE8, -1,   -1,   -1,   -1,             // call ReadString
    0x89, 0x84, 0xB5, -1,   -1,   -1,   -1, // mov [ebp+esi*4+disp32], eax
    0x46,                                   // inc esi
    0x83, 0xFE, 0x02,                       // cmp esi, 2
    0x7C, 0xE7,                             // jl loop (back to push)
};
inline constexpr size_t kMessageOperandShapeBytes =
    sizeof(kMessageOperandShape) / sizeof(kMessageOperandShape[0]);
inline constexpr size_t kReadU16CallOffset = 0u;
inline constexpr size_t kReadStringCallOffset = 22u;
inline constexpr size_t kLoopTopOffset = 15u;  // the push
inline constexpr size_t kLoopBranchOffset = 38u;
inline constexpr uint32_t kMessageRecordCount = 2u;

// Every site is an RVA.
struct MessageSites {
  uint32_t read_u16 = 0u;          // reader entry
  uint32_t read_string = 0u;       // reader entry
  uint32_t voice_return = 0u;      // return address of the ReadU16 call
  uint32_t record_return = 0u;     // return address of the ReadString call
};

enum class MessageSiteResult : uint8_t {
  kResolved = 0,
  kMissing,
  kAmbiguous,
  kBadTarget,
};

struct CodeSpan {
  const uint8_t* bytes = nullptr;
  size_t size = 0u;
  uint32_t rva = 0u;
};

inline bool MatchesShape(const uint8_t* at) {
  for (size_t i = 0; i < kMessageOperandShapeBytes; ++i) {
    const int16_t want = kMessageOperandShape[i];
    if (want >= 0 && at[i] != static_cast<uint8_t>(want)) return false;
  }
  return true;
}

inline int32_t ReadRel32(const uint8_t* p) {
  int32_t value = 0;
  std::memcpy(&value, p, sizeof(value));
  return value;
}

inline bool SpanContainsRva(const CodeSpan* spans, size_t span_count,
                            uint64_t rva) {
  for (size_t i = 0; i < span_count; ++i) {
    if (rva >= spans[i].rva && rva < uint64_t{spans[i].rva} + spans[i].size) {
      return true;
    }
  }
  return false;
}

inline const uint8_t* SpanBytesAt(const CodeSpan* spans, size_t span_count,
                                  uint32_t rva) {
  for (size_t i = 0; i < span_count; ++i) {
    if (rva >= spans[i].rva && rva - spans[i].rva < spans[i].size) {
      return spans[i].bytes + (rva - spans[i].rva);
    }
  }
  return nullptr;
}

// A VM operand reader as the handler uses it: a __thiscall function with one
// stack argument, so its body returns with `ret 4` before any other return.
inline bool LooksLikeOperandReader(const CodeSpan* spans, size_t span_count,
                                   uint32_t entry) {
  constexpr size_t kReaderWindow = 0x100u;
  for (size_t i = 0; i < span_count; ++i) {
    const CodeSpan& span = spans[i];
    if (entry < span.rva || entry - span.rva >= span.size) continue;
    const size_t start = entry - span.rva;
    const size_t end = (std::min)(span.size, start + kReaderWindow);
    for (size_t at = start; at + 3u <= end; ++at) {
      if (span.bytes[at] == 0xC2 && span.bytes[at + 1] == 0x04 &&
          span.bytes[at + 2] == 0x00) {
        return true;
      }
    }
    return false;
  }
  return false;
}

// `spans` are the image's executable sections as currently mapped.
inline MessageSiteResult ResolveMessageSites(const CodeSpan* spans,
                                             size_t span_count,
                                             MessageSites* out) {
  if (spans == nullptr || out == nullptr) return MessageSiteResult::kMissing;
  uint32_t found_rva = 0u;
  const uint8_t* found = nullptr;
  size_t matches = 0u;
  for (size_t s = 0; s < span_count; ++s) {
    const CodeSpan& span = spans[s];
    if (span.bytes == nullptr || span.size < kMessageOperandShapeBytes) continue;
    const size_t last = span.size - kMessageOperandShapeBytes;
    for (size_t at = 0; at <= last; ++at) {
      if (span.bytes[at] != 0xE8 || !MatchesShape(span.bytes + at)) continue;
      if (++matches > 1u) return MessageSiteResult::kAmbiguous;
      found = span.bytes + at;
      found_rva = span.rva + static_cast<uint32_t>(at);
    }
  }
  if (matches == 0u) return MessageSiteResult::kMissing;
  // The loop branch must land on the push that starts each iteration.
  const int8_t back = static_cast<int8_t>(found[kLoopBranchOffset + 1]);
  if (static_cast<int64_t>(kLoopBranchOffset + 2) + back !=
      static_cast<int64_t>(kLoopTopOffset)) {
    return MessageSiteResult::kBadTarget;
  }
  MessageSites sites;
  sites.voice_return = found_rva + kReadU16CallOffset + 5u;
  sites.record_return = found_rva + kReadStringCallOffset + 5u;
  const int64_t u16_target =
      int64_t{sites.voice_return} +
      ReadRel32(found + kReadU16CallOffset + 1u);
  const int64_t string_target =
      int64_t{sites.record_return} +
      ReadRel32(found + kReadStringCallOffset + 1u);
  if (u16_target <= 0 || string_target <= 0 || u16_target == string_target ||
      !SpanContainsRva(spans, span_count, static_cast<uint64_t>(u16_target)) ||
      !SpanContainsRva(spans, span_count,
                       static_cast<uint64_t>(string_target))) {
    return MessageSiteResult::kBadTarget;
  }
  sites.read_u16 = static_cast<uint32_t>(u16_target);
  sites.read_string = static_cast<uint32_t>(string_target);
  if (!LooksLikeOperandReader(spans, span_count, sites.read_u16) ||
      !LooksLikeOperandReader(spans, span_count, sites.read_string)) {
    return MessageSiteResult::kBadTarget;
  }
  *out = sites;
  return MessageSiteResult::kResolved;
}

inline bool IsJapaneseUnit(wchar_t unit) {
  return (unit >= 0x3040 && unit <= 0x30FF) ||  // kana
         (unit >= 0x3400 && unit <= 0x4DBF) ||  // CJK ext A
         (unit >= 0x4E00 && unit <= 0x9FFF) ||  // CJK unified
         (unit >= 0xFF66 && unit <= 0xFF9F);    // half-width kana
}

inline bool ContainsJapanese(const std::wstring& text) {
  for (const wchar_t unit : text) {
    if (IsJapaneseUnit(unit)) return true;
  }
  return false;
}

struct MessageText {
  std::wstring speaker;  // empty for narration and the unnamed `@` speaker
  std::wstring body;
  bool role = false;     // the record carried a role prefix
};

// Strips the `$K<digits>` glossary markers; every other unit is kept.
inline std::wstring StripKeywordMarkers(const std::wstring& text) {
  std::wstring out;
  out.reserve(text.size());
  size_t i = 0u;
  while (i < text.size()) {
    if (i + 2u < text.size() && text[i] == L'$' && text[i + 1u] == L'K' &&
        text[i + 2u] >= L'0' && text[i + 2u] <= L'9') {
      i += 2u;
      while (i < text.size() && text[i] >= L'0' && text[i] <= L'9') ++i;
      continue;
    }
    out.push_back(text[i]);
    ++i;
  }
  return out;
}

// Decodes one MESSAGE record.  A role prefix is `` `speaker@`` with a speaker
// free of control units, or a lone leading `@`; the body after it must be
// non-empty. Newer engines can opt into `@speaker@body` with named_at;
// default decoding retains the older engine's exact behavior.
inline MessageText DecodeMessageRecord(const std::wstring& record,
                                       bool named_at = false) {
  MessageText out;
  size_t body_start = 0u;
  if (!record.empty() &&
      (record[0] == L'`' || (named_at && record[0] == L'@'))) {
    const size_t at = record.find(L'@', 1u);
    bool clean = at != std::wstring::npos && at > 1u &&
                 at + 1u < record.size();
    for (size_t i = 1u; clean && i < at; ++i) {
      const wchar_t unit = record[i];
      if (unit < 0x20 || unit == 0x7F || unit == L'`') clean = false;
    }
    if (clean) {
      out.speaker = record.substr(1u, at - 1u);
      out.role = true;
      body_start = at + 1u;
    }
  }
  if (body_start == 0u && record.size() > 1u && record[0] == L'@') {
    out.role = true;
    body_start = 1u;
  }
  out.body = StripKeywordMarkers(record.substr(body_start));
  return out;
}

// The record published as the line: the first one written in Japanese (the
// engine stores one record per script language; Fushi mines Japanese).
// This is the legacy two-language selector. Win64 uses VM-owned calibration
// instead, so adding its Chinese record does not change this behavior.
inline uint32_t PickJapaneseRecord(const std::wstring* records,
                                   uint32_t count) {
  for (uint32_t i = 0; i < count; ++i) {
    if (ContainsJapanese(records[i])) return i;
  }
  return count;
}

}  // namespace fushi_voice_hook::luca
