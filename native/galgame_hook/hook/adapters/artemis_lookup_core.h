#pragma once

// Artemis Engine in-game lookup: pure, unit-tested half.
//
// Engine facts (amanatu.exe, Artemis x64, measured 2026-09-27 with Frida):
//   * Every rendered character is its own scene-graph node ("glyph").  The
//     text layer creates it through a virtual factory
//       Glyph* Layer::CreateGlyph(Layer*, const char* one_char, ...)
//     = `operator new(0x108)` + the glyph constructor.  The constructor stores
//     the layer's colours, zeroes the cell (+0x88 width, +0x8c height) and
//     measures the single multibyte character it was handed.  LunaHook's
//     Artemis text hook sits on that constructor, so this provider hooks the
//     factory instead and never touches LunaHook's site.
//   * A glyph's world transform is a 2x3 affine matrix at +0x50
//     {a, b, tx, c, d, ty}, owned by a matrix object whose vptr is at +0x48
//     (the parent's world matrix follows at +0x68 with the same vptr).  The
//     cell size lives at +0x88/+0x8c.  World units are engine client pixels
//     (identical to the 1280x720 design canvas only at a 1280x720 client).
//   * Visible glyphs reach vtable slot 4 once per rendered frame; a hidden
//     message window (right click), a closed layer or a not-yet-typed glyph
//     never does.  That call is the visibility truth this provider uses.
//   * Input::Update(input, now) polls GetAsyncKeyState for all 256 keys once
//     per frame into a per-key state array at input+0x18: 0 idle, 1 pressed,
//     2 held, 3 repeat, 4 released.  Dialogue advance consumes that array (a
//     click whose state is zeroed after Update never advances; measured).
//     Zeroing a held key makes the next poll report "pressed" again, so a
//     claimed press must be masked every frame until the button is released.
//   * The engine maps the cursor as design = (client - off) * k with
//     k = input+0x0c, off = input+0x10/+0x14 and the game HWND at +0x3158
//     (uniform letterbox; measured 960x600 -> k=4/3, off_y=30).  Glyph world
//     matrices already include the inverse root transform, i.e. world units
//     are engine client pixels; k is the per-glyph cross-check of that.
//
// Every one of those offsets is pinned by a byte signature below, so a build
// with a different layout fails closed instead of reading the wrong field.

#include <windows.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "exact_lookup_signature.h"
#include "../lookup_line_text_match.h"

namespace fushi_voice_hook::artemis_lookup {

namespace exact = fushi_voice_hook::exact_lookup;

// ── engine layout (pinned by the signatures) ────────────────────────────────

inline constexpr size_t kInputScaleOffset = 0x0cu;
inline constexpr size_t kInputOffsetXOffset = 0x10u;
inline constexpr size_t kInputOffsetYOffset = 0x14u;
inline constexpr size_t kInputKeyStateOffset = 0x18u;
inline constexpr size_t kInputWindowOffset = 0x3158u;
inline constexpr uint32_t kKeyStateIdle = 0u;
inline constexpr uint32_t kKeyStatePressed = 1u;
inline constexpr uint32_t kKeyStateHeld = 2u;
inline constexpr uint32_t kKeyStateRepeat = 3u;
inline constexpr uint32_t kKeyStateReleased = 4u;
inline constexpr size_t kLeftButtonKey = 1u;  // VK_LBUTTON, engine logical

inline constexpr size_t kGlyphMatrixVptrOffset = 0x48u;
inline constexpr size_t kGlyphWorldMatrixOffset = 0x50u;
inline constexpr size_t kGlyphParentMatrixVptrOffset = 0x68u;
inline constexpr size_t kGlyphCellOffset = 0x88u;
inline constexpr size_t kGlyphDrawSlot = 4u;
inline constexpr size_t kGlyphDrawSiblingSlot = 3u;

inline constexpr size_t kMaxFrameGlyphs = 512u;

// ── signatures ──────────────────────────────────────────────────────────────

// Layer::CreateGlyph: new(0x108) then the glyph constructor.
inline constexpr uint8_t kGlyphFactoryBytes[] = {
    0x40, 0x57, 0x48, 0x83, 0xec, 0x40, 0x48, 0xc7, 0x44, 0x24, 0x30, 0xfe,
    0xff, 0xff, 0xff, 0x48, 0x89, 0x5c, 0x24, 0x50, 0x48, 0x89, 0x74, 0x24,
    0x58, 0x49, 0x8b, 0xd8, 0x48, 0x8b, 0xfa, 0x48, 0x8b, 0xf1, 0xb9, 0x08,
    0x01, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x48, 0x89, 0x44, 0x24,
    0x68, 0x4c, 0x8b, 0xcb, 0x4c, 0x8b, 0xc7, 0x48, 0x8b, 0xd6, 0x48, 0x8b,
    0xc8, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x90};
inline constexpr auto kGlyphFactoryMask =
    exact::MaskExceptRanges<sizeof(kGlyphFactoryBytes)>(40u, 44u, 62u, 66u);
inline constexpr size_t kGlyphFactoryCtorCallOffset = 61u;

// Inside the constructor (searched in its first kCtorScanBytes bytes):
// `call base_ctor; nop; lea rax,[rip+vtable]; mov [r11],rax`.
inline constexpr uint8_t kCtorVtableBytes[] = {
    0xe8, 0x00, 0x00, 0x00, 0x00, 0x90, 0x48, 0x8d,
    0x05, 0x00, 0x00, 0x00, 0x00, 0x49, 0x89, 0x03};
inline constexpr auto kCtorVtableMask =
    exact::MaskExceptRanges<sizeof(kCtorVtableBytes)>(1u, 5u, 9u, 13u);
inline constexpr size_t kCtorVtableLeaOffset = 6u;
// `mov [r11+0x88],r12; mov [r11+0x90],r12`: the cell width/height slot.
inline constexpr uint8_t kCtorCellBytes[] = {0x4d, 0x89, 0xa3, 0x88, 0x00,
                                             0x00, 0x00, 0x4d, 0x89, 0xa3,
                                             0x90, 0x00, 0x00, 0x00};
// `xor eax,0x20; sub eax,0xa1`: the Shift_JIS lead-byte width test of the
// one-character argument.
inline constexpr uint8_t kCtorMultibyteBytes[] = {0x83, 0xf0, 0x20, 0x2d,
                                                  0xa1, 0x00, 0x00, 0x00};
inline constexpr size_t kCtorScanBytes = 0x200u;

// Glyph vtable slot 4: forwards the per-frame pass (vtable +0x18) to the
// glyph's effect list (+0xb8..+0xc0) and sprite list (+0xa0..+0xa8).  Slot 3
// is the byte-identical sibling forwarding vtable +0x10.
inline constexpr uint8_t kGlyphDrawBytes[] = {
    0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48,
    0x83, 0xec, 0x30, 0x48, 0x8b, 0x99, 0xb8, 0x00, 0x00, 0x00, 0x48, 0x8b,
    0xf2, 0x48, 0x8b, 0xf9, 0x0f, 0x29, 0x74, 0x24, 0x20, 0x0f, 0x28, 0xf2,
    0x48, 0x3b, 0x99, 0xc0, 0x00, 0x00, 0x00, 0x74, 0x2e, 0x0f, 0x1f, 0x00,
    0x4c, 0x8b, 0x0b, 0x0f, 0x28, 0xd6, 0x48, 0x8b, 0xd6, 0x49, 0x8b, 0x41,
    0x08, 0x49, 0x8d, 0x49, 0x08, 0x4c, 0x63, 0x40, 0x04, 0x49, 0x03, 0xc8,
    0x48, 0x8b, 0x01, 0xff, 0x50, 0x18};
inline constexpr size_t kGlyphDrawForwardSlotByte = sizeof(kGlyphDrawBytes) - 1u;

// Input::Update prologue: key-state array at +0x18, 256-key loop.
inline constexpr uint8_t kInputUpdateBytes[] = {
    0x48, 0x89, 0x5c, 0x24, 0x10, 0x48, 0x89, 0x6c, 0x24, 0x18, 0x56, 0x57,
    0x41, 0x54, 0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xec, 0x90, 0x00, 0x00,
    0x00, 0x48, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00, 0x48, 0x33, 0xc4, 0x48,
    0x89, 0x84, 0x24, 0x80, 0x00, 0x00, 0x00, 0x8b, 0x99, 0x48, 0x31, 0x00,
    0x00, 0x4c, 0x8d, 0xb1, 0x38, 0x08, 0x00, 0x00, 0x48, 0x8d, 0x71, 0x18,
    0x89, 0x54, 0x24, 0x28, 0x4d, 0x8b, 0xc6, 0x4c, 0x8b, 0xd6, 0x44, 0x8b,
    0xfa, 0x48, 0x8b, 0xf9, 0x41, 0xbb, 0x00, 0x01, 0x00, 0x00};
inline constexpr auto kInputUpdateMask =
    exact::MaskExceptRanges<sizeof(kInputUpdateBytes)>(28u, 32u);

// The engine's own client->design cursor mapping: hwnd at +0x3158,
// k at +0x0c, offsets at +0x10/+0x14.
inline constexpr uint8_t kCursorMappingBytes[] = {
    0x48, 0x8b, 0x8b, 0x58, 0x31, 0x00, 0x00, 0x48, 0x8d, 0x54, 0x24, 0x30,
    0xff, 0x15, 0x00, 0x00, 0x00, 0x00, 0x48, 0x8b, 0x07, 0x48, 0x8b, 0xcf,
    0x8b, 0x54, 0x24, 0x30, 0xff, 0x50, 0x18, 0x48, 0x8b, 0x07, 0x48, 0x8b,
    0xcf, 0x8b, 0x54, 0x24, 0x34, 0xff, 0x50, 0x20, 0x66, 0x0f, 0x6e, 0x4c,
    0x24, 0x30, 0x48, 0x8b, 0xce, 0x48, 0x8b, 0x06, 0x0f, 0x5b, 0xc9, 0xf3,
    0x0f, 0x5c, 0x4b, 0x10, 0xf3, 0x0f, 0x59, 0x4b, 0x0c, 0xff, 0x50, 0x18,
    0x66, 0x0f, 0x6e, 0x4c, 0x24, 0x34, 0x0f, 0x5b, 0xc9, 0xf3, 0x0f, 0x5c,
    0x4b, 0x14, 0xf3, 0x0f, 0x59, 0x4b, 0x0c};
inline constexpr auto kCursorMappingMask =
    exact::MaskExceptRanges<sizeof(kCursorMappingBytes)>(14u, 18u);

struct Sites {
  uintptr_t glyph_factory = 0u;
  uintptr_t glyph_ctor = 0u;
  uintptr_t glyph_vtable = 0u;
  uintptr_t glyph_draw = 0u;
  uintptr_t input_update = 0u;
};

enum class SiteResult : uint32_t {
  kResolved = 0u,
  kNotX64 = 1u,
  kFactoryMissing = 2u,
  kCtorInvalid = 3u,
  kVtableInvalid = 4u,
  kDrawInvalid = 5u,
  kUpdateMissing = 6u,
  kCursorMappingMissing = 7u,
};

// A pattern that must occur exactly once inside [begin, begin + bytes).
inline const uint8_t* FindUniqueInRange(const uint8_t* begin, size_t bytes,
                                        const exact::MaskedPattern& pattern) {
  if (begin == nullptr || !exact::IsReadableSpan(begin, bytes)) return nullptr;
  const auto match = exact::FindUniqueMaskedPattern(begin, bytes, pattern);
  return match.count == 1u ? match.address : nullptr;
}

inline bool IsExecutableImageAddress(const exact::LoadedPeImage& image,
                                     uintptr_t address, size_t bytes) {
  uintptr_t rva = 0u;
  return exact::AddressToRva(image, address, &rva) &&
         exact::SectionHasRole(exact::FindSectionForRva(image, rva, bytes),
                               IMAGE_SCN_MEM_EXECUTE);
}

inline bool IsReadOnlyDataImageAddress(const exact::LoadedPeImage& image,
                                       uintptr_t address, size_t bytes) {
  uintptr_t rva = 0u;
  return exact::AddressToRva(image, address, &rva) &&
         exact::SectionHasRole(exact::FindSectionForRva(image, rva, bytes),
                               IMAGE_SCN_MEM_READ,
                               IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_WRITE);
}

inline bool MatchesGlyphForwarder(const exact::LoadedPeImage& image,
                                  uintptr_t function, uint8_t forward_slot) {
  if (!IsExecutableImageAddress(image, function, sizeof(kGlyphDrawBytes)) ||
      !exact::IsReadableSpan(reinterpret_cast<const void*>(function),
                             sizeof(kGlyphDrawBytes))) {
    return false;
  }
  const auto* bytes = reinterpret_cast<const uint8_t*>(function);
  return std::memcmp(bytes, kGlyphDrawBytes, kGlyphDrawForwardSlotByte) == 0 &&
         bytes[kGlyphDrawForwardSlotByte] == forward_slot;
}

// Resolves every hook site from structure alone.  No RVA, hash, file name or
// title is consulted; any missing or ambiguous proof returns a failure and
// leaves `sites` zeroed.
inline SiteResult ResolveSites(const exact::LoadedPeImage& image,
                               Sites* sites) {
  if (sites == nullptr) return SiteResult::kFactoryMissing;
  *sites = {};
  if (image.machine != IMAGE_FILE_MACHINE_AMD64 || image.pointer_bits != 64u) {
    return SiteResult::kNotX64;
  }
  const exact::MaskedPattern factory_pattern = {
      kGlyphFactoryBytes, kGlyphFactoryMask.data(), sizeof(kGlyphFactoryBytes)};
  const auto factory =
      exact::FindUniquePatternInExecutableSections(image, factory_pattern);
  if (factory.count != 1u) return SiteResult::kFactoryMissing;

  uintptr_t ctor = 0u;
  if (!exact::DecodeRel32CallTarget(
          factory.address + kGlyphFactoryCtorCallOffset, &ctor) ||
      !IsExecutableImageAddress(image, ctor, kCtorScanBytes)) {
    return SiteResult::kCtorInvalid;
  }
  const auto* ctor_bytes = reinterpret_cast<const uint8_t*>(ctor);
  const exact::MaskedPattern vtable_pattern = {
      kCtorVtableBytes, kCtorVtableMask.data(), sizeof(kCtorVtableBytes)};
  const exact::MaskedPattern cell_pattern = {kCtorCellBytes, nullptr,
                                             sizeof(kCtorCellBytes)};
  const exact::MaskedPattern multibyte_pattern = {
      kCtorMultibyteBytes, nullptr, sizeof(kCtorMultibyteBytes)};
  const uint8_t* vtable_site =
      FindUniqueInRange(ctor_bytes, kCtorScanBytes, vtable_pattern);
  if (vtable_site == nullptr ||
      FindUniqueInRange(ctor_bytes, kCtorScanBytes, cell_pattern) == nullptr ||
      FindUniqueInRange(ctor_bytes, kCtorScanBytes, multibyte_pattern) ==
          nullptr) {
    return SiteResult::kCtorInvalid;
  }
  uintptr_t vtable = 0u;
  if (!exact::DecodeRipRelativeAddress(vtable_site + kCtorVtableLeaOffset, 3u,
                                       7u, &vtable) ||
      !IsReadOnlyDataImageAddress(image, vtable,
                                  (kGlyphDrawSlot + 1u) * sizeof(uintptr_t)) ||
      !exact::IsReadableSpan(reinterpret_cast<const void*>(vtable),
                             (kGlyphDrawSlot + 1u) * sizeof(uintptr_t))) {
    return SiteResult::kVtableInvalid;
  }
  uintptr_t draw = 0u;
  uintptr_t sibling = 0u;
  std::memcpy(&draw,
              reinterpret_cast<const void*>(vtable +
                                            kGlyphDrawSlot * sizeof(uintptr_t)),
              sizeof(draw));
  std::memcpy(&sibling,
              reinterpret_cast<const void*>(
                  vtable + kGlyphDrawSiblingSlot * sizeof(uintptr_t)),
              sizeof(sibling));
  if (!MatchesGlyphForwarder(image, draw, 0x18u) ||
      !MatchesGlyphForwarder(image, sibling, 0x10u)) {
    return SiteResult::kDrawInvalid;
  }

  const exact::MaskedPattern update_pattern = {
      kInputUpdateBytes, kInputUpdateMask.data(), sizeof(kInputUpdateBytes)};
  const auto update =
      exact::FindUniquePatternInExecutableSections(image, update_pattern);
  if (update.count != 1u) return SiteResult::kUpdateMissing;
  const exact::MaskedPattern cursor_pattern = {
      kCursorMappingBytes, kCursorMappingMask.data(),
      sizeof(kCursorMappingBytes)};
  if (exact::FindUniquePatternInExecutableSections(image, cursor_pattern)
          .count != 1u) {
    return SiteResult::kCursorMappingMissing;
  }

  sites->glyph_factory = reinterpret_cast<uintptr_t>(factory.address);
  sites->glyph_ctor = ctor;
  sites->glyph_vtable = vtable;
  sites->glyph_draw = draw;
  sites->input_update = reinterpret_cast<uintptr_t>(update.address);
  return SiteResult::kResolved;
}

// ── one-character factory argument ──────────────────────────────────────────

// The factory is handed exactly one character, NUL terminated.  Artemis
// titles store scripts as UTF-8 or Shift_JIS; the two single-character forms
// cannot collide (a lone Shift_JIS character is never a complete UTF-8
// scalar), so the strict UTF-8 decode is tried first.  Anything else yields 0
// ("unknown"), which keeps that glyph out of every text match.
inline uint32_t DecodeSingleUtf8Scalar(const uint8_t* bytes, size_t length) {
  if (bytes == nullptr || length == 0u || length > 4u) return 0u;
  const uint8_t first = bytes[0];
  uint32_t scalar = 0u;
  size_t units = 0u;
  if (first < 0x80u) {
    scalar = first;
    units = 1u;
  } else if (first >= 0xc2u && first <= 0xdfu) {
    scalar = first & 0x1fu;
    units = 2u;
  } else if (first >= 0xe0u && first <= 0xefu) {
    scalar = first & 0x0fu;
    units = 3u;
  } else if (first >= 0xf0u && first <= 0xf4u) {
    scalar = first & 0x07u;
    units = 4u;
  } else {
    return 0u;
  }
  if (units != length) return 0u;
  for (size_t index = 1u; index < units; ++index) {
    if ((bytes[index] & 0xc0u) != 0x80u) return 0u;
    scalar = (scalar << 6u) | (bytes[index] & 0x3fu);
  }
  const bool overlong = (units == 3u && scalar < 0x800u) ||
                        (units == 4u && scalar < 0x10000u);
  if (overlong || scalar > 0x10ffffu ||
      (scalar >= 0xd800u && scalar <= 0xdfffu) || scalar == 0u) {
    return 0u;
  }
  return scalar;
}

inline uint32_t DecodeSingleCp932Character(const uint8_t* bytes,
                                           size_t length) {
  if (bytes == nullptr || length == 0u || length > 2u) return 0u;
  wchar_t decoded[2] = {};
  const int count = MultiByteToWideChar(
      932, MB_ERR_INVALID_CHARS, reinterpret_cast<const char*>(bytes),
      static_cast<int>(length), decoded, 2);
  if (count != 1 || decoded[0] == 0 || decoded[0] == 0xfffd ||
      (decoded[0] >= 0xd800 && decoded[0] <= 0xdfff)) {
    return 0u;
  }
  return decoded[0];
}

// `bytes` must point at readable memory; at most 5 bytes are inspected.
inline uint32_t DecodeFactoryCharacter(const uint8_t* bytes) {
  if (bytes == nullptr) return 0u;
  size_t length = 0u;
  while (length < 5u && bytes[length] != 0u) ++length;
  if (length == 0u || length == 5u) return 0u;
  const uint32_t utf8 = DecodeSingleUtf8Scalar(bytes, length);
  const uint32_t decoded =
      utf8 != 0u ? utf8 : DecodeSingleCp932Character(bytes, length);
  // A C0/C1 control is never a drawn glyph (CP932 maps a stray 0x80 to
  // U+0080); keep it unknown rather than let it match selected text.
  if (decoded < 0x20u || (decoded >= 0x7fu && decoded <= 0x9fu)) return 0u;
  return decoded;
}

// ── glyph -> character table (game thread only) ────────────────────────────

struct GlyphCode {
  uintptr_t glyph = 0u;
  uint64_t seq = 0u;
  uint32_t codepoint = 0u;
};

// Glyph objects are freed without notification, so the table is keyed by the
// object address and every factory call overwrites the entry of a reused
// address.  A bucket holds `Probe` entries; when all are taken the oldest
// creation is evicted, which can only drop glyphs far older than the current
// message.  A dropped entry reads as "unknown" and fails the text match closed.
template <size_t Capacity = 8192u, size_t Probe = 8u>
class GlyphCodeTable {
  static_assert((Capacity & (Capacity - 1u)) == 0u, "power of two");

 public:
  void Clear() { entries_.fill(GlyphCode{}); }

  void Remember(uintptr_t glyph, uint32_t codepoint, uint64_t seq) {
    if (glyph == 0u || seq == 0u) return;
    const size_t home = Home(glyph);
    size_t victim = home;
    for (size_t probe = 0u; probe < Probe; ++probe) {
      GlyphCode& entry = entries_[(home + probe) & (Capacity - 1u)];
      if (entry.glyph == glyph || entry.glyph == 0u) {
        entry = {glyph, seq, codepoint};
        return;
      }
      if (entry.seq < entries_[victim].seq) {
        victim = (home + probe) & (Capacity - 1u);
      }
    }
    entries_[victim] = {glyph, seq, codepoint};
  }

  bool Find(uintptr_t glyph, GlyphCode* out) const {
    if (glyph == 0u || out == nullptr) return false;
    const size_t home = Home(glyph);
    for (size_t probe = 0u; probe < Probe; ++probe) {
      const GlyphCode& entry = entries_[(home + probe) & (Capacity - 1u)];
      if (entry.glyph == glyph) {
        *out = entry;
        return entry.codepoint != 0u;
      }
    }
    return false;
  }

 private:
  static size_t Home(uintptr_t glyph) {
    const uint64_t mixed =
        (static_cast<uint64_t>(glyph) >> 4u) * 0x9e3779b97f4a7c15ull;
    return static_cast<size_t>(mixed >> 40u) & (Capacity - 1u);
  }

  std::array<GlyphCode, Capacity> entries_{};
};

// ── per-frame geometry ─────────────────────────────────────────────────────

struct CellBounds {
  float left = 0.0f;
  float top = 0.0f;
  float right = 0.0f;
  float bottom = 0.0f;
};

struct FrameGlyph {
  uint64_t seq = 0u;
  uint32_t codepoint = 0u;
  float matrix[6] = {};  // world {a, b, tx, c, d, ty} at draw time
  CellBounds bounds;
};

inline bool IsFiniteFloat(float value) { return std::isfinite(value) != 0; }

// World bounds of the glyph cell (0,0)-(w,h) under {a, b, tx, c, d, ty}.
inline bool ComputeCellBounds(const float matrix[6], float width, float height,
                              CellBounds* out) {
  if (matrix == nullptr || out == nullptr) return false;
  for (int index = 0; index < 6; ++index) {
    if (!IsFiniteFloat(matrix[index])) return false;
  }
  if (!IsFiniteFloat(width) || !IsFiniteFloat(height) || width <= 0.0f ||
      height <= 0.0f || width > 4096.0f || height > 4096.0f) {
    return false;
  }
  const float a = matrix[0], b = matrix[1], tx = matrix[2];
  const float c = matrix[3], d = matrix[4], ty = matrix[5];
  if (std::fabs(a * d - b * c) < 1e-6f) return false;
  const float xs[4] = {0.0f, width, 0.0f, width};
  const float ys[4] = {0.0f, 0.0f, height, height};
  CellBounds bounds = {INFINITY, INFINITY, -INFINITY, -INFINITY};
  for (int corner = 0; corner < 4; ++corner) {
    const float x = a * xs[corner] + b * ys[corner] + tx;
    const float y = c * xs[corner] + d * ys[corner] + ty;
    bounds.left = (std::min)(bounds.left, x);
    bounds.top = (std::min)(bounds.top, y);
    bounds.right = (std::max)(bounds.right, x);
    bounds.bottom = (std::max)(bounds.bottom, y);
  }
  if (!IsFiniteFloat(bounds.left) || !IsFiniteFloat(bounds.right) ||
      !IsFiniteFloat(bounds.top) || !IsFiniteFloat(bounds.bottom)) {
    return false;
  }
  *out = bounds;
  return true;
}

struct EngineProjection {
  float design_per_client = 0.0f;  // input+0x0c
  float offset_x = 0.0f;           // input+0x10, engine client pixels
  float offset_y = 0.0f;           // input+0x14
  int32_t engine_client_w = 0;     // GetClientRect on the game thread
  int32_t engine_client_h = 0;
};

struct PixelRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

inline bool ProjectionUsable(const EngineProjection& projection) {
  return IsFiniteFloat(projection.design_per_client) &&
         projection.design_per_client > 0.01f &&
         projection.design_per_client < 100.0f &&
         IsFiniteFloat(projection.offset_x) &&
         IsFiniteFloat(projection.offset_y) &&
         projection.engine_client_w > 0 && projection.engine_client_h > 0;
}

// A glyph's world matrix already contains the engine's root letterbox
// transform (design -> engine client pixels = scale 1/k, offset off; measured:
// at 960x600 the first glyph of a line laid out at design (340,552) carries
// world (255,444) with a = d = 0.75).  So world units ARE engine client
// pixels.  The proof, per glyph, is that its world scale equals the root
// scale 1/k with no rotation/shear: a renderer that drew into a design-sized
// backbuffer (world == design, a == 1 while k != 1) or a glyph under a
// scale/rotate effect fails it and is left unclickable rather than projected
// to the wrong place.
inline bool GlyphInEngineClientSpace(const float matrix[6],
                                     float design_per_client) {
  if (matrix == nullptr || !IsFiniteFloat(design_per_client) ||
      design_per_client <= 0.0f) {
    return false;
  }
  constexpr float kTolerance = 5e-3f;
  const float a = matrix[0] * design_per_client;
  const float d = matrix[4] * design_per_client;
  return std::fabs(a - 1.0f) <= kTolerance &&
         std::fabs(d - 1.0f) <= kTolerance &&
         std::fabs(matrix[1]) <= kTolerance &&
         std::fabs(matrix[3]) <= kTolerance;
}

// Engine client pixels -> physical client pixels (the engine's DPI
// virtualization, if any, scales the whole client uniformly per axis).
// Rounds outward; the result must lie in the physical client area.
inline bool ProjectCell(const CellBounds& bounds,
                        const EngineProjection& projection, int32_t physical_w,
                        int32_t physical_h, PixelRect* out) {
  if (out == nullptr || !ProjectionUsable(projection) || physical_w <= 0 ||
      physical_h <= 0) {
    return false;
  }
  const double sx = static_cast<double>(physical_w) /
                    static_cast<double>(projection.engine_client_w);
  const double sy = static_cast<double>(physical_h) /
                    static_cast<double>(projection.engine_client_h);
  const double left = bounds.left * sx;
  const double right = bounds.right * sx;
  const double top = bounds.top * sy;
  const double bottom = bounds.bottom * sy;
  // World scales are floats (1/k = 0.75 for k = 1.3333334), so exact cell
  // edges land a few 1e-5 px off the integer grid; absorb that before
  // rounding out.
  constexpr double kGridSlack = 1e-3;
  const double x0 = std::floor(left + kGridSlack);
  const double y0 = std::floor(top + kGridSlack);
  const double x1 = std::ceil(right - kGridSlack);
  const double y1 = std::ceil(bottom - kGridSlack);
  if (x0 < 0.0 || y0 < 0.0 || x1 > physical_w || y1 > physical_h ||
      x1 - x0 < 1.0 || y1 - y0 < 1.0) {
    return false;
  }
  *out = {static_cast<int32_t>(x0), static_cast<int32_t>(y0),
          static_cast<int32_t>(x1 - x0), static_cast<int32_t>(y1 - y0)};
  return true;
}

// Orders one frame's drawn glyphs by creation, drops duplicates (a glyph drawn
// twice in one frame) and glyphs whose character is unknown.  Returns the new
// count.
inline size_t OrderFrameGlyphs(FrameGlyph* glyphs, size_t count) {
  if (glyphs == nullptr) return 0u;
  std::sort(glyphs, glyphs + count,
            [](const FrameGlyph& left, const FrameGlyph& right) {
              return left.seq < right.seq;
            });
  size_t kept = 0u;
  for (size_t index = 0u; index < count; ++index) {
    if (glyphs[index].codepoint == 0u || glyphs[index].seq == 0u) continue;
    if (kept != 0u && glyphs[kept - 1u].seq == glyphs[index].seq) continue;
    glyphs[kept++] = glyphs[index];
  }
  return kept;
}

// ── selected text -> glyph mapping ─────────────────────────────────────────

inline constexpr uint16_t kNoSource = 0xffffu;

struct TextMapping {
  size_t first_glyph = 0u;  // glyphs before it are older, unrelated text
  std::array<uint16_t, kMaxFrameGlyphs> source_index{};
  std::array<uint8_t, kMaxFrameGlyphs> source_length{};
};

inline size_t Utf16Units(uint32_t codepoint, wchar_t units[2]) {
  if (codepoint == 0u || codepoint > 0x10ffffu ||
      (codepoint >= 0xd800u && codepoint <= 0xdfffu)) {
    return 0u;
  }
  if (codepoint < 0x10000u) {
    units[0] = static_cast<wchar_t>(codepoint);
    return 1u;
  }
  const uint32_t value = codepoint - 0x10000u;
  units[0] = static_cast<wchar_t>(0xd800u + (value >> 10u));
  units[1] = static_cast<wchar_t>(0xdc00u + (value & 0x3ffu));
  return 2u;
}

// The selected LunaHook line is the concatenation of the most recently
// created glyphs (LunaHook hooks the same constructor, in creation order: the
// name plate first, then the dialogue).  Match it, whitespace-insensitively,
// against the creation-ordered suffix of the glyphs drawn this frame.  The
// whole selected line must be consumed; glyphs older than the match stay
// unmapped.  No prefix/substring fallback: a line that is not exactly the
// newest visible text is not claimed.
inline bool ResolveSelectedSuffix(const FrameGlyph* glyphs, size_t count,
                                  const wchar_t* selected,
                                  size_t selected_count, TextMapping* out) {
  if (glyphs == nullptr || out == nullptr || selected == nullptr ||
      count == 0u || count > kMaxFrameGlyphs || selected_count == 0u ||
      selected_count >= kNoSource) {
    return false;
  }
  TextMapping mapping;
  mapping.source_index.fill(kNoSource);
  size_t source = selected_count;  // exclusive end of the unmatched source
  size_t glyph = count;            // exclusive end of the unmatched glyphs
  bool any = false;
  for (;;) {
    while (source > 0u && IsLookupLineWhitespace(selected[source - 1u])) {
      --source;
    }
    if (source == 0u) break;
    if (glyph == 0u) return false;
    const FrameGlyph& candidate = glyphs[glyph - 1u];
    wchar_t units[2] = {};
    const size_t unit_count = Utf16Units(candidate.codepoint, units);
    if (unit_count == 0u) return false;
    if (unit_count == 1u && IsLookupLineWhitespace(units[0])) {
      --glyph;
      continue;
    }
    if (source < unit_count) return false;
    for (size_t unit = 0u; unit < unit_count; ++unit) {
      if (selected[source - unit_count + unit] != units[unit]) return false;
    }
    source -= unit_count;
    mapping.source_index[glyph - 1u] = static_cast<uint16_t>(source);
    mapping.source_length[glyph - 1u] = static_cast<uint8_t>(unit_count);
    any = true;
    --glyph;
  }
  if (!any) return false;
  mapping.first_glyph = glyph;
  *out = mapping;
  return true;
}

// ── game-thread click claim ────────────────────────────────────────────────

struct ClaimState {
  bool owned = false;
};

struct ClaimDecision {
  bool mask = false;    // write kKeyStateIdle over the engine's left button
  bool submit = false;  // queue the resolved glyph for the worker
};

// `state` is the engine's left-button state right after Input::Update.
// `eligible` is only consulted on a fresh press: the cursor is on a mapped
// glyph of the current model and the host admitted native input.  Once owned,
// every frame is masked until the engine no longer reports the button down;
// the final "released" edge is masked too, so the game sees neither edge.
inline ClaimDecision DecideLeftButton(uint32_t state, bool eligible,
                                      ClaimState* claim) {
  ClaimDecision decision;
  if (claim == nullptr) return decision;
  const bool down = state == kKeyStatePressed || state == kKeyStateHeld ||
                    state == kKeyStateRepeat;
  if (claim->owned) {
    decision.mask = true;
    if (!down) claim->owned = false;
    return decision;
  }
  if (state == kKeyStatePressed && eligible) {
    claim->owned = true;
    decision.mask = true;
    decision.submit = true;
  }
  return decision;
}

// ── model hit test (game thread) ───────────────────────────────────────────

struct ModelGlyph {
  PixelRect rect;  // physical client pixels
  uint16_t source_index = kNoSource;
  uint8_t source_length = 0u;
};

// Maps an engine-client cursor into physical pixels and returns the single
// glyph containing it; overlapping candidates are ambiguous and rejected.
inline bool HitTestModel(const ModelGlyph* glyphs, size_t count,
                         int32_t physical_w, int32_t physical_h,
                         int32_t engine_w, int32_t engine_h, int32_t engine_x,
                         int32_t engine_y, size_t* hit) {
  if (glyphs == nullptr || hit == nullptr || physical_w <= 0 ||
      physical_h <= 0 || engine_w <= 0 || engine_h <= 0) {
    return false;
  }
  const double x = (static_cast<double>(engine_x) + 0.5) * physical_w /
                   static_cast<double>(engine_w);
  const double y = (static_cast<double>(engine_y) + 0.5) * physical_h /
                   static_cast<double>(engine_h);
  size_t found = count;
  for (size_t index = 0u; index < count; ++index) {
    const ModelGlyph& glyph = glyphs[index];
    if (glyph.source_index == kNoSource) continue;
    if (x < glyph.rect.x || y < glyph.rect.y ||
        x >= static_cast<double>(glyph.rect.x) + glyph.rect.w ||
        y >= static_cast<double>(glyph.rect.y) + glyph.rect.h) {
      continue;
    }
    if (found != count) return false;
    found = index;
  }
  if (found == count) return false;
  *hit = found;
  return true;
}

}  // namespace fushi_voice_hook::artemis_lookup
