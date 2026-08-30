#pragma once

// SGRE (M2 wind3d11 runtime) anchor resolution.
//
// Identity used to be a single executable SHA-256 and every engine-internal
// address was a fixed RVA guarded by that hash. That made the adapter a patch
// for one build, not an engine adapter: a Steam update or a different regional
// depot silently disabled text, geometry, input shield and audio at once.
//
// This header separates the three concerns:
//   1. Family identity (does this process run the wind3d11 runtime?) lives in
//      sgre_profile.h and never depends on a hash.
//   2. Known builds: one row per measured executable, hash -> RVAs. A hash hit
//      is the fast path and keeps verified builds byte-for-byte unchanged.
//   3. Unknown builds: each anchor is resolved independently by a byte
//      signature scanned over the mapped image. A signature must match exactly
//      once and the result must pass a structural check for its anchor kind;
//      otherwise that anchor stays unresolved and nothing is hooked at a
//      guessed address. Empty signatures (not measured yet) resolve to
//      kSignatureEmpty so the outcome is reported instead of silently absent.
//
// Everything here is pure: no Windows headers, no process access. The OS
// facing wrapper that builds an SgreImageView from a loaded module lives in
// sgre_profile.h so this file stays testable on any host.

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {

// ── Anchor kinds ────────────────────────────────────────────────────────────

// Structural expectations per anchor. Signature hits that violate them are
// rejected: the pattern matched bytes, but not the thing we intend to hook.
enum class SgreAnchorKind : uint8_t {
  kCode = 0,         // function entry: must lie in an executable section
  kVtable = 1,       // read-only vtable: slot 0 must point into code
  kWritableData = 2  // global pointer slot: must lie in a writable section
};

enum class SgreAnchorSource : uint8_t {
  kUnresolved = 0,
  kKnownBuild = 1,         // hash table hit
  kSignature = 2,          // unique signature hit + structural check passed
  kSignatureEmpty = 3,     // no signature recorded for this anchor yet
  kSignatureInvalid = 4,   // pattern text failed to parse
  kSignatureMissing = 5,   // scanned, zero matches
  kSignatureAmbiguous = 6, // scanned, more than one match
  kStructureRejected = 7   // unique match but structural check failed
};

struct SgreResolvedAnchor {
  uintptr_t rva = 0;
  SgreAnchorSource source = SgreAnchorSource::kUnresolved;
  bool resolved() const {
    return source == SgreAnchorSource::kKnownBuild ||
           source == SgreAnchorSource::kSignature;
  }
};

struct SgreAnchorSet {
  SgreResolvedAnchor text_draw;
  SgreResolvedAnchor scenario_text_vtable;
  SgreResolvedAnchor direct_input_mouse_device;
  bool known_build = false;

  // The in-game lookup sensor needs both the draw boundary and the scenario
  // surface class; one without the other cannot validate captured objects.
  bool lookup_sensor_available() const {
    return text_draw.resolved() && scenario_text_vtable.resolved();
  }
  bool direct_input_shield_available() const {
    return direct_input_mouse_device.resolved();
  }
  bool complete() const {
    return lookup_sensor_available() && direct_input_shield_available();
  }
};

// ── Known builds ────────────────────────────────────────────────────────────

struct SgreBuildAnchors {
  std::array<uint8_t, 32> exe_sha256;
  uintptr_t text_draw_rva;
  uintptr_t scenario_text_vtable_rva;
  uintptr_t direct_input_mouse_device_rva;
  const char* label;
};

// STEINS;GATE RE:BOOT Steam x64, measured 2026-08-21. Same digest the Luna
// text profile keys on (config/luna_hook_profiles.tsv) so text and audio
// identity cannot drift apart for this row.
inline constexpr std::array<uint8_t, 32> kSgreExecutableSha256 = {
    0x75, 0xa8, 0x3a, 0x0e, 0x2a, 0x7e, 0x22, 0x05,
    0x54, 0x17, 0xae, 0x04, 0x74, 0xb4, 0x7b, 0xe9,
    0x84, 0x18, 0xc4, 0xe4, 0x2c, 0x69, 0x5c, 0x54,
    0x8b, 0x55, 0x87, 0x05, 0xc4, 0x04, 0xb9, 0xd8,
};

// TextRender draw boundary (not UserHook1's pre-layout routine at 0x328e0):
// at draw time the flattened glyph vector holds only the visible sentence and
// the game's own parser has already consumed MAGES control codes.
inline constexpr uintptr_t kSgreTextDrawRva = 0x35aa0u;
inline constexpr uintptr_t kSgreScenarioTextVtableRva = 0x5be330u;
// Mouse device slot of that build:
//   CreateDevice(GUID_SysMouse, module + 0xA96E18, ...)
//   SetDataFormat(c_dfDIMouse2)
//   GetDeviceState(0x14, ...), vtable slot 9 / byte offset 0x48.
inline constexpr uintptr_t kSgreDirectInputMouseDeviceRva = 0xA96E18u;

inline constexpr SgreBuildAnchors kSgreKnownBuilds[] = {
    {kSgreExecutableSha256, kSgreTextDrawRva, kSgreScenarioTextVtableRva,
     kSgreDirectInputMouseDeviceRva, "STEINS;GATE RE:BOOT Steam x64 2026-08-21"},
};
inline constexpr size_t kSgreKnownBuildCount =
    sizeof(kSgreKnownBuilds) / sizeof(kSgreKnownBuilds[0]);

inline const SgreBuildAnchors* FindSgreKnownBuild(const uint8_t* digest,
                                                  size_t digest_bytes) {
  if (digest == nullptr || digest_bytes != 32) return nullptr;
  for (size_t i = 0; i < kSgreKnownBuildCount; ++i) {
    if (std::memcmp(kSgreKnownBuilds[i].exe_sha256.data(), digest, 32) == 0) {
      return &kSgreKnownBuilds[i];
    }
  }
  return nullptr;
}

// ── Signatures ──────────────────────────────────────────────────────────────

// IDA-style byte pattern: hex pairs or "??" wildcards separated by spaces,
// e.g. "48 89 5C 24 ?? 57 48 83 EC 30". The match position plus
// `anchor_offset` is the anchor, unless `rip_disp_offset >= 0`: then the
// anchor is the RIP-relative target of the instruction at the match, decoded
// from the int32 displacement at `rip_disp_offset` with instruction length
// `rip_instr_len` (target = match + rip_instr_len + disp). That form locates
// data anchors (vtable address, global device slot) from the code that
// references them, which is far more stable across builds than data bytes.
//
// A pattern is always scanned inside `section` only.
struct SgreAnchorSignature {
  const char* pattern;
  const char* section;
  SgreAnchorKind kind;
  int32_t anchor_offset;
  int32_t rip_disp_offset;  // < 0: no RIP decoding
  int32_t rip_instr_len;
};

// Signatures are intentionally empty until measured from real builds. Fill
// the pattern text only; everything else is the decoding contract for that
// pattern. Keep one entry per anchor; do not add per-game rows here — that is
// what kSgreKnownBuilds is for.
inline constexpr SgreAnchorSignature kSgreTextDrawSignature = {
    "", ".text", SgreAnchorKind::kCode, 0, -1, 0};
inline constexpr SgreAnchorSignature kSgreScenarioTextVtableSignature = {
    "", ".text", SgreAnchorKind::kVtable, 0, -1, 0};
inline constexpr SgreAnchorSignature kSgreDirectInputMouseDeviceSignature = {
    "", ".text", SgreAnchorKind::kWritableData, 0, -1, 0};

inline constexpr size_t kSgreSignatureMaxBytes = 64;

struct SgrePatternByte {
  uint8_t value = 0;
  bool wildcard = false;
};

inline int SgreHexNibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// Returns the number of parsed bytes, 0 for an empty or malformed pattern.
inline size_t ParseSgreSignaturePattern(const char* text,
                                        SgrePatternByte* out,
                                        size_t capacity) {
  if (text == nullptr || out == nullptr || capacity == 0) return 0;
  size_t count = 0;
  const char* p = text;
  while (*p != '\0') {
    if (*p == ' ') {
      ++p;
      continue;
    }
    if (count >= capacity) return 0;
    const char a = p[0];
    const char b = a == '\0' ? '\0' : p[1];
    if (b == '\0') return 0;
    if (a == '?' && b == '?') {
      out[count].value = 0;
      out[count].wildcard = true;
    } else {
      const int hi = SgreHexNibble(a);
      const int lo = SgreHexNibble(b);
      if (hi < 0 || lo < 0) return 0;
      out[count].value = static_cast<uint8_t>((hi << 4) | lo);
      out[count].wildcard = false;
    }
    ++count;
    p += 2;
    if (*p != '\0' && *p != ' ') return 0;
  }
  return count;
}

// ── Image view ──────────────────────────────────────────────────────────────

struct SgreImageSection {
  char name[9] = {};
  uintptr_t rva = 0;
  size_t size = 0;
  const uint8_t* bytes = nullptr;  // `size` readable bytes
  bool executable = false;
  bool writable = false;
};

inline constexpr size_t kSgreImageMaxSections = 32;

struct SgreImageView {
  uintptr_t image_base = 0;  // address that absolute pointers are relative to
  SgreImageSection sections[kSgreImageMaxSections] = {};
  size_t section_count = 0;

  const SgreImageSection* FindSection(const char* name) const {
    if (name == nullptr) return nullptr;
    for (size_t i = 0; i < section_count; ++i) {
      if (std::strncmp(sections[i].name, name, sizeof(sections[i].name)) ==
          0) {
        return &sections[i];
      }
    }
    return nullptr;
  }
  const SgreImageSection* SectionContaining(uintptr_t rva) const {
    for (size_t i = 0; i < section_count; ++i) {
      const SgreImageSection& s = sections[i];
      if (rva >= s.rva && rva - s.rva < s.size) return &s;
    }
    return nullptr;
  }
};

// ── Resolution ──────────────────────────────────────────────────────────────

inline bool SgreStructureAccepts(SgreAnchorKind kind, uintptr_t rva,
                                 const SgreImageView& image) {
  const SgreImageSection* home = image.SectionContaining(rva);
  if (home == nullptr) return false;
  switch (kind) {
    case SgreAnchorKind::kCode:
      return home->executable;
    case SgreAnchorKind::kWritableData:
      return home->writable && !home->executable;
    case SgreAnchorKind::kVtable: {
      if (home->executable || home->writable) return false;
      const size_t offset = static_cast<size_t>(rva - home->rva);
      if (home->size - offset < sizeof(uintptr_t)) return false;
      uintptr_t slot0 = 0;
      std::memcpy(&slot0, home->bytes + offset, sizeof(slot0));
      if (slot0 < image.image_base) return false;
      const SgreImageSection* target =
          image.SectionContaining(slot0 - image.image_base);
      return target != nullptr && target->executable;
    }
  }
  return false;
}

inline SgreResolvedAnchor ResolveSgreAnchorBySignature(
    const SgreAnchorSignature& signature, const SgreImageView& image) {
  SgreResolvedAnchor result;
  if (signature.pattern == nullptr || signature.pattern[0] == '\0') {
    result.source = SgreAnchorSource::kSignatureEmpty;
    return result;
  }
  SgrePatternByte pattern[kSgreSignatureMaxBytes];
  const size_t length =
      ParseSgreSignaturePattern(signature.pattern, pattern,
                                kSgreSignatureMaxBytes);
  const bool rip_contract_broken =
      signature.rip_disp_offset >= 0 &&
      (signature.rip_instr_len <= 0 ||
       static_cast<size_t>(signature.rip_disp_offset) + sizeof(int32_t) >
           static_cast<size_t>(signature.rip_instr_len));
  if (length == 0 || rip_contract_broken) {
    result.source = SgreAnchorSource::kSignatureInvalid;
    return result;
  }
  const SgreImageSection* section = image.FindSection(signature.section);
  if (section == nullptr || section->bytes == nullptr ||
      section->size < length) {
    result.source = SgreAnchorSource::kSignatureMissing;
    return result;
  }

  size_t matches = 0;
  size_t match_offset = 0;
  for (size_t at = 0; at + length <= section->size; ++at) {
    size_t i = 0;
    for (; i < length; ++i) {
      if (!pattern[i].wildcard && section->bytes[at + i] != pattern[i].value) {
        break;
      }
    }
    if (i != length) continue;
    if (++matches > 1) break;
    match_offset = at;
  }
  if (matches == 0) {
    result.source = SgreAnchorSource::kSignatureMissing;
    return result;
  }
  if (matches > 1) {
    result.source = SgreAnchorSource::kSignatureAmbiguous;
    return result;
  }

  uintptr_t rva = section->rva + match_offset;
  if (signature.rip_disp_offset >= 0) {
    const size_t disp_at =
        match_offset + static_cast<size_t>(signature.rip_disp_offset);
    if (disp_at + sizeof(int32_t) > section->size) {
      result.source = SgreAnchorSource::kStructureRejected;
      return result;
    }
    int32_t disp = 0;
    std::memcpy(&disp, section->bytes + disp_at, sizeof(disp));
    rva = static_cast<uintptr_t>(
        static_cast<intptr_t>(rva) + signature.rip_instr_len + disp);
  }
  rva = static_cast<uintptr_t>(static_cast<intptr_t>(rva) +
                               signature.anchor_offset);
  if (!SgreStructureAccepts(signature.kind, rva, image)) {
    result.source = SgreAnchorSource::kStructureRejected;
    return result;
  }
  result.rva = rva;
  result.source = SgreAnchorSource::kSignature;
  return result;
}

inline SgreAnchorSet ResolveSgreAnchors(const uint8_t* digest,
                                        size_t digest_bytes,
                                        const SgreImageView& image) {
  SgreAnchorSet set;
  if (const SgreBuildAnchors* build =
          FindSgreKnownBuild(digest, digest_bytes)) {
    set.known_build = true;
    set.text_draw = {build->text_draw_rva, SgreAnchorSource::kKnownBuild};
    set.scenario_text_vtable = {build->scenario_text_vtable_rva,
                                SgreAnchorSource::kKnownBuild};
    set.direct_input_mouse_device = {build->direct_input_mouse_device_rva,
                                     SgreAnchorSource::kKnownBuild};
    return set;
  }
  set.text_draw = ResolveSgreAnchorBySignature(kSgreTextDrawSignature, image);
  set.scenario_text_vtable =
      ResolveSgreAnchorBySignature(kSgreScenarioTextVtableSignature, image);
  set.direct_input_mouse_device = ResolveSgreAnchorBySignature(
      kSgreDirectInputMouseDeviceSignature, image);
  return set;
}

inline const char* SgreAnchorSourceName(SgreAnchorSource source) {
  switch (source) {
    case SgreAnchorSource::kUnresolved: return "unresolved";
    case SgreAnchorSource::kKnownBuild: return "known_build";
    case SgreAnchorSource::kSignature: return "signature";
    case SgreAnchorSource::kSignatureEmpty: return "signature_empty";
    case SgreAnchorSource::kSignatureInvalid: return "signature_invalid";
    case SgreAnchorSource::kSignatureMissing: return "signature_missing";
    case SgreAnchorSource::kSignatureAmbiguous: return "signature_ambiguous";
    case SgreAnchorSource::kStructureRejected: return "structure_rejected";
  }
  return "unknown";
}

}  // namespace fushi_voice_hook
