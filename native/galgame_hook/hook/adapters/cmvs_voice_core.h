#pragma once

// CMVS（Purple Software）per-line voice from the engine's own archive loader:
// pure, unit-tested half (site proof, voice-group / member-name checks).
//
// Engine facts (cmvs64, measured 2026-10-04 with Frida on the リアライブ trial
// v2 build; the sample is never an identity input):
//   * Every resource comes out of a "group loader"
//       void* load(Group* group, const char* name, uint32_t* size, ...)
//     A Group is four slots { char path[0x800]; Archive* archive; } of stride
//     0x808 followed by a cache field at +0x2020.  The loader walks the four
//     slots: a path ending in '\' is a loose directory (file read), anything
//     else asks the slot's archive object through a virtual call.  The return
//     value is a heap buffer the caller owns, already decrypted, and *size its
//     byte count.
//   * Voice lines are loaded through that loader with the voice group
//     (slot 0 = "...\data\pack\voice.cpz") and member names "<id>.ogg"; the
//     buffer is a complete Ogg Vorbis stream (head "OggS").  Sound effects and
//     BGM come from other groups (se.cpz, data\music\), so the group's slot
//     paths tell voice from everything else without guessing from the sound.
//   * Two builds compiled by different toolchains (リアライブ / クロノクロック
//     cmvs64) share no instruction run beyond what the source fixes: the slot
//     stride (add r64, 0x808), the archive field (mov r64, [r64 + 0x800]), the
//     trailing-backslash test (cmp byte [... - 1], 0x5c), the archive vcall and
//     the cache field address (lea r64, [rcx + 0x2020]) taken off the first
//     argument.  The last one is what proves the first argument is the group;
//     the other loaders that walk a group (different signatures) do not have it.
//
// Nothing here decrypts or knows a key: the adapter copies what the engine
// already produced for its own decoder.

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook::cmvs_voice {

inline constexpr size_t kSlotPathBytes = 0x800u;
inline constexpr size_t kSlotStride = 0x808u;
inline constexpr size_t kSlotCount = 4u;
inline constexpr size_t kGroupBytes = kSlotStride * kSlotCount;
inline constexpr size_t kNameBytes = 128u;
inline constexpr size_t kMaxSites = 8u;
// A voice line is kilobytes; anything larger is not copied.
inline constexpr uint32_t kMaxMemberBytes = 8u * 1024u * 1024u;

// ── site proof ─────────────────────────────────────────────────────────────

// add r64, 0x808  (REX.W [+B] 81 /0 imm32)
inline bool HasSlotStrideAdd(const uint8_t* code, size_t bytes) {
  for (size_t i = 0; i + 7u <= bytes; ++i) {
    if ((code[i] == 0x48u || code[i] == 0x49u) && code[i + 1] == 0x81u &&
        (code[i + 2] & 0xF8u) == 0xC0u && code[i + 3] == 0x08u &&
        code[i + 4] == 0x08u && code[i + 5] == 0u && code[i + 6] == 0u) {
      return true;
    }
  }
  return false;
}

// mov r64, [r64 + 0x800]  (REX.W 8B, mod=10, no SIB, disp32 0x800)
inline bool HasArchiveFieldLoad(const uint8_t* code, size_t bytes) {
  for (size_t i = 0; i + 7u <= bytes; ++i) {
    const uint8_t rex = code[i];
    if ((rex & 0xFAu) == 0x48u && code[i + 1] == 0x8Bu &&
        (code[i + 2] >> 6) == 2u && (code[i + 2] & 7u) != 4u &&
        code[i + 3] == 0u && code[i + 4] == 0x08u && code[i + 5] == 0u &&
        code[i + 6] == 0u) {
      return true;
    }
  }
  return false;
}

// cmp byte [base + index - 1], 0x5c  or  cmp byte [reg - 1], 0x5c
inline bool HasTrailingBackslashTest(const uint8_t* code, size_t bytes) {
  for (size_t i = 0; i + 4u <= bytes; ++i) {
    if (code[i] != 0x80u) continue;
    const uint8_t modrm = code[i + 1];
    if ((modrm & 0xF8u) != 0x78u) continue;  // mod=01 (disp8), reg=/7 (cmp)
    if ((modrm & 7u) == 4u) {
      if (i + 5u <= bytes && code[i + 3] == 0xFFu && code[i + 4] == 0x5Cu) {
        return true;
      }
    } else if (code[i + 2] == 0xFFu && code[i + 3] == 0x5Cu) {
      return true;
    }
  }
  return false;
}

// call qword [r64 + disp8] — the archive object's read slot.
inline bool HasVirtualCall(const uint8_t* code, size_t bytes) {
  for (size_t i = 0; i + 3u <= bytes; ++i) {
    const uint8_t modrm = code[i + 1];
    if (code[i] == 0xFFu && (modrm & 0xF8u) == 0x50u && (modrm & 7u) != 4u &&
        (modrm & 7u) != 5u && code[i + 2] >= 0x08u && code[i + 2] <= 0x78u &&
        (code[i + 2] & 7u) == 0u) {
      return true;
    }
  }
  return false;
}

// lea r64, [rcx + 0x2020] — the cache field off the first argument.
inline bool HasGroupCacheFromFirstArgument(const uint8_t* code, size_t bytes) {
  for (size_t i = 0; i + 7u <= bytes; ++i) {
    if ((code[i] == 0x48u || code[i] == 0x4Cu) && code[i + 1] == 0x8Du &&
        (code[i + 2] & 0xC7u) == 0x81u && code[i + 3] == 0x20u &&
        code[i + 4] == 0x20u && code[i + 5] == 0u && code[i + 6] == 0u) {
      return true;
    }
  }
  return false;
}

inline bool IsGroupLoaderBody(const uint8_t* code, size_t bytes) {
  return code != nullptr && bytes >= 32u && bytes <= 0x1000u &&
         HasGroupCacheFromFirstArgument(code, bytes) &&
         HasSlotStrideAdd(code, bytes) && HasArchiveFieldLoad(code, bytes) &&
         HasTrailingBackslashTest(code, bytes) && HasVirtualCall(code, bytes);
}

enum class SiteResult : uint32_t {
  kResolved = 0,
  kNotPe64 = 1,
  kNoExceptionDirectory = 2,
  kNoSite = 3,
  kTooManySites = 4,
};

// x64 exception directory entry (IMAGE_RUNTIME_FUNCTION_ENTRY), spelled out so
// the scan also compiles in the x86 build, whose headers lack the AMD64 type.
struct X64RuntimeFunction {
  uint32_t begin;
  uint32_t end;
  uint32_t unwind;
};
static_assert(sizeof(X64RuntimeFunction) == 12u, "x64 RUNTIME_FUNCTION layout");
inline constexpr uint8_t kUnwindFlagChainInfo = 0x4u;  // UNW_FLAG_CHAININFO

struct Sites {
  uint32_t rva[kMaxSites] = {};
  size_t count = 0;
};

// Walks the x64 exception directory of an image mapped at `base` (`size`
// bytes of address space) and keeps every primary function whose body passes
// IsGroupLoaderBody.  Chained unwind entries are fragments of a function, not
// entries, and are never hook targets.
inline SiteResult FindGroupLoaderSites(const uint8_t* base, size_t size,
                                       Sites* sites) {
  *sites = {};
  if (base == nullptr || size < sizeof(IMAGE_DOS_HEADER)) {
    return SiteResult::kNotPe64;
  }
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS64) > size) {
    return SiteResult::kNotPe64;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXCEPTION) {
    return SiteResult::kNotPe64;
  }
  const IMAGE_DATA_DIRECTORY dir =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
  if (dir.VirtualAddress == 0u || dir.Size < sizeof(X64RuntimeFunction) ||
      static_cast<size_t>(dir.VirtualAddress) + dir.Size > size) {
    return SiteResult::kNoExceptionDirectory;
  }
  const auto* table =
      reinterpret_cast<const X64RuntimeFunction*>(base + dir.VirtualAddress);
  const size_t entries = dir.Size / sizeof(X64RuntimeFunction);
  size_t found = 0;
  for (size_t i = 0; i < entries; ++i) {
    const X64RuntimeFunction& fn = table[i];
    if (fn.end <= fn.begin || fn.end > size || fn.unwind == 0u ||
        static_cast<size_t>(fn.unwind) + 4u > size) {
      continue;
    }
    // UNWIND_INFO byte 0: version (3 bits) | flags (5 bits).
    if (((base[fn.unwind] >> 3) & kUnwindFlagChainInfo) != 0u) continue;
    if (!IsGroupLoaderBody(base + fn.begin, fn.end - fn.begin)) continue;
    if (found < kMaxSites) sites->rva[found] = fn.begin;
    ++found;
  }
  if (found == 0u) return SiteResult::kNoSite;
  if (found > kMaxSites) {
    *sites = {};
    return SiteResult::kTooManySites;
  }
  sites->count = found;
  return SiteResult::kResolved;
}

// ── voice group / member checks ─────────────────────────────────────────────

inline char AsciiLower(char c) {
  return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

inline bool AsciiStartsWithNoCase(const char* text, size_t length,
                                  const char* prefix) {
  const size_t n = strlen(prefix);
  if (length < n) return false;
  for (size_t i = 0; i < n; ++i) {
    if (AsciiLower(text[i]) != prefix[i]) return false;
  }
  return true;
}

inline bool AsciiEndsWithNoCase(const char* text, size_t length,
                                const char* suffix) {
  const size_t n = strlen(suffix);
  return length >= n && AsciiStartsWithNoCase(text + length - n, n, suffix);
}

// One slot path.  Archive slot: basename "voice*.cpz".  Loose slot (trailing
// separator): last directory component "voice*".  Empty: not voice.
inline bool IsVoiceSlotPath(const char* path, size_t capacity) {
  const size_t length = strnlen(path, capacity);
  if (length == 0u || length == capacity) return false;
  size_t end = length;
  const bool loose = path[end - 1] == '\\' || path[end - 1] == '/';
  while (end > 0u && (path[end - 1] == '\\' || path[end - 1] == '/')) --end;
  size_t start = end;
  while (start > 0u && path[start - 1] != '\\' && path[start - 1] != '/') {
    --start;
  }
  const char* leaf = path + start;
  const size_t leaf_length = end - start;
  if (!AsciiStartsWithNoCase(leaf, leaf_length, "voice")) return false;
  return loose || AsciiEndsWithNoCase(leaf, leaf_length, ".cpz");
}

// A voice group has at least one slot and every used slot is a voice slot.
inline bool IsVoiceGroup(const uint8_t* group) {
  size_t used = 0;
  for (size_t slot = 0; slot < kSlotCount; ++slot) {
    const char* path = reinterpret_cast<const char*>(group + slot * kSlotStride);
    if (path[0] == '\0') continue;
    if (!IsVoiceSlotPath(path, kSlotPathBytes)) return false;
    ++used;
  }
  return used != 0u;
}

// Member names are bare "<id>.ogg": printable, no path separators.
inline bool IsVoiceMemberName(const char* name, size_t capacity) {
  const size_t length = strnlen(name, capacity);
  if (length <= 4u || length == capacity) return false;
  for (size_t i = 0; i < length; ++i) {
    const auto c = static_cast<unsigned char>(name[i]);
    if (c < 0x20u || c == '\\' || c == '/' || c == ':') return false;
  }
  return AsciiEndsWithNoCase(name, length, ".ogg");
}

inline bool HasOggHead(const uint8_t* data, uint32_t bytes) {
  return data != nullptr && bytes >= 4u && memcmp(data, "OggS", 4) == 0;
}

}  // namespace fushi_voice_hook::cmvs_voice
