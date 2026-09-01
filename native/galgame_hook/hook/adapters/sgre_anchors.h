#pragma once

// SGRE (M2 wind3d11 runtime) anchor resolution.
//
// Identity used to be a single executable SHA-256 and every engine-internal
// address was a fixed RVA guarded by that hash. That made the adapter a patch
// for one build, not an engine adapter: a Steam update or a different regional
// depot silently disabled text, geometry, input shield and audio at once.
//
// This header separates the three concerns:
//   1. Family identity never depends on a hash. The optional voice archive can
//      prove the audio family, while a complete lookup anchor proof can admit
//      text/lookup even when that archive is absent.
//   2. Known builds: one row per measured executable, hash -> RVAs. A hash hit
//      is only an additional consistency check; it never bypasses the same
//      signatures and structural proof required from an unknown build.
//   3. Unknown builds: each anchor is resolved independently by a byte
//      signature scanned over the mapped image. Raw hits are decoded and
//      de-duplicated by final RVA; independent references must have exactly one
//      structurally valid intersection. Otherwise the anchor stays unresolved
//      and nothing is hooked at a guessed address. The draw function is also
//      tied back to the scenario vtable and x64 unwind metadata.
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
  kVtable = 1,       // aligned read-only vtable storage
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
  // RawImageEx.drawText/drawTextAlign share this native boundary. It is a
  // second renderer path used by PSB/Squirrel UI labels (item titles, menus),
  // independent from the scenario TextDraw surface above. Keep it optional:
  // a build may retain scenario lookup while changing this UI ABI.
  SgreResolvedAnchor ui_draw_text;
  // RawImageEx UI lookup is a chained proof. drawText only supplies UTF-8
  // identity; VectorFont rasterization supplies glyph-local cells, RawImage
  // upload transfers those cells to LayerRawTex, and LayerRawTex::draw plus
  // ComputeScreenAabb supplies the live client-pixel transform.  The vtable
  // and renderer-context slot independently bind the two terminal anchors to
  // the engine object graph.  None of these anchors is safe in isolation.
  SgreResolvedAnchor ui_raster_text;
  SgreResolvedAnchor ui_raw_image_upload;
  SgreResolvedAnchor ui_layer_raw_tex_draw;
  SgreResolvedAnchor ui_layer_raw_tex_vtable;
  SgreResolvedAnchor ui_compute_screen_aabb;
  SgreResolvedAnchor ui_renderer_context;
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
  bool ui_draw_text_available() const { return ui_draw_text.resolved(); }
  bool ui_lookup_chain_available() const {
    return ui_draw_text.resolved() && ui_raster_text.resolved() &&
           ui_raw_image_upload.resolved() &&
           ui_layer_raw_tex_draw.resolved() &&
           ui_layer_raw_tex_vtable.resolved() &&
           ui_compute_screen_aabb.resolved() &&
           ui_renderer_context.resolved();
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
// `section == nullptr` scans every executable section and requires global
// uniqueness. Tests and offline tools may still name one exact section.
struct SgreAnchorSignature {
  const char* pattern;
  const char* section;
  SgreAnchorKind kind;
  int32_t anchor_offset;
  int32_t rip_disp_offset;  // < 0: no RIP decoding
  int32_t rip_instr_len;
};

// These patterns describe the SGRE/M2 object ABI used by the adapter rather
// than one executable address. Offsets such as TextRender's glyph-vector
// fields are deliberately retained: if a later build changes that layout, the
// current capture code is no longer safe and resolution must fail closed.
//
// TextDraw is located inside the function body. ResolveSgreTextDraw() maps the
// body candidates through the x64 PE exception directory to function entries
// and requires the scenario vtable's draw slot to name the unique intersection.
inline constexpr SgreAnchorSignature kSgreTextDrawSignature = {
    "F3 0F 10 ?? B0 03 00 00 "
    "F3 0F 58 ?? A8 03 00 00 "
    "F3 0F 58 ?? C0 03 00 00 "
    "F3 ?? 0F 10 ?? B4 03 00 00 "
    "F3 ?? 0F 58 ?? AC 03 00 00 "
    "F3 ?? 0F 58 ?? C4 03 00 00 "
    "48 8B ?? D0 02 00 00 "
    "48 3B ?? D8 02 00 00 "
    "74 ?? "
    "3B ?? CC 03 00 00 "
    "7D ?? "
    "4C 8B ??",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};

// RawImageEx.drawText/drawTextAlign native implementation. The first
// signature identifies the seven-argument x64 ABI at the function entry:
//   (RawImageEx, font descriptor, UTF-8 text, x, y, hAlign, vAlign).
// The second signature independently proves the style layout consumed by that
// implementation: destination origin/extent at +0x60..+0x6c followed by the
// colour/effect words at +0x70..+0x84. Both hits are mapped through the PE
// exception directory and must name the same unique function. This is an
// engine/codegen signature, never a build RVA or executable-hash shortcut.
inline constexpr SgreAnchorSignature kSgreUiDrawTextEntrySignature = {
    "48 85 D2 "
    "0F 84 ?? ?? ?? ?? "
    "48 8B C4 "
    "53 55 56 57 41 54 41 55 41 56 41 57 "
    "48 81 EC ?? ?? 00 00 "
    "0F 29 70 ?? "
    "0F 29 78 ?? "
    "48 8B 05 ?? ?? ?? ?? "
    "48 33 C4 "
    "48 89 84 24 ?? ?? 00 00 "
    "41 8B F9 "
    "44 89 8C 24 ?? ?? 00 00 "
    "49 8B D8 "
    "4C 8B E9",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};

inline constexpr SgreAnchorSignature kSgreUiDrawTextLayoutSignature = {
    "41 8B 9D 84 00 00 00 "
    "41 8B BD 80 00 00 00 "
    "41 8B 75 7C "
    "41 8B 6D 78 "
    "45 8B 75 74 "
    "45 8B 7D 70 "
    "45 8B 65 6C "
    "45 8B 6D 68 "
    "48 8B ?? ?? ?? 00 00 00 "
    "8B 42 64 "
    "89 84 24 ?? ?? 00 00 "
    "8B 42 60 "
    "89 84 24 ?? ?? 00 00",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};

// The drawText common calls VectorFont rasterization after laying out the
// glyph-vector records.  Resolve the call target and independently map a
// raster body signature through x64 unwind metadata; their intersection is
// the only ABI admitted by the detour.
inline constexpr SgreAnchorSignature kSgreUiRasterCallSignature = {
    "89 5C 24 70 89 7C 24 68 89 74 24 60 89 6C 24 58 "
    "44 89 74 24 50 44 89 7C 24 48 F3 0F 11 74 24 40 "
    "F3 0F 11 7C 24 38 48 8D 84 24 C0 00 00 00 "
    "48 89 44 24 30 44 89 64 24 28 44 89 6C 24 20 "
    "44 8B 8C 24 84 00 00 00 44 8B 84 24 88 00 00 00 "
    "48 8B 8C 24 98 00 00 00 E8 ?? ?? ?? ?? "
    "48 8B 84 24 90 00 00 00 C6 40 58 01",
    nullptr, SgreAnchorKind::kCode, 0, 0x56, 0x5a};
inline constexpr SgreAnchorSignature kSgreUiRasterEntrySignature = {
    "48 8B C4 55 53 56 57 41 54 41 55 41 56 41 57 "
    "48 8D 68 88 48 81 EC 38 01 00 00 "
    "0F 29 70 A8 0F 29 78 98 44 0F 29 40 88 "
    "44 0F 29 88 78 FF FF FF 48 8B 05 ?? ?? ?? ?? 48 33 C4 "
    "48 89 45 E8 41 8B F1 44 89 4C 24 40 44 89 44 24 44 "
    "4C 8B E2 48 89 54 24 48 4C 8B E9 8B 41 50 "
    "45 0F 57 C0 F3 4C 0F 2A C0 F3 44 0F 58 85 C0 00 00 00",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};
inline constexpr SgreAnchorSignature kSgreUiRasterBodySignature = {
    "41 8B 5C 24 18 C1 E3 02 48 8D 4D D8 E8 ?? ?? ?? ?? 90 "
    "41 0F AF 74 24 18 03 74 24 44 C1 E6 02 8B CE "
    "49 8B 14 24 49 8B 44 24 08 48 2B C2 48 3B C1",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};

// RawImage -> native LayerRawTex pixel upload.  The entry proves RawImage
// width/height at +0x18/+0x1c and the body proves row-wise transfer followed
// by texture commit.  Both signatures must map to one function entry.
inline constexpr SgreAnchorSignature kSgreUiRawImageUploadEntrySignature = {
    "40 57 41 55 48 83 EC 48 "
    "8B 42 18 48 8B FA 0F 29 74 24 20 4C 8B E9 0F 57 F6 "
    "F3 48 0F 2A F0 E8 ?? ?? ?? ?? 0F 2E F0 "
    "0F 8A ?? ?? ?? ?? 0F 85 ?? ?? ?? ?? 8B 47 1C",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};
inline constexpr SgreAnchorSignature kSgreUiRawImageUploadBodySignature = {
    "4C 8B C5 48 8B D3 48 8B CF E8 ?? ?? ?? ?? "
    "49 03 DE 49 03 FF 48 83 EE 01 75 ?? "
    "4C 8B 7C 24 ?? 4C 8B 74 24 ?? "
    "49 8B 8D B0 00 00 00 E8 ?? ?? ?? ??",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};

// Native LayerRawTex draw.  Its local image origin is +0xb8/+0xbc; the body
// corroborates the colour/vertex packing performed before the engine draw.
inline constexpr SgreAnchorSignature kSgreUiLayerRawTexDrawEntrySignature = {
    "40 53 48 83 EC 40 48 8B 01 48 8D 54 24 50 48 8B D9 "
    "FF 50 50 F3 0F 10 83 B8 00 00 00 F3 0F 10 8B BC 00 00 00 "
    "0F B6 93 C4 00 00 00 0B 93 C0 00 00 00",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};
inline constexpr SgreAnchorSignature kSgreUiLayerRawTexDrawBodySignature = {
    "F3 0F 11 44 24 30 F3 0F 58 00 "
    "F3 0F 11 4C 24 34 F3 0F 58 48 04 "
    "0F B6 C2 C1 E0 08 44 0B C0 F3 0F 11 44 24 38 "
    "8B C2 41 C1 E0 08 C1 E8 10 0F B6 C8",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};

// LayerRawTex constructor installs this vtable.  Slot 4 is the draw method
// and must equal the independently resolved draw entry above.
inline constexpr SgreAnchorSignature kSgreUiLayerRawTexVtableSignature = {
    "48 8D 05 ?? ?? ?? ?? 48 89 06 33 FF "
    "48 89 BE B8 00 00 00 C7 86 C0 00 00 00 00 FF FF FF "
    "48 C7 86 C4 00 00 00 FF 00 00 00 C6 86 CC 00 00 00 01 "
    "C7 86 D0 00 00 00 03 00 00 00",
    nullptr, SgreAnchorKind::kVtable, 0, 3, 7};

// Engine client-pixel AABB helper.  Entry and body map to one function, and
// the M2 camera locator callsite must call that exact entry.  The same unique
// callsite also exposes the renderer-context global slot.
inline constexpr SgreAnchorSignature kSgreUiScreenAabbEntrySignature = {
    "48 8B C4 48 89 58 18 55 56 57 48 8D 68 D8 "
    "48 81 EC 10 01 00 00 0F 29 70 D8 0F 29 78 C8 "
    "44 0F 29 40 B8 44 0F 29 48 A8 44 0F 29 50 98 44 0F 29 58 88",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};
inline constexpr SgreAnchorSignature kSgreUiScreenAabbBodySignature = {
    "48 8B 41 40 48 8B F2 48 8B 51 70 48 83 E9 80 "
    "F3 45 0F 10 28 48 83 EA 30 F3 41 0F 10 70 04 "
    "F3 45 0F 10 40 08 F3 45 0F 10 60 0C "
    "4C 8D 44 24 40 8B 58 0C 8B 78 10",
    nullptr, SgreAnchorKind::kCode, 0, -1, 0};
inline constexpr SgreAnchorSignature kSgreUiScreenAabbCallSignature = {
    "48 8B 0D ?? ?? ?? ?? 4C 8D 44 24 30 48 8D 54 24 50 "
    "48 8B D8 E8 ?? ?? ?? ?? F3 44 0F 10 40 08 F3 44 0F 10 08",
    nullptr, SgreAnchorKind::kCode, 0, 21, 25};
inline constexpr SgreAnchorSignature kSgreUiRendererContextSignature = {
    "48 8B 0D ?? ?? ?? ?? 4C 8D 44 24 30 48 8D 54 24 50 "
    "48 8B D8 E8 ?? ?? ?? ?? F3 44 0F 10 40 08 F3 44 0F 10 08",
    nullptr, SgreAnchorKind::kWritableData, 0, 3, 7};
inline constexpr SgreAnchorSignature
    kSgreUiRendererContextShutdownSignature = {
        "48 83 EC 28 48 8B 0D ?? ?? ?? ?? 48 85 C9 74 ?? "
        "48 8B 01 BA 01 00 00 00 FF 10 "
        "48 C7 05 ?? ?? ?? ?? 00 00 00 00 48 83 C4 28 C3",
        nullptr, SgreAnchorKind::kWritableData, 0, 7, 11};

// Two independent construction paths must decode the same read-only vtable.
inline constexpr SgreAnchorSignature kSgreScenarioTextVtableSignature = {
    "48 8D 05 ?? ?? ?? ?? "
    "8B DA "
    "48 89 01 "
    "48 8B F9 "
    "48 8D 05 ?? ?? ?? ?? "
    "48 89 81 B0 00 00 00",
    nullptr, SgreAnchorKind::kVtable, 0, 3, 7};
inline constexpr SgreAnchorSignature
    kSgreScenarioTextVtableCorroborationSignature = {
        "48 8D 05 ?? ?? ?? ?? "
        "48 89 06 "
        "48 8D 05 ?? ?? ?? ?? "
        "48 89 86 B0 00 00 00 "
        "48 8D 8E 30 04 00 00",
        nullptr, SgreAnchorKind::kVtable, 0, 3, 7};

// CreateDevice's output pointer and the immediate GetDeviceState poll must
// decode to the same writable, non-executable global device slot.
inline constexpr SgreAnchorSignature kSgreDirectInputMouseDeviceSignature = {
    "C6 05 ?? ?? ?? ?? 01 "
    "48 8B 0D ?? ?? ?? ?? "
    "4C 8D 05 ?? ?? ?? ?? "
    "45 33 C9 "
    "48 8D 15 ?? ?? ?? ?? "
    "48 8B 01 "
    "FF 50 18 "
    "85 C0",
    nullptr, SgreAnchorKind::kWritableData, 0, 17, 21};
inline constexpr SgreAnchorSignature
    kSgreDirectInputMouseDeviceCorroborationSignature = {
        "48 8B 0D ?? ?? ?? ?? "
        "48 85 C9 "
        "0F 84 ?? ?? ?? ?? "
        "48 8B 01 "
        "4C 8D 44 24 30 "
        "BA 14 00 00 00 "
        "FF 50 48",
        nullptr, SgreAnchorKind::kWritableData, 0, 3, 7};

inline constexpr size_t kSgreSignatureMaxBytes = 128;

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
  // PE OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION]. The
  // directory is authoritative; linkers may rename or merge its section.
  uintptr_t exception_directory_rva = 0;
  size_t exception_directory_size = 0;
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

inline bool SgreImageSpanAvailable(const SgreImageView& image, uintptr_t rva,
                                   size_t bytes) {
  if (bytes == 0) return false;
  const SgreImageSection* section = image.SectionContaining(rva);
  if (section == nullptr || section->bytes == nullptr) return false;
  const size_t offset = static_cast<size_t>(rva - section->rva);
  return offset <= section->size && bytes <= section->size - offset;
}

inline bool SgreStructureAccepts(SgreAnchorKind kind, uintptr_t rva,
                                 const SgreImageView& image) {
  const SgreImageSection* home = image.SectionContaining(rva);
  if (home == nullptr) return false;
  switch (kind) {
    case SgreAnchorKind::kCode:
      return home->executable;
    case SgreAnchorKind::kWritableData:
      return home->writable && !home->executable &&
             rva % alignof(uintptr_t) == 0 &&
             SgreImageSpanAvailable(image, rva, sizeof(uintptr_t));
    case SgreAnchorKind::kVtable: {
      // The sensor consumes slot 4 only. ResolveSgreTextDraw validates that
      // slot; unrelated virtual methods may legitimately be folded or thunked
      // outside the main image in a candidate build.
      return !home->executable && !home->writable &&
             rva % alignof(uintptr_t) == 0 &&
             SgreImageSpanAvailable(image, rva, sizeof(uintptr_t));
    }
  }
  return false;
}

inline constexpr size_t kSgreAnchorCandidateMax = 64;

struct SgreAnchorCandidates {
  std::array<uintptr_t, kSgreAnchorCandidateMax> rvas = {};
  size_t count = 0;
  SgreAnchorSource failure = SgreAnchorSource::kUnresolved;
  bool overflow = false;
};

inline bool AddUniqueSgreAnchorCandidate(SgreAnchorCandidates* candidates,
                                         uintptr_t rva) {
  if (candidates == nullptr) return false;
  for (size_t i = 0; i < candidates->count; ++i) {
    if (candidates->rvas[i] == rva) return true;
  }
  if (candidates->count >= candidates->rvas.size()) {
    candidates->overflow = true;
    candidates->failure = SgreAnchorSource::kSignatureAmbiguous;
    return false;
  }
  candidates->rvas[candidates->count++] = rva;
  return true;
}

inline bool DecodeSgreSignatureMatch(const SgreAnchorSignature& signature,
                                     const SgreImageSection& section,
                                     size_t match_offset, uintptr_t* rva_out) {
  if (rva_out == nullptr || match_offset >= section.size) return false;
  int64_t decoded = static_cast<int64_t>(section.rva + match_offset);
  if (signature.rip_disp_offset >= 0) {
    const size_t disp_at =
        match_offset + static_cast<size_t>(signature.rip_disp_offset);
    if (disp_at > section.size ||
        sizeof(int32_t) > section.size - disp_at) {
      return false;
    }
    int32_t displacement = 0;
    std::memcpy(&displacement, section.bytes + disp_at,
                sizeof(displacement));
    decoded += static_cast<int64_t>(signature.rip_instr_len) + displacement;
  }
  decoded += signature.anchor_offset;
  if (decoded <= 0 ||
      static_cast<uint64_t>(decoded) > static_cast<uint64_t>(UINTPTR_MAX)) {
    return false;
  }
  *rva_out = static_cast<uintptr_t>(decoded);
  return true;
}

// Collect every raw match across all selected executable sections, decode it,
// discard structurally impossible targets, and de-duplicate by the final RVA.
// Consumers can then intersect independent evidence instead of rejecting a
// candidate build merely because the compiler emitted the same byte sequence
// more than once.
inline SgreAnchorCandidates CollectSgreAnchorCandidates(
    const SgreAnchorSignature& signature, const SgreImageView& image) {
  SgreAnchorCandidates result;
  if (signature.pattern == nullptr || signature.pattern[0] == '\0') {
    result.failure = SgreAnchorSource::kSignatureEmpty;
    return result;
  }
  SgrePatternByte pattern[kSgreSignatureMaxBytes];
  const size_t length = ParseSgreSignaturePattern(
      signature.pattern, pattern, kSgreSignatureMaxBytes);
  const bool rip_contract_broken =
      signature.rip_disp_offset >= 0 &&
      (signature.rip_instr_len <= 0 ||
       static_cast<size_t>(signature.rip_instr_len) > length ||
       static_cast<size_t>(signature.rip_disp_offset) + sizeof(int32_t) >
           length);
  if (length == 0 || rip_contract_broken) {
    result.failure = SgreAnchorSource::kSignatureInvalid;
    return result;
  }

  size_t raw_matches = 0;
  for (size_t section_index = 0; section_index < image.section_count;
       ++section_index) {
    const SgreImageSection& section = image.sections[section_index];
    const bool section_selected = signature.section == nullptr
                                      ? section.executable
                                      : std::strncmp(
                                            section.name, signature.section,
                                            sizeof(section.name)) == 0;
    if (!section_selected || section.bytes == nullptr ||
        section.size < length) {
      continue;
    }
    for (size_t at = 0; at + length <= section.size; ++at) {
      size_t i = 0;
      for (; i < length; ++i) {
        if (!pattern[i].wildcard &&
            section.bytes[at + i] != pattern[i].value) {
          break;
        }
      }
      if (i != length) continue;
      ++raw_matches;
      uintptr_t decoded = 0;
      if (!DecodeSgreSignatureMatch(signature, section, at, &decoded) ||
          !SgreStructureAccepts(signature.kind, decoded, image)) {
        continue;
      }
      if (!AddUniqueSgreAnchorCandidate(&result, decoded)) return result;
    }
  }
  if (result.count == 0) {
    result.failure = raw_matches == 0
                         ? SgreAnchorSource::kSignatureMissing
                         : SgreAnchorSource::kStructureRejected;
  } else if (result.count == 1) {
    result.failure = SgreAnchorSource::kSignature;
  } else {
    result.failure = SgreAnchorSource::kSignatureAmbiguous;
  }
  return result;
}

inline SgreResolvedAnchor ResolveSgreAnchorBySignature(
    const SgreAnchorSignature& signature, const SgreImageView& image) {
  const SgreAnchorCandidates candidates =
      CollectSgreAnchorCandidates(signature, image);
  if (!candidates.overflow && candidates.count == 1) {
    return {candidates.rvas[0], SgreAnchorSource::kSignature};
  }
  SgreResolvedAnchor result;
  result.source = candidates.failure;
  return result;
}

inline SgreResolvedAnchor RejectSgreAnchorStructure() {
  SgreResolvedAnchor result;
  result.source = SgreAnchorSource::kStructureRejected;
  return result;
}

inline bool ReadSgreImagePointer(const SgreImageView& image, uintptr_t rva,
                                 uintptr_t* value) {
  if (value == nullptr) return false;
  const SgreImageSection* section = image.SectionContaining(rva);
  if (section == nullptr || section->bytes == nullptr) return false;
  const size_t offset = static_cast<size_t>(rva - section->rva);
  if (offset > section->size ||
      section->size - offset < sizeof(uintptr_t)) {
    return false;
  }
  std::memcpy(value, section->bytes + offset, sizeof(*value));
  return true;
}

inline bool SgreAbsolutePointerRva(const SgreImageView& image,
                                   uintptr_t address, uintptr_t* rva) {
  if (rva == nullptr || address < image.image_base) return false;
  const uintptr_t candidate = address - image.image_base;
  if (image.SectionContaining(candidate) == nullptr) return false;
  *rva = candidate;
  return true;
}

// The x64 PE exception directory is an array of RUNTIME_FUNCTION triples.
// SgreImageView records the data-directory bounds from the PE header, so this
// decoder does not depend on the linker naming its containing section .pdata.
// Multiple or malformed entries are rejected rather than selecting the first.
inline uintptr_t FindSgreContainingFunctionBegin(
    const SgreImageView& image, uintptr_t code_rva) {
  constexpr size_t kRuntimeFunctionBytes = sizeof(uint32_t) * 3u;
  if (image.exception_directory_rva == 0 ||
      image.exception_directory_size < kRuntimeFunctionBytes ||
      image.exception_directory_size % kRuntimeFunctionBytes != 0 ||
      !SgreImageSpanAvailable(image, image.exception_directory_rva,
                              image.exception_directory_size)) {
    return 0;
  }
  const SgreImageSection* directory =
      image.SectionContaining(image.exception_directory_rva);
  if (directory == nullptr || directory->bytes == nullptr) return 0;
  const size_t directory_offset = static_cast<size_t>(
      image.exception_directory_rva - directory->rva);
  uintptr_t found = 0;
  for (size_t offset = 0;
       offset + kRuntimeFunctionBytes <= image.exception_directory_size;
       offset += kRuntimeFunctionBytes) {
    uint32_t begin = 0;
    uint32_t end = 0;
    uint32_t unwind = 0;
    const uint8_t* entry = directory->bytes + directory_offset + offset;
    std::memcpy(&begin, entry, sizeof(begin));
    std::memcpy(&end, entry + sizeof(begin), sizeof(end));
    std::memcpy(&unwind, entry + sizeof(begin) + sizeof(end), sizeof(unwind));
    if (begin == 0 || end <= begin || code_rva < begin || code_rva >= end) {
      continue;
    }
    const SgreImageSection* begin_section =
        image.SectionContaining(static_cast<uintptr_t>(begin));
    const SgreImageSection* end_section =
        image.SectionContaining(static_cast<uintptr_t>(end - 1u));
    if (begin_section == nullptr || end_section == nullptr || unwind == 0 ||
        !begin_section->executable || !end_section->executable ||
        !SgreImageSpanAvailable(image, unwind, sizeof(uint8_t))) {
      return 0;
    }
    if (found != 0 && found != begin) return 0;
    found = begin;
  }
  return found;
}

inline SgreResolvedAnchor ResolveSameSgreAnchor(
    const SgreAnchorSignature& primary,
    const SgreAnchorSignature& corroboration,
    const SgreImageView& image) {
  const SgreAnchorCandidates first =
      CollectSgreAnchorCandidates(primary, image);
  if (first.overflow || first.count == 0) {
    SgreResolvedAnchor result;
    result.source = first.failure;
    return result;
  }
  const SgreAnchorCandidates second =
      CollectSgreAnchorCandidates(corroboration, image);
  if (second.overflow || second.count == 0) {
    SgreResolvedAnchor result;
    result.source = second.failure;
    return result;
  }
  SgreAnchorCandidates intersection;
  for (size_t i = 0; i < first.count; ++i) {
    for (size_t j = 0; j < second.count; ++j) {
      if (first.rvas[i] == second.rvas[j] &&
          !AddUniqueSgreAnchorCandidate(&intersection, first.rvas[i])) {
        SgreResolvedAnchor result;
        result.source = SgreAnchorSource::kSignatureAmbiguous;
        return result;
      }
    }
  }
  if (!intersection.overflow && intersection.count == 1) {
    return {intersection.rvas[0], SgreAnchorSource::kSignature};
  }
  SgreResolvedAnchor result;
  result.source = intersection.count == 0
                      ? SgreAnchorSource::kStructureRejected
                      : SgreAnchorSource::kSignatureAmbiguous;
  return result;
}

inline SgreAnchorCandidates CollectSgreContainingFunctions(
    const SgreAnchorSignature& signature, const SgreImageView& image) {
  const SgreAnchorCandidates matches =
      CollectSgreAnchorCandidates(signature, image);
  if (matches.overflow || matches.count == 0) return matches;
  SgreAnchorCandidates functions;
  for (size_t i = 0; i < matches.count; ++i) {
    const uintptr_t function_begin =
        FindSgreContainingFunctionBegin(image, matches.rvas[i]);
    if (function_begin == 0 ||
        !SgreStructureAccepts(SgreAnchorKind::kCode, function_begin, image)) {
      continue;
    }
    if (!AddUniqueSgreAnchorCandidate(&functions, function_begin)) {
      functions.failure = SgreAnchorSource::kSignatureAmbiguous;
      return functions;
    }
  }
  if (functions.count == 0) {
    functions.failure = SgreAnchorSource::kStructureRejected;
  } else if (functions.count == 1) {
    functions.failure = SgreAnchorSource::kSignature;
  } else {
    functions.failure = SgreAnchorSource::kSignatureAmbiguous;
  }
  return functions;
}

inline SgreResolvedAnchor ResolveSameSgreFunction(
    const SgreAnchorSignature& entry, const SgreAnchorSignature& body,
    const SgreImageView& image) {
  const SgreAnchorCandidates entries =
      CollectSgreContainingFunctions(entry, image);
  if (entries.overflow || entries.count == 0) {
    SgreResolvedAnchor result;
    result.source = entries.failure;
    return result;
  }
  const SgreAnchorCandidates bodies =
      CollectSgreContainingFunctions(body, image);
  if (bodies.overflow || bodies.count == 0) {
    SgreResolvedAnchor result;
    result.source = bodies.failure;
    return result;
  }
  SgreAnchorCandidates intersection;
  for (size_t i = 0; i < entries.count; ++i) {
    for (size_t j = 0; j < bodies.count; ++j) {
      if (entries.rvas[i] == bodies.rvas[j] &&
          !AddUniqueSgreAnchorCandidate(&intersection, entries.rvas[i])) {
        SgreResolvedAnchor result;
        result.source = SgreAnchorSource::kSignatureAmbiguous;
        return result;
      }
    }
  }
  if (!intersection.overflow && intersection.count == 1) {
    return {intersection.rvas[0], SgreAnchorSource::kSignature};
  }
  SgreResolvedAnchor result;
  result.source = intersection.count == 0
                      ? SgreAnchorSource::kStructureRejected
                      : SgreAnchorSource::kSignatureAmbiguous;
  return result;
}

inline SgreResolvedAnchor ResolveSgreScenarioTextVtable(
    const SgreImageView& image) {
  return ResolveSameSgreAnchor(
      kSgreScenarioTextVtableSignature,
      kSgreScenarioTextVtableCorroborationSignature, image);
}

inline SgreResolvedAnchor ResolveSgreTextDraw(
    const SgreImageView& image,
    const SgreResolvedAnchor& scenario_text_vtable) {
  if (!scenario_text_vtable.resolved()) {
    SgreResolvedAnchor result;
    result.source = scenario_text_vtable.source;
    return result;
  }
  const SgreAnchorCandidates bodies =
      CollectSgreAnchorCandidates(kSgreTextDrawSignature, image);
  if (bodies.overflow || bodies.count == 0) {
    SgreResolvedAnchor result;
    result.source = bodies.failure;
    return result;
  }
  SgreAnchorCandidates functions;
  for (size_t i = 0; i < bodies.count; ++i) {
    const uintptr_t function_begin =
        FindSgreContainingFunctionBegin(image, bodies.rvas[i]);
    if (function_begin != 0 &&
        SgreStructureAccepts(SgreAnchorKind::kCode, function_begin, image) &&
        !AddUniqueSgreAnchorCandidate(&functions, function_begin)) {
      SgreResolvedAnchor result;
      result.source = SgreAnchorSource::kSignatureAmbiguous;
      return result;
    }
  }

  constexpr size_t kScenarioTextDrawVtableSlot = 4u;
  constexpr size_t kScenarioTextDrawVtableSpan =
      (kScenarioTextDrawVtableSlot + 1u) * sizeof(uintptr_t);
  uintptr_t draw_address = 0;
  uintptr_t draw_rva = 0;
  if (scenario_text_vtable.rva >
          UINTPTR_MAX - kScenarioTextDrawVtableSlot * sizeof(uintptr_t) ||
      !SgreImageSpanAvailable(image, scenario_text_vtable.rva,
                              kScenarioTextDrawVtableSpan) ||
      !ReadSgreImagePointer(
          image,
          scenario_text_vtable.rva +
              kScenarioTextDrawVtableSlot * sizeof(uintptr_t),
          &draw_address) ||
      !SgreAbsolutePointerRva(image, draw_address, &draw_rva)) {
    return RejectSgreAnchorStructure();
  }
  size_t intersections = 0;
  for (size_t i = 0; i < functions.count; ++i) {
    if (functions.rvas[i] == draw_rva) ++intersections;
  }
  return intersections == 1
             ? SgreResolvedAnchor{draw_rva, SgreAnchorSource::kSignature}
             : RejectSgreAnchorStructure();
}

inline SgreResolvedAnchor ResolveSgreUiDrawText(
    const SgreImageView& image) {
  return ResolveSameSgreFunction(kSgreUiDrawTextEntrySignature,
                                 kSgreUiDrawTextLayoutSignature, image);
}

inline SgreResolvedAnchor ResolveSgreUiRasterText(
    const SgreImageView& image) {
  const SgreResolvedAnchor function = ResolveSameSgreFunction(
      kSgreUiRasterEntrySignature, kSgreUiRasterBodySignature, image);
  if (!function.resolved()) return function;
  const SgreResolvedAnchor call_target =
      ResolveSgreAnchorBySignature(kSgreUiRasterCallSignature, image);
  return call_target.resolved() && call_target.rva == function.rva
             ? function
             : RejectSgreAnchorStructure();
}

inline SgreResolvedAnchor ResolveSgreUiRawImageUpload(
    const SgreImageView& image) {
  return ResolveSameSgreFunction(kSgreUiRawImageUploadEntrySignature,
                                 kSgreUiRawImageUploadBodySignature, image);
}

inline SgreResolvedAnchor ResolveSgreUiLayerRawTexDraw(
    const SgreImageView& image) {
  return ResolveSameSgreFunction(kSgreUiLayerRawTexDrawEntrySignature,
                                 kSgreUiLayerRawTexDrawBodySignature, image);
}

inline SgreResolvedAnchor ResolveSgreUiComputeScreenAabb(
    const SgreImageView& image) {
  const SgreResolvedAnchor function =
      ResolveSameSgreFunction(kSgreUiScreenAabbEntrySignature,
                              kSgreUiScreenAabbBodySignature, image);
  if (!function.resolved()) return function;
  const SgreResolvedAnchor call_target = ResolveSgreAnchorBySignature(
      kSgreUiScreenAabbCallSignature, image);
  return call_target.resolved() && call_target.rva == function.rva
             ? function
             : RejectSgreAnchorStructure();
}

inline SgreResolvedAnchor ResolveSgreUiRendererContext(
    const SgreImageView& image) {
  return ResolveSameSgreAnchor(kSgreUiRendererContextSignature,
                               kSgreUiRendererContextShutdownSignature,
                               image);
}

inline SgreResolvedAnchor ResolveSgreDirectInputMouseDevice(
    const SgreImageView& image) {
  return ResolveSameSgreAnchor(
      kSgreDirectInputMouseDeviceSignature,
      kSgreDirectInputMouseDeviceCorroborationSignature, image);
}

inline bool ValidateSgreLookupAnchorStructure(
    const SgreAnchorSet& set, const SgreImageView& image) {
  constexpr size_t kScenarioTextDrawVtableSlot = 4u;
  constexpr size_t kScenarioTextDrawVtableSpan =
      (kScenarioTextDrawVtableSlot + 1u) * sizeof(uintptr_t);
  if (!set.lookup_sensor_available() ||
      !SgreStructureAccepts(SgreAnchorKind::kCode, set.text_draw.rva, image) ||
      !SgreStructureAccepts(SgreAnchorKind::kVtable,
                            set.scenario_text_vtable.rva, image) ||
      !SgreImageSpanAvailable(image, set.scenario_text_vtable.rva,
                              kScenarioTextDrawVtableSpan) ||
      FindSgreContainingFunctionBegin(image, set.text_draw.rva) !=
          set.text_draw.rva) {
    return false;
  }
  uintptr_t draw_address = 0;
  uintptr_t draw_rva = 0;
  return ReadSgreImagePointer(
             image,
             set.scenario_text_vtable.rva +
                 kScenarioTextDrawVtableSlot * sizeof(uintptr_t),
             &draw_address) &&
         SgreAbsolutePointerRva(image, draw_address, &draw_rva) &&
         draw_rva == set.text_draw.rva;
}

inline bool ValidateSgreDirectInputAnchorStructure(
    const SgreAnchorSet& set, const SgreImageView& image) {
  return set.direct_input_shield_available() &&
         SgreStructureAccepts(SgreAnchorKind::kWritableData,
                              set.direct_input_mouse_device.rva, image);
}

inline bool ValidateSgreUiDrawTextAnchorStructure(
    const SgreAnchorSet& set, const SgreImageView& image) {
  constexpr size_t kLayerRawTexDrawVtableSlot = 4u;
  constexpr size_t kLayerRawTexDrawVtableSpan =
      (kLayerRawTexDrawVtableSlot + 1u) * sizeof(uintptr_t);
  if (!set.ui_lookup_chain_available() ||
      !SgreStructureAccepts(SgreAnchorKind::kCode,
                            set.ui_draw_text.rva, image) ||
      !SgreStructureAccepts(SgreAnchorKind::kCode,
                            set.ui_raster_text.rva, image) ||
      !SgreStructureAccepts(SgreAnchorKind::kCode,
                            set.ui_raw_image_upload.rva, image) ||
      !SgreStructureAccepts(SgreAnchorKind::kCode,
                            set.ui_layer_raw_tex_draw.rva, image) ||
      !SgreStructureAccepts(SgreAnchorKind::kVtable,
                            set.ui_layer_raw_tex_vtable.rva, image) ||
      !SgreStructureAccepts(SgreAnchorKind::kCode,
                            set.ui_compute_screen_aabb.rva, image) ||
      !SgreStructureAccepts(SgreAnchorKind::kWritableData,
                            set.ui_renderer_context.rva, image) ||
      !SgreImageSpanAvailable(image, set.ui_layer_raw_tex_vtable.rva,
                              kLayerRawTexDrawVtableSpan)) {
    return false;
  }
  const uintptr_t function_rvas[] = {
      set.ui_draw_text.rva, set.ui_raster_text.rva,
      set.ui_raw_image_upload.rva, set.ui_layer_raw_tex_draw.rva,
      set.ui_compute_screen_aabb.rva};
  for (const uintptr_t function_rva : function_rvas) {
    if (FindSgreContainingFunctionBegin(image, function_rva) != function_rva) {
      return false;
    }
  }
  uintptr_t draw_address = 0;
  uintptr_t draw_rva = 0;
  return ReadSgreImagePointer(
             image,
             set.ui_layer_raw_tex_vtable.rva +
                 kLayerRawTexDrawVtableSlot * sizeof(uintptr_t),
             &draw_address) &&
         SgreAbsolutePointerRva(image, draw_address, &draw_rva) &&
         draw_rva == set.ui_layer_raw_tex_draw.rva;
}

inline void RejectSgreUiLookupChain(SgreAnchorSet* set) {
  if (set == nullptr) return;
  set->ui_draw_text = RejectSgreAnchorStructure();
  set->ui_raster_text = RejectSgreAnchorStructure();
  set->ui_raw_image_upload = RejectSgreAnchorStructure();
  set->ui_layer_raw_tex_draw = RejectSgreAnchorStructure();
  set->ui_layer_raw_tex_vtable = RejectSgreAnchorStructure();
  set->ui_compute_screen_aabb = RejectSgreAnchorStructure();
  set->ui_renderer_context = RejectSgreAnchorStructure();
}

inline bool ValidateSgreAnchorSetStructure(const SgreAnchorSet& set,
                                           const SgreImageView& image) {
  return ValidateSgreLookupAnchorStructure(set, image) &&
         ValidateSgreDirectInputAnchorStructure(set, image);
}

inline void RequireSgreKnownBuildRva(SgreResolvedAnchor* anchor,
                                     uintptr_t expected_rva) {
  if (anchor == nullptr || !anchor->resolved()) return;
  if (anchor->rva != expected_rva) {
    *anchor = RejectSgreAnchorStructure();
    return;
  }
  anchor->source = SgreAnchorSource::kKnownBuild;
}

inline SgreAnchorSet ResolveSgreAnchors(const uint8_t* digest,
                                        size_t digest_bytes,
                                        const SgreImageView& image) {
  SgreAnchorSet set;
  const SgreBuildAnchors* build =
      FindSgreKnownBuild(digest, digest_bytes);
  set.known_build = build != nullptr;

  // A measured hash does not bypass this path. Loaded-image patching, a stale
  // row, or an ABI-changing rebuild must fail the same proof as any unknown
  // executable instead of trusting addresses merely because the file hash was
  // once recognized.
  set.scenario_text_vtable = ResolveSgreScenarioTextVtable(image);
  set.text_draw = ResolveSgreTextDraw(image, set.scenario_text_vtable);
  set.ui_draw_text = ResolveSgreUiDrawText(image);
  set.ui_raster_text = ResolveSgreUiRasterText(image);
  set.ui_raw_image_upload = ResolveSgreUiRawImageUpload(image);
  set.ui_layer_raw_tex_draw = ResolveSgreUiLayerRawTexDraw(image);
  set.ui_layer_raw_tex_vtable = ResolveSgreAnchorBySignature(
      kSgreUiLayerRawTexVtableSignature, image);
  set.ui_compute_screen_aabb = ResolveSgreUiComputeScreenAabb(image);
  set.ui_renderer_context = ResolveSgreUiRendererContext(image);
  set.direct_input_mouse_device =
      ResolveSgreDirectInputMouseDevice(image);

  if (set.lookup_sensor_available() &&
      !ValidateSgreLookupAnchorStructure(set, image)) {
    set.text_draw = RejectSgreAnchorStructure();
    set.scenario_text_vtable = RejectSgreAnchorStructure();
  }
  if (set.direct_input_shield_available() &&
      !ValidateSgreDirectInputAnchorStructure(set, image)) {
    set.direct_input_mouse_device = RejectSgreAnchorStructure();
  }
  const bool any_ui_anchor =
      set.ui_draw_text.resolved() || set.ui_raster_text.resolved() ||
      set.ui_raw_image_upload.resolved() ||
      set.ui_layer_raw_tex_draw.resolved() ||
      set.ui_layer_raw_tex_vtable.resolved() ||
      set.ui_compute_screen_aabb.resolved() ||
      set.ui_renderer_context.resolved();
  if (any_ui_anchor &&
      (!set.ui_lookup_chain_available() ||
       !ValidateSgreUiDrawTextAnchorStructure(set, image))) {
    RejectSgreUiLookupChain(&set);
  }

  if (build != nullptr) {
    RequireSgreKnownBuildRva(&set.text_draw, build->text_draw_rva);
    RequireSgreKnownBuildRva(&set.scenario_text_vtable,
                             build->scenario_text_vtable_rva);
    RequireSgreKnownBuildRva(&set.direct_input_mouse_device,
                             build->direct_input_mouse_device_rva);
  }
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
