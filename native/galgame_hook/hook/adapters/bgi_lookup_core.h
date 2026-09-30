#pragma once

// BGI / Ethornell message text lane + in-game lookup: pure, unit-tested half.
//
// Engine facts (x86 MSVC, two generations; measured 2026-09-30 with Frida on
// the 2011 Ethornell 1.519.6 trial, statically cross-checked on a 2016
// Ethornell 1.626 trial — the samples only, never an identity input):
//   * A message is shown through a message object (Ex class, CProcDspMsgEx in
//     the 1.6 RTTI) whose SetTextImpl(this, text, render, a2, a3) receives the
//     whole CP932 line.  1.5 builds use __thiscall (ret 0x10), 1.6 builds
//     __stdcall with `this` as the first stack argument (ret 0x14).  The Impl
//     keeps the owning display object at this+0x20 and a cell list whose
//     sentinel record is embedded at this+0x7c; it lays the text out through
//     the Ex vtable's layout slot (`lea esi,[ebx+0x7c]` → vcall) — the same
//     slot whose wrapper calls the layout function that owns the leading-
//     control-byte switch (the anchor LunaHook's EmbedBGI walks back from).
//   * The cell list is valid when SetTextImpl returns: one 0x48-byte record per
//     displayed character, linked through +0x44 starting at sentinel+0x44,
//     with the pen position in owner-local pixels at +0x10/+0x14 and the glyph
//     surface size at +0x28/+0x2c.  The message object is destroyed a few
//     hundred milliseconds later (after the reveal) while the rendered text
//     stays on the owner's layer until the next line, so the geometry must be
//     copied at SetTextImpl return.
//   * The owner is a DspObj.  Its vtable slot 2 is the engine's own
//     "is drawn" predicate (visible flags + transparency < 256; hiding the
//     message window, opening the backlog or a menu fades the transparency to
//     256), and one vtable slot composes its display position from the base
//     position and additive offset pairs (1.6 adds a camera offset when a flag
//     is set).  Both functions are decoded here from their bytes; any other
//     shape is refused.
//   * The screen is a design-size back buffer (screen mode index at T-4,
//     width table T, height table T+0x20) stretched over the whole client.
//   * Input: the main window procedure turns WM_LBUTTONDOWN into the engine's
//     key-down latch (the per-frame GetAsyncKeyState poll only releases it), so
//     a swallowed down/up pair never reaches the script (measured).
//
// Every site is proven by a byte shape plus a structural cross-check (the
// Impl's vcall slot must be the Ex vtable slot whose wrapper calls the anchored
// layout function; the vtable must be installed by a constructor store).  No
// hash, file name or title is consulted; anything missing or ambiguous installs
// nothing.

#include <windows.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "exact_lookup_signature.h"
#include "../lookup_line_text_match.h"

namespace fushi_voice_hook::bgi_lookup {

namespace exact = fushi_voice_hook::exact_lookup;

// ── engine record layout (both generations) ────────────────────────────────

inline constexpr size_t kCellLinkOffset = 0x44u;
inline constexpr size_t kCellXOffset = 0x10u;
inline constexpr size_t kCellYOffset = 0x14u;
inline constexpr size_t kCellSurfaceWidthOffset = 0x28u;
inline constexpr size_t kCellSurfaceHeightOffset = 0x2cu;
inline constexpr size_t kCellBytes = 0x48u;

inline constexpr size_t kMaxTextBytes = 512u;
inline constexpr size_t kMaxCells = 256u;
inline constexpr size_t kMaxPositionTerms = 4u;
inline constexpr size_t kMaxDrawableTerms = 6u;
inline constexpr int32_t kMaxCellSide = 512;
inline constexpr int32_t kMinDesignSide = 64;
inline constexpr int32_t kMaxDesignSide = 8192;

// ── signatures ─────────────────────────────────────────────────────────────

enum class Generation : uint32_t {
  kUnknown = 0,
  kThiscall = 1,  // 1.5x: SetTextImpl(this=ecx; text, render, a2, a3) ret 0x10
  kStdcall = 2,   // 1.6x: SetTextImpl(this, text, render, a2, a3) ret 0x14
};

// A masked byte shape: mask byte 0 = wildcard.
struct Shape {
  const uint8_t* bytes;
  const uint8_t* mask;
  size_t size;
};

inline bool ShapeAt(const uint8_t* at, const uint8_t* end, const Shape& shape) {
  if (at == nullptr || end == nullptr || at > end ||
      static_cast<size_t>(end - at) < shape.size) {
    return false;
  }
  for (size_t index = 0u; index < shape.size; ++index) {
    if (shape.mask[index] != 0u && at[index] != shape.bytes[index]) {
      return false;
    }
  }
  return true;
}

// Layout anchor: `cmp al,0x20; jge; movsx eax,al; add eax,-2; cmp eax,6; ja;
// jmp [eax*4+table]` — the leading control byte switch (2..8) of the layout.
inline constexpr uint8_t kAnchorBytes[] = {0x3c, 0x20, 0x7d, 0x00, 0x0f, 0xbe,
                                           0xc0, 0x83, 0xc0, 0xfe, 0x83, 0xf8,
                                           0x06, 0x77, 0x00, 0xff, 0x24, 0x85};
inline constexpr uint8_t kAnchorMask[] = {1, 1, 1, 0, 1, 1, 1, 1, 1,
                                          1, 1, 1, 1, 1, 0, 1, 1, 1};
inline constexpr Shape kAnchor = {kAnchorBytes, kAnchorMask,
                                  sizeof(kAnchorBytes)};

// 1.5 vcall: `lea esi,[ebx+list]; push ecx; push edx; push esi; mov ecx,ebx;
// call [eax+slot]`.
inline constexpr uint8_t kVcallThisBytes[] = {0x8d, 0x73, 0x00, 0x51, 0x52, 0x56,
                                              0x8b, 0xcb, 0xff, 0x50, 0x00};
inline constexpr uint8_t kVcallThisMask[] = {1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 0};
inline constexpr Shape kVcallThis = {kVcallThisBytes, kVcallThisMask,
                                     sizeof(kVcallThisBytes)};
inline constexpr size_t kVcallThisListByte = 2u;
inline constexpr size_t kVcallThisSlotByte = 10u;

// 1.6 vcall: `lea esi,[ebx+list]; push esi; mov ecx,ebx; call eax`, with the
// slot loaded earlier by `mov eax,[ebx]; mov eax,[eax+slot]`.
inline constexpr uint8_t kVcallStdBytes[] = {0x8d, 0x73, 0x00, 0x56,
                                             0x8b, 0xcb, 0xff, 0xd0};
inline constexpr uint8_t kVcallStdMask[] = {1, 1, 0, 1, 1, 1, 1, 1};
inline constexpr Shape kVcallStd = {kVcallStdBytes, kVcallStdMask,
                                    sizeof(kVcallStdBytes)};
inline constexpr size_t kVcallStdListByte = 2u;
inline constexpr uint8_t kSlotLoadStdBytes[] = {0x8b, 0x03, 0x8b, 0x40, 0x00};
inline constexpr uint8_t kSlotLoadStdMask[] = {1, 1, 1, 1, 0};
inline constexpr Shape kSlotLoadStd = {kSlotLoadStdBytes, kSlotLoadStdMask,
                                       sizeof(kSlotLoadStdBytes)};
inline constexpr size_t kSlotLoadStdScanBytes = 0x60u;

// Impl prologues.
// 1.5: `sub esp,imm8; push ebx; push ebp; mov ebx,ecx`
inline constexpr uint8_t kImplThisBytes[] = {0x83, 0xec, 0x00, 0x53,
                                             0x55, 0x8b, 0xd9};
inline constexpr uint8_t kImplThisMask[] = {1, 1, 0, 1, 1, 1, 1};
inline constexpr Shape kImplThis = {kImplThisBytes, kImplThisMask,
                                    sizeof(kImplThisBytes)};
// 1.6: `push ebp; mov ebp,esp; and esp,-8; sub esp,imm8`
inline constexpr uint8_t kImplStdBytes[] = {0x55, 0x8b, 0xec, 0x83, 0xe4,
                                            0xf8, 0x83, 0xec, 0x00};
inline constexpr uint8_t kImplStdMask[] = {1, 1, 1, 1, 1, 1, 1, 1, 0};
inline constexpr Shape kImplStd = {kImplStdBytes, kImplStdMask,
                                   sizeof(kImplStdBytes)};
// Owner loads: 1.5 `mov ecx,[ebx+owner]`; 1.6 `mov ebx,[ebp+8]` (this) then
// `mov esi,[ebx+owner]`.
inline constexpr uint8_t kOwnerThisBytes[] = {0x8b, 0x4b, 0x00};
inline constexpr uint8_t kOwnerThisMask[] = {1, 1, 0};
inline constexpr Shape kOwnerThis = {kOwnerThisBytes, kOwnerThisMask, 3u};
inline constexpr uint8_t kThisArgStdBytes[] = {0x8b, 0x5d, 0x08};
inline constexpr uint8_t kThisArgStdMask[] = {1, 1, 1};
inline constexpr Shape kThisArgStd = {kThisArgStdBytes, kThisArgStdMask, 3u};
inline constexpr uint8_t kOwnerStdBytes[] = {0x8b, 0x73, 0x00};
inline constexpr uint8_t kOwnerStdMask[] = {1, 1, 0};
inline constexpr Shape kOwnerStd = {kOwnerStdBytes, kOwnerStdMask, 3u};
inline constexpr size_t kOwnerScanBytes = 0x40u;
inline constexpr uint8_t kRetThis[] = {0xc2, 0x10, 0x00};
inline constexpr uint8_t kRetStd[] = {0xc2, 0x14, 0x00};
inline constexpr size_t kImplMaxSpan = 0x200u;
inline constexpr size_t kRetScanBytes = 0x100u;
inline constexpr size_t kLayoutMaxSpan = 0x200u;
inline constexpr size_t kWrapperScanBytes = 0x80u;

// ── owner (DspObj) functions ───────────────────────────────────────────────

// 1.5 slot 2: `mov eax,[ecx+a]; test; je; mov eax,[ecx+b]; test; je;
// cmp dword [ecx+c],0x100; jae; mov eax,1; ret`.
inline constexpr uint8_t kDrawableThisBytes[] = {
    0x8b, 0x41, 0x00, 0x85, 0xc0, 0x74, 0x00, 0x8b, 0x41, 0x00, 0x85,
    0xc0, 0x74, 0x00, 0x81, 0xb9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x73, 0x00, 0xb8, 0x01, 0x00, 0x00, 0x00, 0xc3};
inline constexpr uint8_t kDrawableThisMask[] = {
    1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1};
inline constexpr Shape kDrawableThis = {kDrawableThisBytes, kDrawableThisMask,
                                        sizeof(kDrawableThisBytes)};
// 1.6 slot 2: `cmp [ecx+a],0; je; cmp [ecx+b],0; je; cmp [ecx+c],0; jne;
// cmp dword [ecx+d],0x100; jae; cmp dword [ecx+e],0; jbe; mov eax,1; ret`.
inline constexpr uint8_t kDrawableStdBytes[] = {
    0x83, 0x79, 0x00, 0x00, 0x74, 0x00, 0x83, 0x79, 0x00, 0x00, 0x74,
    0x00, 0x83, 0x79, 0x00, 0x00, 0x75, 0x00, 0x81, 0xb9, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x73, 0x00, 0x83, 0xb9, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x76, 0x00, 0xb8, 0x01, 0x00, 0x00, 0x00,
    0xc3};
inline constexpr uint8_t kDrawableStdMask[] = {
    1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 0, 1, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1};
inline constexpr Shape kDrawableStd = {kDrawableStdBytes, kDrawableStdMask,
                                       sizeof(kDrawableStdBytes)};

// Pair getters `out = {[ecx+d], [ecx+d+4]}` in the three shapes both
// generations use, and 1.6's camera term.
inline constexpr uint8_t kPairStackBytes[] = {
    0x8b, 0x44, 0x24, 0x04, 0x8b, 0x51, 0x00, 0x89, 0x10,
    0x8b, 0x49, 0x00, 0x89, 0x48, 0x04, 0xc2, 0x04, 0x00};
inline constexpr uint8_t kPairStackMask[] = {1, 1, 1, 1, 1, 1, 0, 1, 1,
                                             1, 1, 0, 1, 1, 1, 1, 1, 1};
inline constexpr Shape kPairStack = {kPairStackBytes, kPairStackMask,
                                     sizeof(kPairStackBytes)};
inline constexpr uint8_t kPairFrameBytes[] = {
    0x55, 0x8b, 0xec, 0x8b, 0x51, 0x00, 0x8b, 0x45, 0x08, 0x89, 0x10,
    0x8b, 0x49, 0x00, 0x89, 0x48, 0x04, 0x5d, 0xc2, 0x04, 0x00};
inline constexpr uint8_t kPairFrameMask[] = {1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1,
                                             1, 1, 0, 1, 1, 1, 1, 1, 1, 1};
inline constexpr Shape kPairFrame = {kPairFrameBytes, kPairFrameMask,
                                     sizeof(kPairFrameBytes)};
inline constexpr uint8_t kPairRegBytes[] = {0x8b, 0x51, 0x00, 0x89, 0x10, 0x8b,
                                            0x49, 0x00, 0x89, 0x48, 0x04, 0xc3};
inline constexpr uint8_t kPairRegMask[] = {1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1};
inline constexpr Shape kPairReg = {kPairRegBytes, kPairRegMask,
                                   sizeof(kPairRegBytes)};
inline constexpr uint8_t kCameraBytes[] = {
    0x33, 0xc0, 0x39, 0x42, 0x00, 0x74, 0x00, 0xa1, 0x00, 0x00, 0x00, 0x00,
    0x8b, 0x15, 0x00, 0x00, 0x00, 0x00, 0x89, 0x01, 0x89, 0x51, 0x04, 0xb8,
    0x01, 0x00, 0x00, 0x00, 0xc3};
inline constexpr uint8_t kCameraMask[] = {1, 1, 1, 1, 0, 1, 0, 1, 0, 0,
                                          0, 0, 1, 1, 0, 0, 0, 0, 1, 1,
                                          1, 1, 1, 1, 1, 1, 1, 1, 1};
inline constexpr Shape kCamera = {kCameraBytes, kCameraMask,
                                  sizeof(kCameraBytes)};
inline constexpr size_t kDisplayScanBytes = 0x90u;
// Largest term shape; every term is decoded from one read of this size.
inline constexpr size_t kTermReadBytes = sizeof(kCameraBytes);
inline constexpr size_t kOwnerVtableSlots = 40u;

// ── image helpers ──────────────────────────────────────────────────────────

inline bool IsExecutableRva(const exact::LoadedPeImage& image, uintptr_t rva,
                            size_t bytes) {
  const exact::LoadedPeSection* section =
      exact::FindSectionForRva(image, rva, bytes);
  return section != nullptr &&
         (section->characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u;
}

inline bool IsDataRva(const exact::LoadedPeImage& image, uintptr_t rva,
                      size_t bytes) {
  const exact::LoadedPeSection* section =
      exact::FindSectionForRva(image, rva, bytes);
  return section != nullptr &&
         (section->characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u &&
         (section->characteristics & IMAGE_SCN_MEM_READ) != 0u;
}

inline uintptr_t AbsoluteBase(const exact::LoadedPeImage& image) {
  return image.absolute_base != 0u
             ? image.absolute_base
             : reinterpret_cast<uintptr_t>(image.base);
}

inline uint32_t ReadU32(const uint8_t* at) {
  uint32_t value = 0u;
  std::memcpy(&value, at, sizeof(value));
  return value;
}

// Absolute 32-bit VA operand → RVA; false when outside the image.
inline bool VaToRva(const exact::LoadedPeImage& image, uint32_t va,
                    uintptr_t* rva) {
  const uintptr_t base = AbsoluteBase(image);
  if (va < base || va - base >= image.size) return false;
  *rva = va - base;
  return true;
}

inline uint32_t RvaToVa(const exact::LoadedPeImage& image, uintptr_t rva) {
  return static_cast<uint32_t>(AbsoluteBase(image) + rva);
}

// Visits every executable byte span once: fn(rva_of_span, bytes, size).
template <typename Fn>
void ForEachExecutableSection(const exact::LoadedPeImage& image, Fn&& fn) {
  for (size_t index = 0u; index < image.section_count; ++index) {
    const exact::LoadedPeSection& section = image.sections[index];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u ||
        section.bytes == nullptr || section.size == 0u) {
      continue;
    }
    fn(static_cast<uintptr_t>(section.rva), section.bytes, section.size);
  }
}

// Every match of `shape` in executable sections (RVA of the first byte).
inline void FindShapeRvas(const exact::LoadedPeImage& image, const Shape& shape,
                          std::vector<uintptr_t>* out, size_t limit = 16u) {
  ForEachExecutableSection(
      image, [&](uintptr_t rva, const uint8_t* bytes, size_t size) {
        const uint8_t* end = bytes + size;
        for (size_t offset = 0u; offset + shape.size <= size; ++offset) {
          if (out->size() > limit) return;
          if (ShapeAt(bytes + offset, end, shape)) out->push_back(rva + offset);
        }
      });
}

// Sorted, unique targets of every `e8 rel32` in executable sections that land
// inside an executable section.  Byte-level (not instruction-level), so a
// target is only a candidate; callers prove it with a prologue shape.
inline std::vector<uintptr_t> CollectCallTargets(
    const exact::LoadedPeImage& image) {
  std::vector<uintptr_t> targets;
  ForEachExecutableSection(
      image, [&](uintptr_t rva, const uint8_t* bytes, size_t size) {
        for (size_t offset = 0u; offset + 5u <= size; ++offset) {
          if (bytes[offset] != 0xe8u) continue;
          int32_t rel = 0;
          std::memcpy(&rel, bytes + offset + 1u, sizeof(rel));
          const int64_t target = static_cast<int64_t>(rva + offset + 5u) + rel;
          if (target <= 0 || static_cast<uint64_t>(target) >= image.size) {
            continue;
          }
          const uintptr_t target_rva = static_cast<uintptr_t>(target);
          if (IsExecutableRva(image, target_rva, 16u)) {
            targets.push_back(target_rva);
          }
        }
      });
  std::sort(targets.begin(), targets.end());
  targets.erase(std::unique(targets.begin(), targets.end()), targets.end());
  return targets;
}

inline const uint8_t* BytesAt(const exact::LoadedPeImage& image, uintptr_t rva,
                              size_t bytes) {
  if (exact::FindSectionForRva(image, rva, bytes) == nullptr) return nullptr;
  return image.base + rva;
}

// The nearest call target at or below `site` (within `span`) whose bytes match
// `prologue`.
inline bool EnclosingFunction(const exact::LoadedPeImage& image,
                              const std::vector<uintptr_t>& targets,
                              uintptr_t site, size_t span,
                              const Shape* prologue, uintptr_t* entry) {
  auto upper = std::upper_bound(targets.begin(), targets.end(), site);
  while (upper != targets.begin()) {
    --upper;
    const uintptr_t candidate = *upper;
    if (site - candidate >= span) return false;
    const uint8_t* bytes = BytesAt(image, candidate, 32u);
    if (bytes == nullptr) continue;
    if (prologue == nullptr || ShapeAt(bytes, bytes + 32u, *prologue)) {
      *entry = candidate;
      return true;
    }
  }
  return false;
}

inline bool FindShapeIn(const uint8_t* begin, size_t bytes, const Shape& shape,
                        size_t* offset) {
  for (size_t index = 0u; index + shape.size <= bytes; ++index) {
    if (ShapeAt(begin + index, begin + bytes, shape)) {
      *offset = index;
      return true;
    }
  }
  return false;
}

// The last match (closest to the end of the window).
inline bool FindLastShapeIn(const uint8_t* begin, size_t bytes,
                            const Shape& shape, size_t* offset) {
  bool found = false;
  for (size_t index = 0u; index + shape.size <= bytes; ++index) {
    if (ShapeAt(begin + index, begin + bytes, shape)) {
      *offset = index;
      found = true;
    }
  }
  return found;
}

inline bool ContainsBytes(const uint8_t* begin, size_t bytes,
                          const uint8_t* needle, size_t needle_bytes) {
  for (size_t index = 0u; index + needle_bytes <= bytes; ++index) {
    if (std::memcmp(begin + index, needle, needle_bytes) == 0) return true;
  }
  return false;
}

// ── site resolution ────────────────────────────────────────────────────────

struct Sites {
  Generation generation = Generation::kUnknown;
  uintptr_t set_text_impl = 0u;   // RVA
  uintptr_t ex_vtable = 0u;       // RVA
  uintptr_t layout = 0u;          // RVA (proof only; never hooked)
  uint32_t layout_slot_disp = 0u;
  uint32_t owner_offset = 0u;
  uint32_t list_offset = 0u;      // sentinel record; first cell at +0x44
  uintptr_t screen_index = 0u;    // RVA of the screen mode index
  uintptr_t screen_widths = 0u;   // RVA; heights at +0x20
};

enum class SiteResult : uint32_t {
  kResolved = 0,
  kNotX86 = 1,
  kVcallMissing = 2,
  kVcallAmbiguous = 3,
  kImplMissing = 4,
  kImplShape = 5,
  kAnchorMissing = 6,
  kLayoutMissing = 7,
  kVtableMissing = 8,
  kVtableAmbiguous = 9,
  kScreenMissing = 10,
  kScreenAmbiguous = 11,
};

// The Impl: exactly one vcall shape of either generation in the image, its
// enclosing function carries that generation's prologue, owner load and
// return.
inline SiteResult ResolveImpl(const exact::LoadedPeImage& image,
                              const std::vector<uintptr_t>& targets,
                              Sites* sites) {
  std::vector<uintptr_t> this_sites;
  std::vector<uintptr_t> std_sites;
  FindShapeRvas(image, kVcallThis, &this_sites);
  FindShapeRvas(image, kVcallStd, &std_sites);
  if (this_sites.size() + std_sites.size() == 0u) {
    return SiteResult::kVcallMissing;
  }
  if (this_sites.size() + std_sites.size() != 1u) {
    return SiteResult::kVcallAmbiguous;
  }
  const bool thiscall = this_sites.size() == 1u;
  const uintptr_t vcall = thiscall ? this_sites[0] : std_sites[0];
  const uint8_t* vcall_bytes = BytesAt(image, vcall, kVcallThis.size);
  if (vcall_bytes == nullptr) return SiteResult::kVcallMissing;
  uintptr_t entry = 0u;
  if (!EnclosingFunction(image, targets, vcall, kImplMaxSpan,
                         thiscall ? &kImplThis : &kImplStd, &entry)) {
    return SiteResult::kImplMissing;
  }
  const size_t head = vcall - entry;
  const uint8_t* body = BytesAt(image, entry, head + kRetScanBytes);
  if (body == nullptr) return SiteResult::kImplShape;
  const size_t owner_scan = (std::min)(head, kOwnerScanBytes);
  size_t at = 0u;
  uint32_t owner = 0u;
  uint32_t slot = 0u;
  if (thiscall) {
    if (!FindShapeIn(body, owner_scan, kOwnerThis, &at)) {
      return SiteResult::kImplShape;
    }
    owner = body[at + 2u];
    slot = vcall_bytes[kVcallThisSlotByte];
  } else {
    // `mov ebx,[ebp+8]` (this) must precede `mov esi,[ebx+owner]`.
    size_t this_at = 0u;
    size_t owner_at = 0u;
    if (!FindShapeIn(body, owner_scan, kThisArgStd, &this_at) ||
        !FindShapeIn(body + this_at, owner_scan - this_at, kOwnerStd,
                     &owner_at)) {
      return SiteResult::kImplShape;
    }
    owner = body[this_at + owner_at + 2u];
    const size_t load_scan = (std::min)(head, kSlotLoadStdScanBytes);
    size_t load_at = 0u;
    // The slot load nearest the vcall is the one feeding `call eax`.
    if (!FindLastShapeIn(body + head - load_scan, load_scan, kSlotLoadStd,
                         &load_at)) {
      return SiteResult::kImplShape;
    }
    slot = body[head - load_scan + load_at + 4u];
  }
  const uint32_t list = vcall_bytes[thiscall ? kVcallThisListByte
                                             : kVcallStdListByte];
  if (!ContainsBytes(body + head, kRetScanBytes, thiscall ? kRetThis : kRetStd,
                     3u) ||
      owner == 0u || list <= owner || slot == 0u || (slot % 4u) != 0u) {
    return SiteResult::kImplShape;
  }
  sites->generation = thiscall ? Generation::kThiscall : Generation::kStdcall;
  sites->set_text_impl = entry;
  sites->owner_offset = owner;
  sites->list_offset = list;
  sites->layout_slot_disp = slot;
  return SiteResult::kResolved;
}

// Cross-proof: the layout slot of the vtable a constructor installs must be a
// wrapper that calls the layout function owning the control-byte switch.
inline SiteResult ResolveExVtable(const exact::LoadedPeImage& image,
                                  const std::vector<uintptr_t>& targets,
                                  Sites* sites) {
  std::vector<uintptr_t> anchors;
  FindShapeRvas(image, kAnchor, &anchors);
  if (anchors.size() != 1u) return SiteResult::kAnchorMissing;
  uintptr_t layout = 0u;
  if (!EnclosingFunction(image, targets, anchors[0], kLayoutMaxSpan, nullptr,
                         &layout)) {
    return SiteResult::kLayoutMissing;
  }
  // Constructor / destructor vtable stores: `mov dword [reg], imm32`
  // (c7 /0, mod 00, rm not esp/ebp).
  std::vector<uintptr_t> vtables;
  ForEachExecutableSection(
      image, [&](uintptr_t rva, const uint8_t* bytes, size_t size) {
        for (size_t offset = 0u; offset + 6u <= size; ++offset) {
          const uint8_t modrm = bytes[offset + 1u];
          if (bytes[offset] != 0xc7u || (modrm & 0xf8u) != 0u ||
              modrm == 0x04u || modrm == 0x05u) {
            continue;
          }
          uintptr_t table = 0u;
          if (!VaToRva(image, ReadU32(bytes + offset + 2u), &table) ||
              !IsDataRva(image, table, sites->layout_slot_disp + 4u)) {
            continue;
          }
          vtables.push_back(table);
        }
        (void)rva;
      });
  std::sort(vtables.begin(), vtables.end());
  vtables.erase(std::unique(vtables.begin(), vtables.end()), vtables.end());
  uintptr_t found = 0u;
  size_t matches = 0u;
  for (const uintptr_t table : vtables) {
    uintptr_t wrapper = 0u;
    if (!VaToRva(image,
                 ReadU32(image.base + table + sites->layout_slot_disp),
                 &wrapper)) {
      continue;
    }
    const uint8_t* bytes = BytesAt(image, wrapper, kWrapperScanBytes);
    if (bytes == nullptr || !IsExecutableRva(image, wrapper, 1u)) continue;
    bool calls_layout = false;
    for (size_t offset = 0u; offset + 5u <= kWrapperScanBytes; ++offset) {
      if (bytes[offset] != 0xe8u) continue;
      int32_t rel = 0;
      std::memcpy(&rel, bytes + offset + 1u, sizeof(rel));
      if (static_cast<int64_t>(wrapper + offset + 5u) + rel ==
          static_cast<int64_t>(layout)) {
        calls_layout = true;
        break;
      }
    }
    if (!calls_layout) continue;
    // The Impl must also be reachable through that vtable (both generations
    // route SetText → Impl through direct calls within a few hops).
    found = table;
    ++matches;
  }
  if (matches == 0u) return SiteResult::kVtableMissing;
  if (matches != 1u) return SiteResult::kVtableAmbiguous;
  sites->ex_vtable = found;
  sites->layout = layout;
  return SiteResult::kResolved;
}

// Screen mode tables: `mov eax,[reg*4+W]` and `mov eax,[reg*4+W+0x20]` both
// exist, and the index word at W-4 is read by `mov eax,[W-4]`.
inline SiteResult ResolveScreenTables(const exact::LoadedPeImage& image,
                                      Sites* sites) {
  std::vector<uintptr_t> tables;
  ForEachExecutableSection(
      image, [&](uintptr_t, const uint8_t* bytes, size_t size) {
        for (size_t offset = 0u; offset + 7u <= size; ++offset) {
          if (bytes[offset] != 0x8bu || bytes[offset + 1u] != 0x04u ||
              bytes[offset + 2u] != 0x85u) {
            continue;
          }
          uintptr_t table = 0u;
          if (VaToRva(image, ReadU32(bytes + offset + 3u), &table) &&
              IsDataRva(image, table, 0x40u)) {
            tables.push_back(table);
          }
        }
      });
  std::sort(tables.begin(), tables.end());
  tables.erase(std::unique(tables.begin(), tables.end()), tables.end());
  std::vector<uintptr_t> index_reads;
  ForEachExecutableSection(
      image, [&](uintptr_t, const uint8_t* bytes, size_t size) {
        for (size_t offset = 0u; offset + 5u <= size; ++offset) {
          if (bytes[offset] != 0xa1u) continue;
          uintptr_t word = 0u;
          if (VaToRva(image, ReadU32(bytes + offset + 1u), &word)) {
            index_reads.push_back(word);
          }
        }
      });
  std::sort(index_reads.begin(), index_reads.end());
  size_t matches = 0u;
  uintptr_t found = 0u;
  for (const uintptr_t widths : tables) {
    if (widths < 4u) continue;
    if (!std::binary_search(tables.begin(), tables.end(), widths + 0x20u) ||
        !std::binary_search(index_reads.begin(), index_reads.end(),
                            widths - 4u)) {
      continue;
    }
    found = widths;
    ++matches;
  }
  if (matches == 0u) return SiteResult::kScreenMissing;
  if (matches != 1u) return SiteResult::kScreenAmbiguous;
  sites->screen_widths = found;
  sites->screen_index = found - 4u;
  return SiteResult::kResolved;
}

inline SiteResult ResolveSites(const exact::LoadedPeImage& image,
                               Sites* out) {
  if (out == nullptr || image.base == nullptr || image.pointer_bits != 32u ||
      image.machine != IMAGE_FILE_MACHINE_I386) {
    return SiteResult::kNotX86;
  }
  Sites sites;
  const std::vector<uintptr_t> targets = CollectCallTargets(image);
  SiteResult result = ResolveImpl(image, targets, &sites);
  if (result != SiteResult::kResolved) return result;
  result = ResolveExVtable(image, targets, &sites);
  if (result != SiteResult::kResolved) return result;
  result = ResolveScreenTables(image, &sites);
  if (result != SiteResult::kResolved) return result;
  *out = sites;
  return SiteResult::kResolved;
}

// Screen mode index → design size (both tables have 8 entries).
inline bool DesignSizeFrom(uint32_t index, const uint32_t* widths,
                           const uint32_t* heights, int32_t* w, int32_t* h) {
  if (index >= 8u || widths == nullptr || heights == nullptr) return false;
  const uint32_t width = widths[index];
  const uint32_t height = heights[index];
  if (width < static_cast<uint32_t>(kMinDesignSide) ||
      height < static_cast<uint32_t>(kMinDesignSide) ||
      width > static_cast<uint32_t>(kMaxDesignSide) ||
      height > static_cast<uint32_t>(kMaxDesignSide)) {
    return false;
  }
  *w = static_cast<int32_t>(width);
  *h = static_cast<int32_t>(height);
  return true;
}

// ── owner (DspObj) ABI, decoded from its own vtable functions ──────────────

enum class DrawableOp : uint8_t {
  kNonZero = 0,
  kZero = 1,
  kBelow256 = 2,  // unsigned < 0x100
  kPositive = 3,  // unsigned > 0
};

struct DrawableTerm {
  uint32_t offset = 0u;
  DrawableOp op = DrawableOp::kNonZero;
};

struct OwnerAbi {
  bool valid = false;
  uint32_t drawable_count = 0u;
  std::array<DrawableTerm, kMaxDrawableTerms> drawable{};
  uint32_t position_count = 0u;
  std::array<uint32_t, kMaxPositionTerms> position{};  // pair offsets, summed
  bool has_camera = false;
  uint32_t camera_flag = 0u;  // must read 0 (camera offset not applied)
  uint32_t display_slot = 0u;
  uint32_t max_field = 0u;    // highest byte offset read (+4)
};

inline void NoteField(OwnerAbi* abi, uint32_t offset) {
  abi->max_field = (std::max)(abi->max_field, offset + 4u);
}

inline bool DecodeDrawable(const uint8_t* bytes, size_t size, OwnerAbi* abi) {
  if (bytes == nullptr) return false;
  const uint8_t* end = bytes + size;
  auto add = [abi](uint32_t offset, DrawableOp op) {
    DrawableTerm& term = abi->drawable[abi->drawable_count++];
    term.offset = offset;
    term.op = op;
    NoteField(abi, offset);
  };
  abi->drawable_count = 0u;
  if (ShapeAt(bytes, end, kDrawableThis)) {
    add(bytes[2], DrawableOp::kNonZero);
    add(bytes[9], DrawableOp::kNonZero);
    add(ReadU32(bytes + 16u), DrawableOp::kBelow256);
    return true;
  }
  if (ShapeAt(bytes, end, kDrawableStd)) {
    add(bytes[2], DrawableOp::kNonZero);
    add(bytes[8], DrawableOp::kNonZero);
    add(bytes[14], DrawableOp::kZero);
    add(ReadU32(bytes + 20u), DrawableOp::kBelow256);
    add(ReadU32(bytes + 32u), DrawableOp::kPositive);
    return true;
  }
  return false;
}

// A pair getter or the camera term at `bytes`.
enum class TermKind : uint8_t { kNone, kPair, kCamera };

inline TermKind DecodeTerm(const uint8_t* bytes, size_t size,
                           uint32_t* offset) {
  if (bytes == nullptr) return TermKind::kNone;
  const uint8_t* end = bytes + size;
  if (ShapeAt(bytes, end, kPairStack) && bytes[11] == bytes[6] + 4u) {
    *offset = bytes[6];
    return TermKind::kPair;
  }
  if (ShapeAt(bytes, end, kPairFrame) && bytes[13] == bytes[5] + 4u) {
    *offset = bytes[5];
    return TermKind::kPair;
  }
  if (ShapeAt(bytes, end, kPairReg) && bytes[7] == bytes[2] + 4u) {
    *offset = bytes[2];
    return TermKind::kPair;
  }
  if (ShapeAt(bytes, end, kCamera)) {
    *offset = bytes[4];
    return TermKind::kCamera;
  }
  return TermKind::kNone;
}

// `read(address, size) -> const uint8_t*` returns readable bytes (or null).
// The owner's display function is the one vtable slot whose body, up to its
// `ret 4`, calls only pair getters (at least two: the base position and its
// offsets) and at most one camera term.  Exactly one function must qualify.
template <typename ReadFn>
bool DecodeOwnerAbi(uintptr_t vtable, ReadFn&& read, OwnerAbi* out) {
  OwnerAbi abi;
  const uint8_t* slots = read(vtable, kOwnerVtableSlots * 4u);
  if (slots == nullptr || out == nullptr) return false;
  if (!DecodeDrawable(read(ReadU32(slots + 8u), kDrawableStd.size),
                      kDrawableStd.size, &abi)) {
    return false;
  }
  uint32_t found = 0u;
  OwnerAbi best;
  uintptr_t best_function = 0u;
  for (uint32_t slot = 3u; slot < kOwnerVtableSlots; ++slot) {
    const uintptr_t function = ReadU32(slots + slot * 4u);
    const uint8_t* body = read(function, kDisplayScanBytes);
    if (body == nullptr) break;  // past the end of the vtable
    OwnerAbi candidate = abi;
    candidate.position_count = 0u;
    candidate.has_camera = false;
    bool ok = true;
    bool ended = false;
    for (size_t offset = 0u; offset + 3u <= kDisplayScanBytes && ok; ++offset) {
      if (body[offset] == 0xc2u && body[offset + 1u] == 0x04u &&
          body[offset + 2u] == 0x00u) {
        ended = true;
        break;
      }
      if (body[offset] != 0xe8u || offset + 5u > kDisplayScanBytes) continue;
      int32_t rel = 0;
      std::memcpy(&rel, body + offset + 1u, sizeof(rel));
      const uintptr_t target = function + offset + 5u + rel;
      uint32_t field = 0u;
      const TermKind final_kind =
          DecodeTerm(read(target, kTermReadBytes), kTermReadBytes, &field);
      if (final_kind == TermKind::kPair &&
          candidate.position_count < kMaxPositionTerms) {
        candidate.position[candidate.position_count++] = field;
        NoteField(&candidate, field + 4u);
        offset += 4u;
      } else if (final_kind == TermKind::kCamera && !candidate.has_camera) {
        candidate.has_camera = true;
        candidate.camera_flag = field;
        NoteField(&candidate, field);
        offset += 4u;
      } else {
        ok = false;
      }
    }
    if (!ok || !ended || candidate.position_count < 2u) continue;
    // The slot scan may run into the next (packed) vtable, which usually
    // inherits the same base function: count distinct functions only.
    if (found != 0u && function == best_function) continue;
    candidate.display_slot = slot;
    best = candidate;
    best_function = function;
    ++found;
  }
  if (found != 1u) return false;
  best.valid = true;
  *out = best;
  return true;
}

inline bool EvaluateDrawable(const OwnerAbi& abi, const uint8_t* owner,
                             size_t owner_bytes) {
  if (!abi.valid || owner == nullptr || owner_bytes < abi.max_field) {
    return false;
  }
  for (uint32_t index = 0u; index < abi.drawable_count; ++index) {
    const DrawableTerm& term = abi.drawable[index];
    const uint32_t value = ReadU32(owner + term.offset);
    switch (term.op) {
      case DrawableOp::kNonZero:
        if (value == 0u) return false;
        break;
      case DrawableOp::kZero:
        if (value != 0u) return false;
        break;
      case DrawableOp::kBelow256:
        if (value >= 0x100u) return false;
        break;
      case DrawableOp::kPositive:
        if (value == 0u) return false;
        break;
    }
  }
  return true;
}

// Display position = Σ pairs; refused while the camera flag applies a global
// offset this provider does not model.
inline bool EvaluatePosition(const OwnerAbi& abi, const uint8_t* owner,
                             size_t owner_bytes, int32_t* x, int32_t* y) {
  if (!abi.valid || owner == nullptr || owner_bytes < abi.max_field ||
      x == nullptr || y == nullptr) {
    return false;
  }
  if (abi.has_camera && ReadU32(owner + abi.camera_flag) != 0u) return false;
  int64_t sx = 0, sy = 0;
  for (uint32_t index = 0u; index < abi.position_count; ++index) {
    int32_t px = 0, py = 0;
    std::memcpy(&px, owner + abi.position[index], sizeof(px));
    std::memcpy(&py, owner + abi.position[index] + 4u, sizeof(py));
    sx += px;
    sy += py;
  }
  if (sx < -kMaxDesignSide || sx > kMaxDesignSide || sy < -kMaxDesignSide ||
      sy > kMaxDesignSide) {
    return false;
  }
  *x = static_cast<int32_t>(sx);
  *y = static_cast<int32_t>(sy);
  return true;
}

// ── text ───────────────────────────────────────────────────────────────────

inline bool IsCp932Lead(uint8_t byte) {
  return (byte >= 0x81u && byte <= 0x9fu) || (byte >= 0xe0u && byte <= 0xfcu);
}

struct TextUnit {
  uint16_t offset = 0u;   // byte offset in the source line
  uint8_t length = 0u;    // 1 or 2 CP932 bytes
  bool source = true;     // part of the published line
};

struct ParsedText {
  uint32_t count = 0u;
  std::array<TextUnit, kMaxTextBytes> units{};
  bool markup = false;    // inline tags: geometry cannot be mapped
  bool truncated = false;
  uint8_t auto_prefix = 0u;  // leading control byte 4..8 (engine-inserted char)
};

// Engine-inserted opening characters for leading control bytes 4..8 (CP932):
// 「 　 （ “ 『.
inline constexpr uint8_t kAutoPrefix[5][2] = {
    {0x81, 0x75}, {0x81, 0x40}, {0x81, 0x69}, {0x81, 0x67}, {0x81, 0x77}};

// Splits a NUL-terminated CP932 line into displayed units.  Inline tags
// (`<...>`) are dropped from the published text except the base text of
// ruby (`<r...>base</r>`), and mark the line as unmappable for geometry
// (ruby readings get cells of their own whose order is not modelled).  '\n'
// is a line break (no unit); '\\' escapes the next character.
inline ParsedText ParseLine(const uint8_t* text, size_t bytes) {
  ParsedText out;
  if (text == nullptr) return out;
  size_t length = 0u;
  while (length < bytes && text[length] != 0u) ++length;
  size_t at = 0u;
  if (length > 0u && text[0] < 0x20u && text[0] >= 0x02u &&
      text[0] <= 0x08u) {
    if (text[0] >= 0x04u) out.auto_prefix = text[0];
    at = 1u;
  }
  auto push = [&out](size_t offset, uint8_t size, bool source) {
    if (out.count >= out.units.size()) {
      out.truncated = true;
      return;
    }
    TextUnit& unit = out.units[out.count++];
    unit.offset = static_cast<uint16_t>(offset);
    unit.length = size;
    unit.source = source;
  };
  if (out.auto_prefix != 0u) push(0u, 0u, false);
  while (at < length) {
    const uint8_t byte = text[at];
    if (byte == '<') {
      out.markup = true;
      // Skip the tag; ruby readings sit inside `<r reading>` and are dropped
      // with it, the base text between the tags is kept.
      while (at < length && text[at] != '>') {
        at += IsCp932Lead(text[at]) && at + 1u < length ? 2u : 1u;
      }
      if (at < length) ++at;
      continue;
    }
    if (byte == '\n' || byte == '\r') {
      ++at;
      continue;
    }
    if (byte == '\\' && at + 1u < length) {
      ++at;
      const uint8_t size = IsCp932Lead(text[at]) && at + 1u < length ? 2u : 1u;
      push(at, size, true);
      at += size;
      continue;
    }
    if (byte < 0x20u) {  // other control bytes are not displayed
      ++at;
      continue;
    }
    const uint8_t size = IsCp932Lead(byte) && at + 1u < length ? 2u : 1u;
    push(at, size, true);
    at += size;
  }
  return out;
}

// ── page model ─────────────────────────────────────────────────────────────

inline constexpr uint16_t kNoSource = 0xffffu;

struct Cell {
  int32_t x = 0;  // owner-local pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

struct LineGlyph {
  uint32_t codepoint = 0u;
  int32_t x = 0;  // design pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  uint16_t source_index = kNoSource;
  uint8_t source_length = 0u;
};

inline bool CellPlausible(const Cell& cell) {
  return cell.w > 0 && cell.h > 0 && cell.w <= kMaxCellSide &&
         cell.h <= kMaxCellSide && cell.x > -kMaxDesignSide &&
         cell.x < kMaxDesignSide && cell.y > -kMaxDesignSide &&
         cell.y < kMaxDesignSide;
}

// One cell per displayed unit, in order.  `codepoints[i]` is the UTF-16 unit
// of display unit i.  A cell is trimmed to the pen of its right neighbour on
// the same row (glyph surfaces overlap by the outline margin).  Returns the
// glyph count, or 0 when the page cannot be mapped.
inline size_t BuildPageGlyphs(const Cell* cells, size_t cell_count,
                              const uint32_t* codepoints,
                              const uint16_t* source_index,
                              size_t unit_count, int32_t origin_x,
                              int32_t origin_y, LineGlyph* out,
                              size_t capacity) {
  if (cells == nullptr || codepoints == nullptr || source_index == nullptr ||
      out == nullptr || cell_count == 0u || cell_count != unit_count ||
      cell_count > capacity) {
    return 0u;
  }
  for (size_t index = 0u; index < cell_count; ++index) {
    const Cell& cell = cells[index];
    if (!CellPlausible(cell)) return 0u;
    int32_t w = cell.w;
    if (index + 1u < cell_count) {
      const Cell& next = cells[index + 1u];
      if (next.y == cell.y && next.x > cell.x && next.x < cell.x + w) {
        w = next.x - cell.x;
      }
    }
    LineGlyph& glyph = out[index];
    glyph.codepoint = codepoints[index];
    glyph.x = origin_x + cell.x;
    glyph.y = origin_y + cell.y;
    glyph.w = w;
    glyph.h = cell.h;
    glyph.source_index = source_index[index];
    glyph.source_length = source_index[index] == kNoSource ? 0u : 1u;
  }
  return cell_count;
}

// The selected line is matched as the render-order suffix of the page
// (whitespace-insensitive); every character of it must be a glyph of the page.
// Glyphs before the match stay unmapped.  Returns the first mapped index, or
// `count` when there is no match.
inline size_t MapSelectedSuffix(LineGlyph* glyphs, size_t count,
                                const wchar_t* selected,
                                size_t selected_count) {
  if (glyphs == nullptr || selected == nullptr || count == 0u ||
      selected_count == 0u || selected_count >= kNoSource) {
    return count;
  }
  auto fail = [glyphs, count]() {
    for (size_t index = 0u; index < count; ++index) {
      glyphs[index].source_index = kNoSource;
      glyphs[index].source_length = 0u;
    }
    return count;
  };
  fail();
  size_t source = selected_count;
  size_t glyph = count;
  bool any = false;
  for (;;) {
    while (source > 0u && IsLookupLineWhitespace(selected[source - 1u])) {
      --source;
    }
    if (source == 0u) break;
    if (glyph == 0u) return fail();
    const uint32_t codepoint = glyphs[glyph - 1u].codepoint;
    if (codepoint == 0u || codepoint > 0xffffu) return fail();
    const wchar_t unit = static_cast<wchar_t>(codepoint);
    if (IsLookupLineWhitespace(unit)) {
      --glyph;
      continue;
    }
    if (selected[source - 1u] != unit) return fail();
    --source;
    glyphs[glyph - 1u].source_index = static_cast<uint16_t>(source);
    glyphs[glyph - 1u].source_length = 1u;
    any = true;
    --glyph;
  }
  if (!any) return fail();
  return glyph;
}

// ── projection and hit testing ─────────────────────────────────────────────

struct PixelRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

inline bool ClientMatchesDesign(int32_t client_w, int32_t client_h,
                                int32_t design_w, int32_t design_h) {
  if (client_w <= 0 || client_h <= 0 || design_w <= 0 || design_h <= 0) {
    return false;
  }
  const int64_t cross = static_cast<int64_t>(client_w) * design_h -
                        static_cast<int64_t>(client_h) * design_w;
  const int64_t limit = (std::max)(design_w, design_h);
  return cross <= limit && cross >= -limit;
}

inline bool ProjectCell(const LineGlyph& glyph, int32_t design_w,
                        int32_t design_h, int32_t physical_w,
                        int32_t physical_h, PixelRect* out) {
  if (out == nullptr || design_w <= 0 || design_h <= 0 || physical_w <= 0 ||
      physical_h <= 0 || glyph.w <= 0 || glyph.h <= 0 || glyph.x < 0 ||
      glyph.y < 0 || glyph.x + glyph.w > design_w ||
      glyph.y + glyph.h > design_h) {
    return false;
  }
  const double sx = static_cast<double>(physical_w) / design_w;
  const double sy = static_cast<double>(physical_h) / design_h;
  const int32_t x0 = static_cast<int32_t>(glyph.x * sx);
  const int32_t y0 = static_cast<int32_t>(glyph.y * sy);
  const double right = (glyph.x + glyph.w) * sx;
  const double bottom = (glyph.y + glyph.h) * sy;
  int32_t x1 = static_cast<int32_t>(right);
  int32_t y1 = static_cast<int32_t>(bottom);
  if (x1 < right) ++x1;
  if (y1 < bottom) ++y1;
  if (x1 > physical_w || y1 > physical_h || x1 - x0 < 1 || y1 - y0 < 1) {
    return false;
  }
  *out = {x0, y0, x1 - x0, y1 - y0};
  return true;
}

inline bool ClientToDesign(int32_t x, int32_t y, int32_t client_w,
                           int32_t client_h, int32_t design_w,
                           int32_t design_h, int32_t* out_x, int32_t* out_y) {
  if (client_w <= 0 || client_h <= 0 || x < 0 || y < 0 || x >= client_w ||
      y >= client_h || out_x == nullptr || out_y == nullptr) {
    return false;
  }
  *out_x = static_cast<int32_t>(static_cast<int64_t>(x) * design_w / client_w);
  *out_y = static_cast<int32_t>(static_cast<int64_t>(y) * design_h / client_h);
  return true;
}

inline bool HitTestLine(const LineGlyph* glyphs, size_t count, int32_t x,
                        int32_t y, size_t* hit) {
  if (glyphs == nullptr || hit == nullptr) return false;
  size_t found = count;
  for (size_t index = 0u; index < count; ++index) {
    const LineGlyph& glyph = glyphs[index];
    if (glyph.source_index == kNoSource) continue;
    if (x < glyph.x || y < glyph.y || x >= glyph.x + glyph.w ||
        y >= glyph.y + glyph.h) {
      continue;
    }
    if (found != count) return false;
    found = index;
  }
  if (found == count) return false;
  *hit = found;
  return true;
}

// ── message-thread click claim ─────────────────────────────────────────────

inline constexpr uint32_t kMessageLeftDown = WM_LBUTTONDOWN;
inline constexpr uint32_t kMessageLeftUp = WM_LBUTTONUP;
inline constexpr uint32_t kMessageLeftDouble = WM_LBUTTONDBLCLK;

struct ClaimState {
  bool owned = false;
};

struct ClaimDecision {
  bool evaluate = false;
  bool swallow = false;
  bool submit = false;
};

inline bool NeedsEligibility(uint32_t message) {
  return message == kMessageLeftDown || message == kMessageLeftDouble;
}

// A claimed press owns the button until its release; both edges are swallowed
// so the engine's key-down latch never sees the click.
inline ClaimDecision DecideMessage(uint32_t message, bool eligible,
                                   ClaimState* claim) {
  ClaimDecision decision;
  if (claim == nullptr) return decision;
  if (NeedsEligibility(message)) {
    decision.evaluate = true;
    claim->owned = eligible;
    decision.swallow = eligible;
    decision.submit = eligible;
  } else if (message == kMessageLeftUp && claim->owned) {
    claim->owned = false;
    decision.swallow = true;
  }
  return decision;
}

// ── published models ───────────────────────────────────────────────────────

// The selected line each recently published model was matched against.  A
// claimed press is resolved against the model it was claimed on, not the
// newest one: the worker may rebuild the model (the message window fades out
// and back in around a speaker change, a new line arrives) between the press
// and the tick that reads it, and the game never saw that press.
struct PublishedLine {
  uint64_t generation = 0u;
  uint64_t text_event = 0u;
  std::wstring line;
};

class PublishedLines {
 public:
  static constexpr size_t kCapacity = 4u;
  void Record(uint64_t generation, uint64_t text_event,
              const std::wstring& line) {
    PublishedLine& slot = slots_[next_++ % kCapacity];
    slot.generation = generation;
    slot.text_event = text_event;
    slot.line = line;
  }
  const PublishedLine* Find(uint64_t generation) const {
    if (generation == 0u) return nullptr;
    for (const PublishedLine& slot : slots_) {
      if (slot.generation == generation && !slot.line.empty()) return &slot;
    }
    return nullptr;
  }

 private:
  std::array<PublishedLine, kCapacity> slots_{};
  size_t next_ = 0u;
};

// Stable text-lane identity of a message owner: the owner class and its base
// position (the dialogue box and a name plate are different owners at
// different places; the owner object itself is recreated across menus).
inline uint64_t LaneIdentity(uint32_t owner_vtable_rva, int32_t x, int32_t y) {
  return (static_cast<uint64_t>(owner_vtable_rva) << 32) ^
         (static_cast<uint64_t>(static_cast<uint16_t>(x)) << 16) ^
         static_cast<uint64_t>(static_cast<uint16_t>(y));
}

}  // namespace fushi_voice_hook::bgi_lookup
