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
// A second build (アマカノ3 Amakano3.exe, Artemis x64, measured 2026-10-02 by
// static disassembly) keeps every offset above but recompiles the code around
// them: the factory has no EH frame and hands the constructor an extra stack
// argument, the constructor addresses the glyph through rdi instead of r11,
// and Input::Update takes no `now` and only drains the key queues.  The sites
// are therefore matched by instruction structure (operation, field offset,
// immediates) instead of fixed register encodings; every offset is still
// pinned, so a build with a different layout fails closed instead of reading
// the wrong field.

#include <windows.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

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

// Layer::CreateGlyph is a virtual factory: `mov ecx,0x108; call new`, then
// `mov rcx,rax; call ctor` within kFactoryCtorCallWindow bytes.  Builds differ
// in prologue (with or without an EH frame) and in an extra stack argument
// handed to the constructor, so only that skeleton is matched; the
// constructor proofs below decide which `new(0x108)` site is the glyph one.
inline constexpr uint8_t kGlyphAllocBytes[] = {0xb9, 0x08, 0x01, 0x00, 0x00,
                                               0xe8};
inline constexpr uint8_t kCallWithNewObjectBytes[] = {0x48, 0x8b, 0xc8, 0xe8};
inline constexpr size_t kFactoryCtorCallWindow = 0x30u;
// The factory entry precedes the allocation by at most this many bytes.
inline constexpr size_t kFactoryEntryWindow = 0x40u;

// Inside the constructor (searched in its first kCtorScanBytes bytes):
// `call base_ctor; nop; lea rax,[rip+vtable]; mov [this],rax` where `this`
// is any base register (r11 in one build, rdi in another).
inline constexpr size_t kCtorVtableLeaOffset = 6u;
inline constexpr size_t kCtorVtableStoreBytes = 16u;
// `mov [this+0x88],reg; mov [this+0x90],reg`: the cell width/height slot.
inline constexpr uint32_t kCtorCellFirstDisp = 0x88u;
inline constexpr uint32_t kCtorCellSecondDisp = 0x90u;
inline constexpr size_t kCtorCellStoreBytes = 14u;
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

// Input::Update: drains the per-key event queues (input+0x838, one 0x28-byte
// deque per key) into the key-state array (input+0x18) for all 256 keys and
// steps the pointer state at input+0x3148, then maps the cursor through the
// game HWND at input+0x3158.  Matched as `mov r32,0x100` (the key count) with
// `lea r,[rcx+0x838]` and `lea r,[rcx+0x18]` in the kUpdateEntryWindow bytes
// before it, the +0x3148 field next to it and the +0x3158 field later in the
// same body; builds differ in register allocation and frame layout.  The
// HWND access separates Update from a queue-flush helper that drains the same
// queues but never touches the cursor (both exist in アマカノ3).
inline constexpr uint32_t kInputKeyQueueOffset = 0x838u;
inline constexpr uint32_t kInputPointerStateOffset = 0x3148u;
inline constexpr uint32_t kInputKeyCount = 0x100u;
inline constexpr size_t kUpdateEntryWindow = 0x60u;
inline constexpr size_t kUpdatePointerStateWindow = 0x80u;
inline constexpr size_t kUpdateWindowFieldReach = 0x300u;

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

inline uint32_t ReadU32(const uint8_t* bytes) {
  uint32_t value = 0u;
  std::memcpy(&value, bytes, sizeof(value));
  return value;
}

// `rex.w 89 modrm` with mod=00, reg=rax and a plain base register (no SIB,
// no RIP): `mov [base],rax`.
inline bool IsStoreRaxToBase(const uint8_t* bytes) {
  const uint8_t modrm = bytes[2];
  return (bytes[0] == 0x48u || bytes[0] == 0x49u) && bytes[1] == 0x89u &&
         (modrm & 0xf8u) == 0x00u && (modrm & 0x07u) != 0x04u &&
         (modrm & 0x07u) != 0x05u;
}

// `call rel32; nop; lea rax,[rip+vtable]; mov [this],rax`.  Returns the lea.
inline const uint8_t* FindCtorVtableStore(const uint8_t* ctor) {
  const uint8_t* found = nullptr;
  for (size_t at = 0u; at + kCtorVtableStoreBytes <= kCtorScanBytes; ++at) {
    const uint8_t* p = ctor + at;
    if (p[0] != 0xe8u || p[5] != 0x90u || p[6] != 0x48u || p[7] != 0x8du ||
        p[8] != 0x05u || !IsStoreRaxToBase(p + 13u)) {
      continue;
    }
    if (found != nullptr) return nullptr;
    found = p + kCtorVtableLeaOffset;
  }
  return found;
}

// `rex.w 89 modrm disp32` with mod=10 and no SIB: `mov [base+disp32],reg`.
inline bool IsStoreRegToBaseDisp32(const uint8_t* bytes, uint32_t disp) {
  const uint8_t modrm = bytes[2];
  return (bytes[0] & 0xf8u) == 0x48u && bytes[1] == 0x89u &&
         (modrm & 0xc0u) == 0x80u && (modrm & 0x07u) != 0x04u &&
         ReadU32(bytes + 3u) == disp;
}

// The same register stored to [this+0x88] and [this+0x90] back to back.
inline bool HasUniqueCtorCellStore(const uint8_t* ctor) {
  size_t count = 0u;
  for (size_t at = 0u; at + kCtorCellStoreBytes <= kCtorScanBytes; ++at) {
    const uint8_t* p = ctor + at;
    if (IsStoreRegToBaseDisp32(p, kCtorCellFirstDisp) &&
        IsStoreRegToBaseDisp32(p + 7u, kCtorCellSecondDisp) &&
        p[7] == p[0] && p[9] == p[2]) {
      ++count;
    }
  }
  return count == 1u;
}

// Every glyph constructor proof; returns the glyph vtable's lea or nullptr.
inline const uint8_t* MatchGlyphCtor(const exact::LoadedPeImage& image,
                                     uintptr_t ctor) {
  if (!IsExecutableImageAddress(image, ctor, kCtorScanBytes) ||
      !exact::IsReadableSpan(reinterpret_cast<const void*>(ctor),
                             kCtorScanBytes)) {
    return nullptr;
  }
  const auto* bytes = reinterpret_cast<const uint8_t*>(ctor);
  const exact::MaskedPattern multibyte_pattern = {
      kCtorMultibyteBytes, nullptr, sizeof(kCtorMultibyteBytes)};
  if (!HasUniqueCtorCellStore(bytes) ||
      FindUniqueInRange(bytes, kCtorScanBytes, multibyte_pattern) == nullptr) {
    return nullptr;
  }
  return FindCtorVtableStore(bytes);
}

// MSVC starts functions 16-byte aligned or right after int3 padding.
inline bool IsFunctionBoundary(uintptr_t address) {
  if ((address & 0x0fu) == 0u) return true;
  const auto* previous = reinterpret_cast<const uint8_t*>(address - 1u);
  return exact::IsReadableSpan(previous, 1u) && *previous == 0xccu;
}

// The function entry owning `anchor`: the nearest address in
// [anchor - window, anchor] that the image itself references as a function
// (a pointer stored in read-only data, i.e. a vtable slot, or a direct rel32
// call target).  No int3 padding run may separate it from the anchor.
inline uintptr_t FindReferencedEntryBefore(const exact::LoadedPeImage& image,
                                           uintptr_t anchor, size_t window) {
  const uintptr_t base = reinterpret_cast<uintptr_t>(image.base);
  if (anchor < base + window) return 0u;
  const uintptr_t low = anchor - window;
  uintptr_t best = 0u;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (section.bytes == nullptr || section.size == 0u ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      continue;
    }
    if (exact::SectionHasRole(&section, IMAGE_SCN_MEM_READ,
                              IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_WRITE)) {
      for (size_t at = 0u; at + sizeof(uintptr_t) <= section.size;
           at += sizeof(uintptr_t)) {
        uintptr_t target = 0u;
        std::memcpy(&target, section.bytes + at, sizeof(target));
        if (target >= low && target <= anchor && target > best &&
            IsFunctionBoundary(target)) {
          best = target;
        }
      }
    } else if (exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE)) {
      for (size_t at = 0u; at + 5u <= section.size; ++at) {
        if (section.bytes[at] != 0xe8u) continue;
        // The section span is already proven readable; decode in place.
        int32_t displacement = 0;
        std::memcpy(&displacement, section.bytes + at + 1u,
                    sizeof(displacement));
        const uintptr_t target =
            reinterpret_cast<uintptr_t>(section.bytes + at + 5u) +
            static_cast<intptr_t>(displacement);
        if (target >= low && target <= anchor && target > best &&
            IsFunctionBoundary(target)) {
          best = target;
        }
      }
    }
  }
  if (best == 0u) return 0u;
  const auto* bytes = reinterpret_cast<const uint8_t*>(best);
  for (uintptr_t at = best; at + 1u < anchor; ++at) {
    if (bytes[at - best] == 0xccu && bytes[at - best + 1u] == 0xccu) return 0u;
  }
  return best;
}

// One glyph factory candidate per `new(0x108)` whose object goes straight
// into a constructor that passes every glyph proof.
struct FactoryCandidate {
  uintptr_t entry = 0u;
  uintptr_t ctor = 0u;
  const uint8_t* vtable_lea = nullptr;
};

inline bool MatchFactoryAt(const exact::LoadedPeImage& image,
                           const uint8_t* alloc, bool* saw_shape,
                           FactoryCandidate* out) {
  const uint8_t* tail = alloc + sizeof(kGlyphAllocBytes) + 4u;
  if (!exact::IsReadableSpan(tail, kFactoryCtorCallWindow)) return false;
  const exact::MaskedPattern call_pattern = {
      kCallWithNewObjectBytes, nullptr, sizeof(kCallWithNewObjectBytes)};
  const auto call =
      exact::FindUniqueMaskedPattern(tail, kFactoryCtorCallWindow, call_pattern);
  if (call.count == 0u) return false;
  // From here on the skeleton is a factory: a failure is a constructor that
  // does not prove the glyph layout.
  uintptr_t ctor = 0u;
  const uint8_t* lea = nullptr;
  if (call.count != 1u ||
      !exact::DecodeRel32CallTarget(call.address + 3u, &ctor) ||
      (lea = MatchGlyphCtor(image, ctor)) == nullptr) {
    *saw_shape = true;
    return false;
  }
  const uintptr_t entry = FindReferencedEntryBefore(
      image, reinterpret_cast<uintptr_t>(alloc), kFactoryEntryWindow);
  if (entry == 0u) return false;
  *out = {entry, ctor, lea};
  return true;
}

enum class FactoryScan : uint32_t { kNone, kShapeOnly, kUnique, kAmbiguous };

inline FactoryScan FindGlyphFactory(const exact::LoadedPeImage& image,
                                    FactoryCandidate* out) {
  bool saw_shape = false;
  size_t count = 0u;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (!exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE)) continue;
    if (section.bytes == nullptr || section.size == 0u ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      return FactoryScan::kAmbiguous;
    }
    const size_t need = sizeof(kGlyphAllocBytes) + 4u + kFactoryCtorCallWindow;
    for (size_t at = 0u; at + need <= section.size; ++at) {
      const uint8_t* alloc = section.bytes + at;
      if (std::memcmp(alloc, kGlyphAllocBytes, sizeof(kGlyphAllocBytes)) != 0) {
        continue;
      }
      FactoryCandidate candidate;
      if (!MatchFactoryAt(image, alloc, &saw_shape, &candidate)) continue;
      if (++count > 1u) return FactoryScan::kAmbiguous;
      *out = candidate;
    }
  }
  if (count == 1u) return FactoryScan::kUnique;
  return saw_shape ? FactoryScan::kShapeOnly : FactoryScan::kNone;
}

// `[rex] b8+r imm32` with imm32 == 256: the key-count loop bound.  Returns
// its length (5 or 6) or 0.
inline size_t MatchKeyCountMov(const uint8_t* bytes) {
  const size_t prefix = bytes[0] == 0x41u ? 1u : 0u;
  if (bytes[prefix] < 0xb8u || bytes[prefix] > 0xbfu ||
      ReadU32(bytes + prefix + 1u) != kInputKeyCount) {
    return 0u;
  }
  return prefix + 5u;
}

// `rex.w 8d modrm` with rm=rcx: `lea r,[rcx+disp]` (disp8 or disp32).
inline bool HasLeaFromRcx(const uint8_t* bytes, size_t length, uint32_t disp) {
  for (size_t at = 0u; at + 4u <= length; ++at) {
    const uint8_t* p = bytes + at;
    if ((p[0] != 0x48u && p[0] != 0x4cu) || p[1] != 0x8du ||
        (p[2] & 0x07u) != 0x01u) {
      continue;
    }
    const uint8_t mod = p[2] & 0xc0u;
    if (mod == 0x40u && disp < 0x80u && p[3] == disp) return true;
    if (mod == 0x80u && at + 7u <= length && ReadU32(p + 3u) == disp) {
      return true;
    }
  }
  return false;
}

inline bool HasDisp32(const uint8_t* bytes, size_t length, uint32_t disp) {
  for (size_t at = 0u; at + 4u <= length; ++at) {
    if (ReadU32(bytes + at) == disp) return true;
  }
  return false;
}

// `disp` used as a field offset before the body's first int3 padding run.
inline bool HasFieldBeforePadding(const uint8_t* bytes, size_t length,
                                  uint32_t disp) {
  for (size_t at = 0u; at + 4u <= length; ++at) {
    if (bytes[at] == 0xccu && bytes[at + 1u] == 0xccu) return false;
    if (ReadU32(bytes + at) == disp) return true;
  }
  return false;
}

// Exactly one function drains the 256 key queues into the key-state array
// and then maps the cursor through the game window.
inline uintptr_t FindInputUpdate(const exact::LoadedPeImage& image) {
  uintptr_t found = 0u;
  for (size_t index = 0u; index < image.section_count; ++index) {
    const auto& section = image.sections[index];
    if (!exact::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE)) continue;
    if (section.bytes == nullptr || section.size == 0u ||
        !exact::IsReadableSpan(section.bytes, section.size)) {
      return 0u;
    }
    for (size_t at = kUpdateEntryWindow;
         at + 6u + kUpdateWindowFieldReach <= section.size; ++at) {
      const uint8_t* mov = section.bytes + at;
      // A REX.B mov is seen once, at its prefix.
      if (MatchKeyCountMov(mov) == 0u || (mov[-1] == 0x41u && mov[0] != 0x41u)) {
        continue;
      }
      const uint8_t* before = mov - kUpdateEntryWindow;
      if (!HasLeaFromRcx(before, kUpdateEntryWindow, kInputKeyQueueOffset) ||
          !HasLeaFromRcx(before, kUpdateEntryWindow,
                         static_cast<uint32_t>(kInputKeyStateOffset)) ||
          !HasDisp32(before, kUpdateEntryWindow + kUpdatePointerStateWindow,
                     kInputPointerStateOffset) ||
          !HasFieldBeforePadding(mov, kUpdateWindowFieldReach,
                                 static_cast<uint32_t>(kInputWindowOffset))) {
        continue;
      }
      const uintptr_t entry = FindReferencedEntryBefore(
          image, reinterpret_cast<uintptr_t>(mov), kUpdateEntryWindow);
      if (entry == 0u || (found != 0u && found != entry)) return 0u;
      found = entry;
    }
  }
  return found;
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
  FactoryCandidate factory;
  switch (FindGlyphFactory(image, &factory)) {
    case FactoryScan::kUnique:
      break;
    case FactoryScan::kShapeOnly:
      return SiteResult::kCtorInvalid;
    case FactoryScan::kNone:
    case FactoryScan::kAmbiguous:
      return SiteResult::kFactoryMissing;
  }
  uintptr_t vtable = 0u;
  if (!exact::DecodeRipRelativeAddress(factory.vtable_lea, 3u, 7u, &vtable) ||
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

  const uintptr_t update = FindInputUpdate(image);
  if (update == 0u) return SiteResult::kUpdateMissing;
  const exact::MaskedPattern cursor_pattern = {
      kCursorMappingBytes, kCursorMappingMask.data(),
      sizeof(kCursorMappingBytes)};
  if (exact::FindUniquePatternInExecutableSections(image, cursor_pattern)
          .count != 1u) {
    return SiteResult::kCursorMappingMissing;
  }

  sites->glyph_factory = factory.entry;
  sites->glyph_ctor = factory.ctor;
  sites->glyph_vtable = vtable;
  sites->glyph_draw = draw;
  sites->input_update = update;
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

// A factory call with an empty string (measured on the x64 build: the line
// break between the two rows of a wrapped line, one creation seq between
// them) or a lone C0 control byte creates a glyph that is never drawn.  It is
// recorded in the creation log as kCreatedControl, distinct from 0 (a
// character that failed to decode, which must never be skipped silently).
inline constexpr uint32_t kCreatedControl = 0x110000u;

inline uint32_t FactoryCreationCode(const uint8_t* bytes) {
  if (bytes == nullptr) return 0u;
  if (bytes[0] == 0u || (bytes[0] < 0x20u && bytes[1] == 0u)) {
    return kCreatedControl;
  }
  return DecodeFactoryCharacter(bytes);
}

// The codes of the most recent creations, indexed by creation seq (game
// thread writes under the codes lock; the worker copies it).  It answers one
// question: was everything created in a seq range invisible?
inline constexpr size_t kCreationLogSize = 1024u;

struct CreationLog {
  uint64_t newest = 0u;
  std::array<uint32_t, kCreationLogSize> codes{};
  std::array<uintptr_t, kCreationLogSize> layers{};  // factory `this`
  std::array<uint64_t, kCreationLogSize> frames{};   // game frame of creation

  void Record(uint64_t seq, uint32_t code, uintptr_t layer = 0u,
              uint64_t frame = 0u) {
    const size_t slot = seq & (kCreationLogSize - 1u);
    codes[slot] = code;
    layers[slot] = layer;
    frames[slot] = frame;
    newest = seq;
  }

  bool Known(uint64_t seq) const {
    return seq != 0u && seq <= newest && newest - seq < kCreationLogSize;
  }

  // 0 when `seq` is outside the window (unknown).
  uint32_t CodeAt(uint64_t seq) const {
    return Known(seq) ? codes[seq & (kCreationLogSize - 1u)] : 0u;
  }
  uintptr_t LayerAt(uint64_t seq) const {
    return Known(seq) ? layers[seq & (kCreationLogSize - 1u)] : 0u;
  }
  uint64_t FrameAt(uint64_t seq) const {
    return Known(seq) ? frames[seq & (kCreationLogSize - 1u)] : 0u;
  }
};

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

// ── engine text lane ───────────────────────────────────────────────────────

// True when two creations belong to one layout: the same layer, or the same
// game frame.  A line's name plate and body are separate layers laid out in
// one frame; a hover tooltip created later on its own layer is neither, even
// when its seqs follow the line's without a hole (measured on the x64 build:
// body 156..179 on one layer, the Config tooltip 180..192 on another, 2400
// frames later).  Unknown creations (0) compare equal only to each other.
inline bool SameLayout(const CreationLog& log, uint64_t left, uint64_t right) {
  return log.LayerAt(left) == log.LayerAt(right) ||
         log.FrameAt(left) == log.FrameAt(right);
}

// A revealed run on another layer, drawn while the last glyph of the line
// already published is still on screen, is UI laid over that line (a hover
// tooltip, a button caption), not the next line: an ADV message clears its
// text before the next one is laid out, and NVL text appends on the same
// layer.  `published_last_seq` 0 means nothing was published yet.
inline bool OverlaysPublishedLine(const FrameGlyph* glyphs, size_t count,
                                  uintptr_t run_layer,
                                  uint64_t published_last_seq,
                                  uintptr_t published_layer) {
  if (glyphs == nullptr || published_last_seq == 0u ||
      run_layer == published_layer) {
    return false;
  }
  for (size_t index = 0u; index < count; ++index) {
    if (glyphs[index].seq == published_last_seq) return true;
  }
  return false;
}

// True when every creation in [begin, end) is invisible: a line-break control
// or a whitespace character (neither is drawn).  An empty range is.
inline bool CreationsInvisible(const CreationLog& log, uint64_t begin,
                               uint64_t end) {
  if (begin > end || end - begin > kCreationLogSize) return false;
  for (uint64_t seq = begin; seq < end; ++seq) {
    const uint32_t code = log.CodeAt(seq);
    if (code == kCreatedControl) continue;
    wchar_t units[2] = {};
    if (Utf16Units(code, units) != 1u || !IsLookupLineWhitespace(units[0])) {
      return false;
    }
  }
  return true;
}

// Layer::CreateGlyph lays a whole line out in one burst, name plate first
// (measured on the x64 build: 「ミサ「さゆが…」」 is one run of consecutive
// creation seqs, 92 -> 179 between two lines), while older persistent text
// (UI labels, a still-visible earlier layer) carries much older seqs.  Glyphs
// that are created but never drawn — the line break of a wrapped line, a
// space — leave seq holes inside the burst, so the creation log decides
// whether a hole is part of the line.  The line on screen is the creation-
// ordered suffix of drawn glyphs joined across invisible holes only, between
// creations of one layout (SameLayout: UI text created later on its own
// layer, like a hover tooltip, follows the line's seqs without a hole), and it
// is fully revealed exactly when that suffix reaches the newest glyph the
// engine created: a choice menu or a title label whose later-created glyphs
// are not drawn is not a revealed line.  `glyphs` must be ordered by
// OrderFrameGlyphs.  Returns the run as UTF-16 (spaces in holes kept, line
// breaks dropped) with whitespace trimmed at both ends and the seq of its
// first glyph.
inline bool ComposeRevealedLine(const FrameGlyph* glyphs, size_t count,
                                uint64_t newest_created,
                                const CreationLog& log, std::wstring* text,
                                uint64_t* first_seq) {
  if (glyphs == nullptr || text == nullptr || first_seq == nullptr ||
      count == 0u || count > kMaxFrameGlyphs || newest_created == 0u ||
      glyphs[count - 1u].seq > newest_created ||
      !CreationsInvisible(log, glyphs[count - 1u].seq + 1u,
                          newest_created + 1u)) {
    return false;
  }
  size_t first = count - 1u;
  while (first > 0u &&
         CreationsInvisible(log, glyphs[first - 1u].seq + 1u,
                            glyphs[first].seq) &&
         SameLayout(log, glyphs[first - 1u].seq, glyphs[first].seq)) {
    --first;
  }
  std::wstring line;
  wchar_t units[2] = {};
  for (size_t index = first; index < count; ++index) {
    if (index > first) {
      for (uint64_t seq = glyphs[index - 1u].seq + 1u; seq < glyphs[index].seq;
           ++seq) {
        const uint32_t code = log.CodeAt(seq);
        if (code != kCreatedControl) line.append(units, Utf16Units(code, units));
      }
    }
    const size_t unit_count = Utf16Units(glyphs[index].codepoint, units);
    if (unit_count == 0u) return false;
    line.append(units, unit_count);
  }
  size_t begin = 0u, end = line.size();
  while (begin < end && IsLookupLineWhitespace(line[begin])) ++begin;
  while (end > begin && IsLookupLineWhitespace(line[end - 1u])) --end;
  if (begin == end) return false;
  *text = line.substr(begin, end - begin);
  *first_seq = glyphs[first].seq;
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

// ── game-thread message tap (sub-frame presses) ────────────────────────────

// Input::Update samples the left button once per frame.  A Windows touch tap is
// promoted to a back-to-back WM_LBUTTONDOWN/UP pair that fits inside one frame,
// so the sampler (and the engine) never see it: the stock game ignores touch
// taps.  The message tap watches the same press at the window-message level.
// `sampled` counts frames in which the sampler saw the button in any non-idle
// state; while it is unchanged from the down to the up message, the press is
// one the sampler never owned and the tap may finish it as a lookup.
struct TapLatch {
  bool armed = false;
  uint64_t sampled = 0u;     // sampler counter at the down message
  uint64_t generation = 0u;  // model generation the down hit
  uint32_t glyph = 0u;       // glyph the down hit
};

// Down message: arm only on an eligible hit, otherwise forget any older press.
inline void ArmTap(TapLatch* latch, bool eligible, uint64_t sampled,
                   uint64_t generation, uint32_t glyph) {
  if (latch == nullptr) return;
  *latch = TapLatch();
  if (!eligible || generation == 0u) return;
  latch->armed = true;
  latch->sampled = sampled;
  latch->generation = generation;
  latch->glyph = glyph;
}

// Up message: submit when the press is still armed, the sampler never saw it,
// and the release re-validates on the same glyph of the same model.  Always
// disarms: one down is at most one lookup.
inline bool ReleaseTap(TapLatch* latch, uint64_t sampled, bool eligible,
                       uint64_t generation, uint32_t glyph) {
  if (latch == nullptr) return false;
  const TapLatch armed = *latch;
  *latch = TapLatch();
  return armed.armed && armed.sampled == sampled && eligible &&
         armed.generation == generation && armed.glyph == glyph;
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
