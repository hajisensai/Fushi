#pragma once

// Malie (light / Greenwood) engine structure: pure, unit-tested half.
//
// Engine facts (x86 MSVC; measured 2026-10-03 on the 2016 build of
// Dies irae ~Interview with Kaziklu Bey~, never an identity input):
//
// Identity — the I/O scheme registry.
//   The runtime keeps a registry of named I/O schemes.  Each scheme is a
//   0x64-byte table built on the stack of a small registration function
//   (+0x00 getc, +0x08 read, +0x10 tell, +0x14 seek, +0x18 open, +0x1c close,
//   +0x20 wchar_t name[] copied from a UTF-16 literal) and handed to one
//   registrar shared by every scheme ("CFI", "WC_I", "TC_I", "LFILE_I", ...).
//   The archive scheme is named "CFI".  Resolving that table from structure
//   is the engine identity; nothing here touches the archive, its cipher or
//   any key, and none of its slots is hooked.
//
// Voice — the Ogg decoder input.
//   The engine's Ogg Vorbis decoder object embeds libogg's ogg_sync_state at
//   offset 0 and keeps the stream it decodes from at +S (0x4f8 measured) and
//   the decoded file's path (UTF-16) at +P (0x2c8 measured).  Every input
//   refill is
//       buf = ogg_sync_buffer(dec, 0x1000);
//       n   = stream_read(dec->stream /*[dec+S]*/, buf, 0x1000);
//       ogg_sync_wrote(dec, n);
//   so at ogg_sync_wrote entry the n bytes the decoder is about to consume
//   are at oy->data + oy->fill (oy = dec).  The lane copies exactly those
//   bytes from the refill call sites only (return-address checked), with the
//   path read from the same object: decoder input, after the engine has
//   resolved and produced the plaintext Ogg itself.
//
// Everything is resolved from structure; any missing or ambiguous proof
// resolves nothing (the adapter then installs nothing).

#include <windows.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>

#include "../siglus_ovk.h"
#include "exact_lookup_signature.h"

namespace fushi_voice_hook::malie_io {

namespace exact = fushi_voice_hook::exact_lookup;

inline constexpr wchar_t kArchiveSchemeName[] = L"CFI";

// ── shared decoding helpers ────────────────────────────────────────────────

inline const exact::LoadedPeSection* SectionAt(
    const exact::LoadedPeImage& image, size_t rva, size_t bytes) {
  return exact::FindSectionForRva(image, rva, bytes);
}

inline bool ExecutableAt(const exact::LoadedPeImage& image, size_t rva,
                         size_t bytes) {
  return exact::SectionHasRole(SectionAt(image, rva, bytes),
                               IMAGE_SCN_MEM_EXECUTE);
}

inline uintptr_t AbsoluteBase(const exact::LoadedPeImage& image) {
  return image.absolute_base != 0u ? image.absolute_base
                                   : reinterpret_cast<uintptr_t>(image.base);
}

inline uint32_t Load32(const uint8_t* at) {
  uint32_t value = 0u;
  std::memcpy(&value, at, sizeof(value));
  return value;
}

inline bool AbsoluteToRva(const exact::LoadedPeImage& image, uint32_t absolute,
                          size_t* rva) {
  const uintptr_t base = AbsoluteBase(image);
  if (absolute < base || absolute - base >= image.size) return false;
  *rva = absolute - base;
  return true;
}

inline bool Rel32Target(const exact::LoadedPeImage& image, size_t call_rva,
                        size_t* target_rva) {
  if (call_rva + 5u > image.size || image.base[call_rva] != 0xe8u) {
    return false;
  }
  int32_t rel = 0;
  std::memcpy(&rel, image.base + call_rva + 1u, sizeof(rel));
  const int64_t target =
      static_cast<int64_t>(call_rva) + 5 + static_cast<int64_t>(rel);
  if (target < 0 || static_cast<uint64_t>(target) >= image.size) return false;
  *target_rva = static_cast<size_t>(target);
  return true;
}

inline bool HasFramePrologue(const exact::LoadedPeImage& image, size_t rva) {
  return rva + 3u <= image.size && ExecutableAt(image, rva, 3u) &&
         image.base[rva] == 0x55u && image.base[rva + 1u] == 0x8bu &&
         image.base[rva + 2u] == 0xecu;
}

// Masked shape: mask byte 0 = wildcard.
inline bool ShapeAt(const exact::LoadedPeImage& image, size_t rva,
                    const uint8_t* bytes, const uint8_t* mask, size_t size) {
  if (rva + size > image.size || !ExecutableAt(image, rva, size)) return false;
  for (size_t i = 0u; i < size; ++i) {
    if (mask[i] != 0u && image.base[rva + i] != bytes[i]) return false;
  }
  return true;
}

// Every executable rva with the shape; at most `limit` are collected.
inline std::vector<size_t> FindShapes(const exact::LoadedPeImage& image,
                                      const uint8_t* bytes,
                                      const uint8_t* mask, size_t size,
                                      size_t limit = 4u) {
  std::vector<size_t> found;
  for (size_t s = 0u; s < image.section_count && found.size() < limit; ++s) {
    const auto& section = image.sections[s];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u ||
        section.size < size) {
      continue;
    }
    for (size_t at = 0u; at + size <= section.size && found.size() < limit;
         ++at) {
      bool match = true;
      for (size_t i = 0u; i < size && match; ++i) {
        match = mask[i] == 0u || section.bytes[at + i] == bytes[i];
      }
      if (match) found.push_back(section.rva + at);
    }
  }
  return found;
}

// ── identity: the "CFI" I/O scheme table ───────────────────────────────────

inline constexpr int32_t kSlotGetc = 0x00;
inline constexpr int32_t kSlotRead = 0x08;
inline constexpr int32_t kSlotTell = 0x10;
inline constexpr int32_t kSlotSeek = 0x14;
inline constexpr int32_t kSlotOpen = 0x18;
inline constexpr int32_t kSlotClose = 0x1c;
inline constexpr int32_t kSlotName = 0x20;

inline constexpr size_t kPrologueBackScan = 0x100u;
inline constexpr size_t kTableBaseForwardScan = 0x80u;
inline constexpr size_t kPushAfterLeaScan = 0x28u;
inline constexpr size_t kCallAfterPushScan = 0x40u;
inline constexpr size_t kGetcCallScan = 0x30u;
inline constexpr uint32_t kMaxPositionOffset = 0x1000u;

enum class SchemeResult : uint32_t {
  kResolved = 0,
  kNotX86 = 1,
  kNoName = 2,
  kNoNameCopy = 3,
  kAmbiguousNameCopy = 4,
  kNoTableBuild = 5,
  kNameOffsetMismatch = 6,
  kMissingSlot = 7,
  kSlotNotFunction = 8,
  kTellShape = 9,
  kGetcNotRead = 10,
  kRegistrarNotShared = 11,
};

// UTF-16LE literal (with terminator) that starts a string.
inline std::vector<size_t> FindWideLiteral(const exact::LoadedPeImage& image,
                                           const wchar_t* text) {
  std::vector<size_t> found;
  const size_t bytes = (wcslen(text) + 1u) * sizeof(wchar_t);
  for (size_t s = 0u; s < image.section_count; ++s) {
    const auto& section = image.sections[s];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u ||
        (section.characteristics & IMAGE_SCN_MEM_READ) == 0u ||
        section.size < bytes) {
      continue;
    }
    for (size_t at = 0u; at + bytes <= section.size; at += 2u) {
      if (std::memcmp(section.bytes + at, text, bytes) != 0) continue;
      if (at >= 2u && (section.bytes[at - 2u] != 0u ||
                       section.bytes[at - 1u] != 0u)) {
        continue;
      }
      found.push_back(section.rva + at);
    }
  }
  return found;
}

inline bool IsWordCopyFromDisp32(const uint8_t* p) {
  // `movzx r32, word ptr [base + disp32]`: 0f b7 /r, mod=10, rm!=esp.
  return p[0] == 0x0fu && p[1] == 0xb7u && (p[2] & 0xc0u) == 0x80u &&
         (p[2] & 0x07u) != 0x04u;
}

inline std::vector<size_t> FindNameCopies(const exact::LoadedPeImage& image,
                                          size_t literal_rva) {
  std::vector<size_t> sites;
  const uint32_t absolute =
      static_cast<uint32_t>(AbsoluteBase(image) + literal_rva);
  for (size_t s = 0u; s < image.section_count; ++s) {
    const auto& section = image.sections[s];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u ||
        section.size < 7u) {
      continue;
    }
    for (size_t at = 0u; at + 7u <= section.size; ++at) {
      const uint8_t* p = section.bytes + at;
      if (IsWordCopyFromDisp32(p) && Load32(p + 3u) == absolute) {
        sites.push_back(section.rva + at);
      }
    }
  }
  return sites;
}

struct TableBuild {
  size_t prologue = 0u;
  size_t call = 0u;
  size_t registrar = 0u;
  int32_t table_base = 0;
  int32_t name_store = 0;
  bool name_store_found = false;
};

inline bool DecodeTableBuild(const exact::LoadedPeImage& image, size_t copy,
                             TableBuild* out) {
  *out = TableBuild();
  bool prologue_found = false;
  for (size_t back = 0u; back <= kPrologueBackScan && back <= copy; ++back) {
    if (HasFramePrologue(image, copy - back)) {
      out->prologue = copy - back;
      prologue_found = true;
      break;
    }
  }
  if (!prologue_found) return false;
  const size_t end = (std::min)(image.size, copy + kTableBaseForwardScan);
  for (size_t at = copy; at + 3u <= end; ++at) {
    const uint8_t* p = image.base + at;
    // `66 89 /r [ebp+eax+disp8]`: the name word store.
    if (!out->name_store_found && at + 5u <= end && p[0] == 0x66u &&
        p[1] == 0x89u && (p[2] & 0xc7u) == 0x44u && p[3] == 0x05u) {
      out->name_store = static_cast<int8_t>(p[4]);
      out->name_store_found = true;
    }
    // `lea r32,[ebp+disp8]`, then `push r32`, then `call registrar`.
    if (p[0] != 0x8du || (p[1] & 0xc7u) != 0x45u) continue;
    const uint8_t reg = static_cast<uint8_t>((p[1] >> 3) & 0x07u);
    const int32_t disp = static_cast<int8_t>(p[2]);
    for (size_t push = at + 3u;
         push < end && push <= at + 3u + kPushAfterLeaScan; ++push) {
      if (image.base[push] != static_cast<uint8_t>(0x50u + reg)) continue;
      for (size_t call = push + 1u;
           call + 5u <= image.size && call <= push + 1u + kCallAfterPushScan;
           ++call) {
        size_t target = 0u;
        if (image.base[call] == 0xe8u && Rel32Target(image, call, &target) &&
            HasFramePrologue(image, target)) {
          out->call = call;
          out->registrar = target;
          out->table_base = disp;
          return true;
        }
      }
      break;
    }
  }
  return false;
}

inline bool FindStore(const exact::LoadedPeImage& image, const TableBuild& b,
                      int32_t disp, size_t* target_rva) {
  bool found = false;
  for (size_t at = b.prologue; at + 7u <= b.call; ++at) {
    const uint8_t* p = image.base + at;
    if (p[0] != 0xc7u || p[1] != 0x45u ||
        static_cast<int8_t>(p[2]) != disp) {
      continue;
    }
    size_t rva = 0u;
    if (!AbsoluteToRva(image, Load32(p + 3u), &rva)) return false;
    if (found && rva != *target_rva) return false;
    *target_rva = rva;
    found = true;
  }
  return found;
}

inline bool DecodeTell(const exact::LoadedPeImage& image, size_t tell) {
  if (tell + 14u > image.size || !ExecutableAt(image, tell, 14u)) return false;
  const uint8_t* p = image.base + tell;
  static constexpr uint8_t kHead[] = {0x55, 0x8b, 0xec, 0x8b,
                                      0x45, 0x08, 0x8b};
  if (std::memcmp(p, kHead, sizeof(kHead)) != 0) return false;
  uint32_t offset = 0u;
  size_t tail = 0u;
  if (p[7] == 0x80u) {
    offset = Load32(p + 8u);
    tail = 12u;
  } else if (p[7] == 0x40u) {
    offset = p[8];
    tail = 9u;
  } else {
    return false;
  }
  return p[tail] == 0x5du && p[tail + 1u] == 0xc3u && offset != 0u &&
         offset <= kMaxPositionOffset && (offset & 3u) == 0u;
}

inline bool GetcCallsRead(const exact::LoadedPeImage& image, size_t getc,
                          size_t read) {
  for (size_t at = getc; at + 5u <= image.size && at <= getc + kGetcCallScan;
       ++at) {
    size_t target = 0u;
    if (image.base[at] == 0xe8u && Rel32Target(image, at, &target) &&
        target == read) {
      return true;
    }
  }
  return false;
}

inline bool RegistrarIsShared(const exact::LoadedPeImage& image,
                              size_t own_copy, size_t registrar) {
  for (size_t s = 0u; s < image.section_count; ++s) {
    const auto& section = image.sections[s];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u) continue;
    for (size_t at = 0u; at + 7u <= section.size; ++at) {
      const uint8_t* p = section.bytes + at;
      const size_t rva = section.rva + at;
      if (rva == own_copy || !IsWordCopyFromDisp32(p)) continue;
      size_t literal = 0u;
      if (!AbsoluteToRva(image, Load32(p + 3u), &literal)) continue;
      const auto* data = SectionAt(image, literal, 4u);
      if (data == nullptr ||
          (data->characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u) {
        continue;
      }
      TableBuild other;
      if (DecodeTableBuild(image, rva, &other) &&
          other.registrar == registrar) {
        return true;
      }
    }
  }
  return false;
}

// Resolves the named scheme's table from structure.  Only the verdict is
// used (engine identity); no slot is hooked.
inline SchemeResult ResolveScheme(const exact::LoadedPeImage& image,
                                  const wchar_t* name) {
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u) {
    return SchemeResult::kNotX86;
  }
  const auto literals = FindWideLiteral(image, name);
  if (literals.empty()) return SchemeResult::kNoName;
  std::vector<size_t> copies;
  for (size_t literal : literals) {
    for (size_t copy : FindNameCopies(image, literal)) copies.push_back(copy);
  }
  if (copies.empty()) return SchemeResult::kNoNameCopy;
  if (copies.size() != 1u) return SchemeResult::kAmbiguousNameCopy;
  TableBuild build;
  if (!DecodeTableBuild(image, copies[0], &build)) {
    return SchemeResult::kNoTableBuild;
  }
  const int32_t name_field = build.table_base + kSlotName;
  if (!build.name_store_found || (build.name_store != name_field - 2 &&
                                  build.name_store != name_field)) {
    return SchemeResult::kNameOffsetMismatch;
  }
  size_t getc = 0u, read = 0u, tell = 0u, seek = 0u, open = 0u, close = 0u;
  if (!FindStore(image, build, build.table_base + kSlotGetc, &getc) ||
      !FindStore(image, build, build.table_base + kSlotRead, &read) ||
      !FindStore(image, build, build.table_base + kSlotTell, &tell) ||
      !FindStore(image, build, build.table_base + kSlotSeek, &seek) ||
      !FindStore(image, build, build.table_base + kSlotOpen, &open) ||
      !FindStore(image, build, build.table_base + kSlotClose, &close)) {
    return SchemeResult::kMissingSlot;
  }
  const size_t slots[] = {getc, read, tell, seek, open, close};
  for (size_t i = 0u; i < 6u; ++i) {
    if (!HasFramePrologue(image, slots[i])) {
      return SchemeResult::kSlotNotFunction;
    }
    for (size_t j = i + 1u; j < 6u; ++j) {
      if (slots[i] == slots[j]) return SchemeResult::kSlotNotFunction;
    }
  }
  if (!DecodeTell(image, tell)) return SchemeResult::kTellShape;
  if (!GetcCallsRead(image, getc, read)) return SchemeResult::kGetcNotRead;
  if (!RegistrarIsShared(image, copies[0], build.registrar)) {
    return SchemeResult::kRegistrarNotShared;
  }
  return SchemeResult::kResolved;
}

// ── identity verdict over the process lifetime ─────────────────────────────
//
// The first probe runs before the game's main thread is resumed.  A packed or
// self-decrypting exe has not unpacked its code / data yet: the scheme name
// literal or its copy site is simply not there.  That is "image not ready",
// not "not Malie": it is measured again once the image changed (sampled
// fingerprint of every section).  Every other refusal is structural (the
// literal is there but the code around it is not the scheme table build) and
// final.
enum class ProfileState : uint32_t {
  kUnmeasured = 0,
  kMatched = 1,
  kImageNotReady = 2,
  kRejected = 3,
};

inline ProfileState ClassifyScheme(SchemeResult result) {
  switch (result) {
    case SchemeResult::kResolved:
      return ProfileState::kMatched;
    case SchemeResult::kNoName:
    case SchemeResult::kNoNameCopy:
      return ProfileState::kImageNotReady;
    default:
      return ProfileState::kRejected;
  }
}

inline constexpr size_t kFingerprintStride = 0x1000u;
inline constexpr size_t kFingerprintRun = 16u;

// FNV-1a over the first kFingerprintRun bytes of every kFingerprintStride of
// every executable or read-only section: cheap, changes when an unpacker
// writes code / constants, and never changes for an image that is not being
// unpacked (plain writable data sections, which every game writes all the
// time, are left out — otherwise a non-Malie game would be re-measured
// forever).
inline uint64_t ImageFingerprint(const exact::LoadedPeImage& image) {
  uint64_t hash = 0xcbf29ce484222325ull;
  const auto mix = [&hash](uint8_t byte) {
    hash ^= byte;
    hash *= 0x100000001b3ull;
  };
  for (size_t s = 0u; s < image.section_count; ++s) {
    const auto& section = image.sections[s];
    const bool executable =
        (section.characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u;
    const bool writable = (section.characteristics & IMAGE_SCN_MEM_WRITE) != 0u;
    if (section.bytes == nullptr || (writable && !executable)) continue;
    for (size_t at = 0u; at < section.size; at += kFingerprintStride) {
      const size_t run = (std::min)(kFingerprintRun, section.size - at);
      for (size_t k = 0u; k < run; ++k) mix(section.bytes[at + k]);
    }
  }
  return hash;
}

// Measure (again)?  Only an unmeasured image, or one that was not ready and
// has changed since that measurement.
inline bool ShouldMeasureProfile(ProfileState state, uint64_t measured,
                                 uint64_t current) {
  return state == ProfileState::kUnmeasured ||
         (state == ProfileState::kImageNotReady && current != measured);
}

// ── voice: the Ogg decoder input ───────────────────────────────────────────

inline constexpr size_t kMaxFeedSites = 8u;
inline constexpr size_t kFeedBackScan = 0x50u;
inline constexpr size_t kPathCopyScan = 0x30u;
inline constexpr uint32_t kFeedBytes = 0x1000u;
inline constexpr uint32_t kMaxDecoderField = 0x10000u;

// libogg ogg_sync_wrote(oy, bytes):
//   push ebp; mov ebp,esp; mov edx,[ebp+8]; cmp dword [edx+4],0; jge +5;
//   or eax,-1; pop ebp; ret; mov eax,[ebp+0xc]; add eax,[edx+8];
//   cmp eax,[edx+4]; jg -0x10; mov [edx+8],eax; xor eax,eax; pop ebp; ret
inline constexpr uint8_t kSyncWroteBytes[] = {
    0x55, 0x8b, 0xec, 0x8b, 0x55, 0x08, 0x83, 0x7a, 0x04, 0x00, 0x7d, 0x05,
    0x83, 0xc8, 0xff, 0x5d, 0xc3, 0x8b, 0x45, 0x0c, 0x03, 0x42, 0x08, 0x3b,
    0x42, 0x04, 0x7f, 0xf0, 0x89, 0x42, 0x08, 0x33, 0xc0, 0x5d, 0xc3};
inline constexpr uint8_t kSyncWroteMask[] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

// libogg ogg_sync_buffer(oy, size) head:
//   push ebp; mov ebp,esp; push esi; mov esi,[ebp+8]; cmp dword [esi+4],0;
//   jge +5; xor eax,eax; pop esi; pop ebp; ret; mov eax,[esi+0xc]
inline constexpr uint8_t kSyncBufferBytes[] = {
    0x55, 0x8b, 0xec, 0x56, 0x8b, 0x75, 0x08, 0x83, 0x7e, 0x04, 0x00,
    0x7d, 0x05, 0x33, 0xc0, 0x5e, 0x5d, 0xc3, 0x8b, 0x46, 0x0c};
inline constexpr uint8_t kSyncBufferMask[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                              1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

// ogg_sync_state field offsets (libogg, 32-bit): data +0, storage +4, fill +8.
inline constexpr size_t kSyncDataOffset = 0u;
inline constexpr size_t kSyncStorageOffset = 4u;
inline constexpr size_t kSyncFillOffset = 8u;

struct OggFeedSites {
  uintptr_t sync_wrote = 0u;  // mapped
  uintptr_t sync_buffer = 0u;
  uintptr_t feed_returns[kMaxFeedSites] = {};  // return address of each call
  size_t feed_count = 0u;
  uint32_t stream_field = 0u;  // decoder +S: the stream it reads from
  uint32_t path_field = 0u;    // decoder +P: wchar_t path[]
};

enum class FeedResult : uint32_t {
  kResolved = 0,
  kNotX86 = 1,
  kNoSyncWrote = 2,
  kNoSyncBuffer = 3,
  kNoFeedSite = 4,
  kFeedFieldMismatch = 5,
  kNoPathCopy = 6,
  kAmbiguousPathCopy = 7,
};

// `push 0x1000`, the buffer call, then `push dword ptr [reg+S]` (ff /6 mod=10)
// between it and the wrote call: one refill site.  Returns S or 0.
inline uint32_t DecodeFeedSite(const exact::LoadedPeImage& image,
                               size_t wrote_call, size_t sync_buffer) {
  const size_t from = wrote_call > kFeedBackScan ? wrote_call - kFeedBackScan
                                                 : 0u;
  size_t buffer_call = SIZE_MAX;
  for (size_t at = from; at + 5u <= wrote_call; ++at) {
    size_t target = 0u;
    if (image.base[at] == 0xe8u && Rel32Target(image, at, &target) &&
        target == sync_buffer && at >= 5u + from &&
        // `push 0x1000` within the arguments of the buffer call.
        [&] {
          for (size_t p = at > 12u ? at - 12u : 0u; p + 5u <= at; ++p) {
            if (image.base[p] == 0x68u && Load32(image.base + p + 1u) ==
                                              kFeedBytes) {
              return true;
            }
          }
          return false;
        }()) {
      buffer_call = at;
    }
  }
  if (buffer_call == SIZE_MAX) return 0u;
  uint32_t field = 0u;
  for (size_t at = buffer_call + 5u; at + 6u <= wrote_call; ++at) {
    const uint8_t* p = image.base + at;
    if (p[0] == 0xffu && (p[1] & 0xf8u) == 0xb0u && (p[1] & 0x07u) != 0x04u) {
      const uint32_t value = Load32(p + 2u);
      if (value == 0u || value >= kMaxDecoderField) return 0u;
      if (field != 0u && field != value) return 0u;
      field = value;
    }
  }
  return field;
}

// `mov [reg+S], eax` (89 /r, mod=10, reg=eax), then within the copy scan
// `lea ecx,[reg+P]` (8d /r, mod=10, reg=ecx) followed by `sub ecx,esi` and a
// word load from [esi] (0f b7 06): the path copy into the decoder.
inline std::vector<uint32_t> FindPathCopies(const exact::LoadedPeImage& image,
                                            uint32_t stream_field) {
  std::vector<uint32_t> found;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const auto& section = image.sections[s];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u) continue;
    for (size_t at = 0u; at + 6u <= section.size; ++at) {
      const uint8_t* p = section.bytes + at;
      if (p[0] != 0x89u || (p[1] & 0xf8u) != 0x80u ||
          (p[1] & 0x07u) == 0x04u || Load32(p + 2u) != stream_field) {
        continue;
      }
      const uint8_t object_reg = p[1] & 0x07u;
      const size_t end = (std::min)(section.size, at + 6u + kPathCopyScan);
      for (size_t k = at + 6u; k + 14u <= end; ++k) {
        const uint8_t* q = section.bytes + k;
        if (q[0] != 0x8du || q[1] != static_cast<uint8_t>(0x88u | object_reg)) {
          continue;
        }
        const uint32_t path_field = Load32(q + 2u);
        if (q[6] != 0x2bu || q[7] != 0xceu) continue;  // sub ecx,esi
        bool word_load = false;
        for (size_t w = k + 8u; w + 3u <= end && w <= k + 12u; ++w) {
          word_load = word_load || (section.bytes[w] == 0x0fu &&
                                    section.bytes[w + 1u] == 0xb7u &&
                                    section.bytes[w + 2u] == 0x06u);
        }
        if (word_load && path_field != 0u && path_field < stream_field) {
          found.push_back(path_field);
        }
        break;
      }
    }
  }
  return found;
}

inline FeedResult ResolveOggFeed(const exact::LoadedPeImage& image,
                                 OggFeedSites* out) {
  *out = OggFeedSites();
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u) {
    return FeedResult::kNotX86;
  }
  const auto wrote = FindShapes(image, kSyncWroteBytes, kSyncWroteMask,
                                sizeof(kSyncWroteBytes));
  if (wrote.size() != 1u) return FeedResult::kNoSyncWrote;
  const auto buffer = FindShapes(image, kSyncBufferBytes, kSyncBufferMask,
                                 sizeof(kSyncBufferBytes));
  if (buffer.size() != 1u) return FeedResult::kNoSyncBuffer;
  uint32_t stream_field = 0u;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const auto& section = image.sections[s];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u) continue;
    for (size_t at = 0u; at + 5u <= section.size; ++at) {
      const size_t rva = section.rva + at;
      size_t target = 0u;
      if (section.bytes[at] != 0xe8u || !Rel32Target(image, rva, &target) ||
          target != wrote[0]) {
        continue;
      }
      const uint32_t field = DecodeFeedSite(image, rva, buffer[0]);
      if (field == 0u) continue;  // a wrote call that is not a refill
      if (stream_field != 0u && field != stream_field) {
        return FeedResult::kFeedFieldMismatch;
      }
      if (out->feed_count == kMaxFeedSites) {
        return FeedResult::kFeedFieldMismatch;
      }
      stream_field = field;
      out->feed_returns[out->feed_count++] =
          reinterpret_cast<uintptr_t>(image.base) + rva + 5u;
    }
  }
  if (out->feed_count == 0u) return FeedResult::kNoFeedSite;
  const auto paths = FindPathCopies(image, stream_field);
  if (paths.empty()) return FeedResult::kNoPathCopy;
  for (uint32_t path : paths) {
    if (path != paths[0]) return FeedResult::kAmbiguousPathCopy;
  }
  out->sync_wrote = reinterpret_cast<uintptr_t>(image.base) + wrote[0];
  out->sync_buffer = reinterpret_cast<uintptr_t>(image.base) + buffer[0];
  out->stream_field = stream_field;
  out->path_field = paths[0];
  return FeedResult::kResolved;
}

// ── voice assembly ─────────────────────────────────────────────────────────

inline constexpr uint32_t kMinPartialPages = 4u;

// Bytes of the leading run of whole Ogg pages of one logical stream (header
// shape, segment table and payload all present); 0 when fewer than
// kMinPartialPages pages are whole.  A playback the next line stopped is
// published as this prefix: the heard part plus the decode-ahead.
inline uint32_t OggPagePrefixBytes(const uint8_t* data, uint32_t bytes) {
  if (data == nullptr) return 0u;
  uint32_t at = 0u;
  uint32_t pages = 0u;
  uint32_t serial = 0u;
  while (bytes - at >= 27u) {
    const uint8_t* page = data + at;
    if (std::memcmp(page, "OggS", 4) != 0 || page[4] != 0u) break;
    const uint32_t page_serial = Load32(page + 14u);
    if (pages == 0u) {
      serial = page_serial;
    } else if (page_serial != serial) {
      break;
    }
    const uint32_t segments = page[26];
    if (bytes - at < 27u + segments) break;
    uint32_t payload = 0u;
    for (uint32_t i = 0u; i < segments; ++i) payload += page[27u + i];
    const uint32_t size = 27u + segments + payload;
    if (bytes - at < size) break;
    at += size;
    ++pages;
  }
  return pages >= kMinPartialPages ? at : 0u;
}

// ── voice classification and naming ────────────────────────────────────────

inline wchar_t WideLower(wchar_t c) {
  return c >= L'A' && c <= L'Z' ? static_cast<wchar_t>(c + (L'a' - L'A')) : c;
}

// A decoded file is voice when a directory component of its path is
// "voice" (data\voice\<chara>\v_xxx0001.ogg) and it is an .ogg.
inline bool IsVoicePath(const wchar_t* path) {
  if (path == nullptr) return false;
  const size_t length = wcslen(path);
  if (length < 4u) return false;
  static constexpr wchar_t kOgg[] = L".ogg";
  for (size_t i = 0u; i < 4u; ++i) {
    if (WideLower(path[length - 4u + i]) != kOgg[i]) return false;
  }
  for (size_t at = 0u; at + 6u <= length; ++at) {
    const bool start = at == 0u || path[at - 1u] == L'\\' ||
                       path[at - 1u] == L'/';
    if (!start) continue;
    static constexpr wchar_t kVoice[] = L"voice";
    bool match = true;
    for (size_t i = 0u; i < 5u && match; ++i) {
      match = WideLower(path[at + i]) == kVoice[i];
    }
    if (match && (path[at + 5u] == L'\\' || path[at + 5u] == L'/')) {
      return true;
    }
  }
  return false;
}

// Published name: the path below "voice\" with separators -> '_'
// ("vir_v_vir0001.ogg"); a stopped playback's prefix is
// "vir_v_vir0001.partial.ogg".
inline std::wstring VoiceStorageName(const wchar_t* path, bool partial = false);
inline std::wstring VoiceStorageNameImpl(const wchar_t* path) {
  std::wstring text(path == nullptr ? L"" : path);
  std::wstring lower = text;
  for (wchar_t& c : lower) c = WideLower(c == L'/' ? L'\\' : c);
  size_t at = std::wstring::npos;
  for (size_t k = lower.find(L"voice\\"); k != std::wstring::npos;
       k = lower.find(L"voice\\", k + 1u)) {
    if (k == 0u || lower[k - 1u] == L'\\') at = k;
  }
  std::wstring tail = at == std::wstring::npos ? text : text.substr(at + 6u);
  for (wchar_t& c : tail) {
    if (c == L'\\' || c == L'/') c = L'_';
  }
  return tail;
}

inline std::wstring VoiceStorageName(const wchar_t* path, bool partial) {
  std::wstring name = VoiceStorageNameImpl(path);
  if (partial) {
    const size_t dot = name.find_last_of(L'.');
    name.insert(dot == std::wstring::npos ? name.size() : dot, L".partial");
  }
  return name;
}

// ── voice assembly from the decoder input (worker side) ───────────────────
//
// The detour hands over every voice refill of a decoder in feed order, plus
// "a voice refill of this decoder was lost" records (no free ring slot).  The
// lifecycle of a voice is decided from decoder signals, never from wall-clock
// idleness (a paused or unfocused game feeds nothing and must not have its
// voice cut):
//   * EOS page reached → complete;
//   * a new BOS page on the *same* decoder → that decoder's unfinished stream
//     was stopped by the engine: its whole-page prefix is kept (partial);
//     other decoders are untouched, and completed voices stay until bound;
//   * a lost refill → the decoder's unfinished stream is cut before the hole
//     and marked damaged (CompleteOggBytes does not check page sequence
//     numbers, so a hole on a page boundary would otherwise pass as whole);
//   * the decoder received nothing while the engine refilled other decoders
//     kStallFeeds times → it was stopped without a successor (partial).
// Wall-clock time is used only for what is not a lifecycle question: how
// long a complete voice waits for its message unit, and the repeat window of
// a file decoded twice for one playback.

inline constexpr int kAssemblerMembers = 8;
inline constexpr uint32_t kMaxMemberBytes = 16u * 1024u * 1024u;
// Other refills seen while a decoder got none: a playing voice refills every
// few hundred milliseconds of audio, BGM about as often, so 48 refills of
// other decoders mean this one stopped.
inline constexpr uint64_t kStallFeeds = 48u;
inline constexpr uint64_t kBindWaitMs = 2000u;
inline constexpr uint64_t kRepeatWindowMs = 3000u;

struct FeedChunk {
  uint64_t feed = 0u;  // global refill order (every refill site call counts)
  uintptr_t decoder = 0u;
  uint64_t tick = 0u;
  const wchar_t* path = nullptr;
  const uint8_t* data = nullptr;
  uint32_t length = 0u;
};

// What the assembler needs from its host (the adapter, or a test double).
class VoiceSink {
 public:
  virtual ~VoiceSink() = default;
  // The text event of the message unit naming this voice; 0 when none yet.
  virtual uint64_t TextEvent(const std::wstring& path, uint64_t first_tick) = 0;
  virtual bool Write(const uint8_t* data, uint32_t bytes,
                     const std::wstring& storage, uint64_t first_tick,
                     uint64_t text_event) = 0;
  virtual void Note(const wchar_t* what, const std::wstring& path,
                    uint32_t a, uint32_t b) = 0;
};

struct VoiceMember {
  bool used = false;
  bool partial = false;   // `complete` is a whole-page prefix
  bool damaged = false;   // cut at a lost refill
  uint32_t complete = 0;  // publishable bytes, 0 while still receiving
  uint64_t complete_tick = 0;
  uintptr_t decoder = 0;
  uint64_t first_tick = 0;
  uint64_t last_feed = 0;
  std::wstring path;
  std::vector<uint8_t> bytes;
};

inline bool StartsOggStream(const uint8_t* data, uint32_t length) {
  // A BOS page: capture pattern, version 0, header-type "beginning".
  return data != nullptr && length >= 27u && std::memcmp(data, "OggS", 4) == 0 &&
         data[4] == 0u && (data[5] & 0x02u) != 0u;
}

class VoiceAssembler {
 public:
  void Feed(const FeedChunk& chunk, VoiceSink& sink) {
    if (chunk.data == nullptr || chunk.length == 0u || !IsVoicePath(chunk.path)) {
      return;
    }
    VoiceMember* member = nullptr;
    if (StartsOggStream(chunk.data, chunk.length)) {
      // The engine reused this decoder for a new stream: what it was still
      // receiving was stopped.  Completed members wait for their binding.
      for (auto& other : members_) {
        if (Receiving(other) && other.decoder == chunk.decoder) {
          Stop(&other, chunk.tick, false, sink);
        }
      }
      member = Allocate(chunk, sink);
    } else {
      member = FindReceiving(chunk.decoder, chunk.path);
      if (member == nullptr) return;  // its head was never seen
    }
    if (member->bytes.size() + chunk.length > kMaxMemberBytes) {
      sink.Note(L"oversized", member->path,
                static_cast<uint32_t>(member->bytes.size()), 0u);
      *member = VoiceMember();
      return;
    }
    member->bytes.insert(member->bytes.end(), chunk.data,
                         chunk.data + chunk.length);
    member->last_feed = chunk.feed;
    const uint32_t complete = siglus::CompleteOggBytes(
        member->bytes.data(), static_cast<uint32_t>(member->bytes.size()));
    if (complete != 0u) {
      member->complete = complete;
      member->complete_tick = chunk.tick;
    }
  }

  // A voice refill of `decoder` at `feed` was lost: the stream it was
  // receiving is cut before the hole.
  void Drop(uintptr_t decoder, uint64_t feed, uint64_t now, VoiceSink& sink) {
    ++dropped_;
    for (auto& member : members_) {
      if (Receiving(member) && member.decoder == decoder &&
          member.last_feed < feed) {
        Stop(&member, now, true, sink);
      }
    }
  }

  // Lost refills whose decoder is unknown (the loss record itself was lost):
  // every stream still receiving may have a hole.
  void DropAll(uint64_t now, VoiceSink& sink) {
    ++dropped_;
    for (auto& member : members_) {
      if (Receiving(member)) Stop(&member, now, true, sink);
    }
  }

  // `feeds_now` is the global refill count already handed over.
  void Settle(uint64_t feeds_now, uint64_t now, VoiceSink& sink) {
    for (auto& member : members_) {
      if (Receiving(member) && feeds_now > member.last_feed &&
          feeds_now - member.last_feed > kStallFeeds) {
        Stop(&member, now, false, sink);
      }
    }
    for (auto& member : members_) {
      if (!member.used || member.complete == 0u) continue;
      const uint64_t text_event = sink.TextEvent(member.path, member.first_tick);
      if (text_event != 0u || now - member.complete_tick >= kBindWaitMs) {
        Publish(&member, text_event, sink);
      }
    }
  }

  void Reset() {
    for (auto& member : members_) member = VoiceMember();
    last_published_.clear();
    last_published_tick_ = 0u;
  }

  uint32_t dropped() const { return dropped_; }
  uint32_t damaged() const { return damaged_; }
  const VoiceMember& member(int index) const { return members_[index]; }

 private:
  static bool Receiving(const VoiceMember& member) {
    return member.used && member.complete == 0u;
  }

  VoiceMember* FindReceiving(uintptr_t decoder, const wchar_t* path) {
    for (auto& member : members_) {
      if (Receiving(member) && member.decoder == decoder &&
          member.path == path) {
        return &member;
      }
    }
    return nullptr;
  }

  // A free member, else the one that was fed least recently (published
  // first when it has publishable bytes).
  VoiceMember* Allocate(const FeedChunk& chunk, VoiceSink& sink) {
    VoiceMember* slot = nullptr;
    for (auto& member : members_) {
      if (!member.used) {
        slot = &member;
        break;
      }
    }
    if (slot == nullptr) {
      slot = &members_[0];
      for (auto& member : members_) {
        if (member.last_feed < slot->last_feed) slot = &member;
      }
      sink.Note(L"evicted", slot->path,
                static_cast<uint32_t>(slot->bytes.size()), slot->complete);
      if (Receiving(*slot)) Stop(slot, chunk.tick, false, sink);
      if (slot->used && slot->complete != 0u) {
        Publish(slot, sink.TextEvent(slot->path, slot->first_tick), sink);
      }
    }
    *slot = VoiceMember();
    slot->used = true;
    slot->decoder = chunk.decoder;
    slot->first_tick = chunk.tick;
    slot->last_feed = chunk.feed;
    slot->path = chunk.path;
    return slot;
  }

  // A stream that will receive no more input: keep its whole-page prefix.
  void Stop(VoiceMember* member, uint64_t now, bool damaged, VoiceSink& sink) {
    if (!Receiving(*member)) return;
    if (damaged) ++damaged_;
    const uint32_t prefix = OggPagePrefixBytes(
        member->bytes.data(), static_cast<uint32_t>(member->bytes.size()));
    if (prefix == 0u) {
      sink.Note(damaged ? L"damaged, dropped" : L"incomplete, dropped",
                member->path, static_cast<uint32_t>(member->bytes.size()), 0u);
      *member = VoiceMember();
      return;
    }
    member->complete = prefix;
    member->partial = true;
    member->damaged = damaged;
    member->complete_tick = now;
  }

  void Publish(VoiceMember* member, uint64_t text_event, VoiceSink& sink) {
    const std::wstring storage =
        VoiceStorageName(member->path.c_str(), member->partial);
    if (!member->partial && storage == last_published_ &&
        member->first_tick - last_published_tick_ <= kRepeatWindowMs) {
      // The same file decoded twice for one playback (e.g. a lip-sync pass).
      sink.Note(L"duplicate decode", storage, member->complete, 0u);
    } else if (sink.Write(member->bytes.data(), member->complete, storage,
                          member->first_tick, text_event)) {
      last_published_ = storage;
      last_published_tick_ = member->first_tick;
    }
    *member = VoiceMember();
  }

  VoiceMember members_[kAssemblerMembers];
  std::wstring last_published_;
  uint64_t last_published_tick_ = 0u;
  uint32_t dropped_ = 0u;
  uint32_t damaged_ = 0u;
};

}  // namespace fushi_voice_hook::malie_io
