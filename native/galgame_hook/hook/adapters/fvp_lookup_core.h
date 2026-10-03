#pragma once

// FVP（Favorite View Point）native text lane + in-game lookup: pure,
// unit-tested half.
//
// Engine facts (x86 MSVC; measured 2026-10 on the 2011 FAVORITE
// 《いろとりどりのセカイ》 World.exe — the sample only, never an identity input):
//   * The HCB bytecode VM calls native "syscalls" through a name table the exe
//     builds at start-up: for every name it fills a pointer-to-member block
//     (`mov r32,handler; mov [eax],r32`), pushes the argument count and the
//     ASCII name and calls one registration function.  `TextPrint` (argc 2:
//     text-buffer index 0..31, string) is the dialogue output point; its
//     handler bounds the index (`cmp eax,0x1f`), loads the text object from the
//     VM's text-buffer array (`mov edx,[G]; mov ebp,[edx+eax*4+A]`), measures
//     the string (`call [lstrlenA]; cmp eax,0x200`) and hands it to the text
//     object's Print(this, const char*).
//   * Print queues the CP932 characters and lays the whole string out at once:
//     every glyph goes through PutGlyph(this, format*, glyph*, bool ruby), which
//     blends the glyph at the text object's pen (i16 pen_x / pen_y fields) into
//     the text object's surface and advances the pen.  Inline ruby is written
//     `[ruby|base]`: the ruby glyphs are put first with ruby=1 (ruby font size
//     format+4), then the base glyphs with ruby=0; when the format reserves ruby
//     space (format+0x14 == 2) a base glyph sits format+4 + format+0x24 below
//     the pen.  Base glyph cell = pen_x, that y, glyph advance (glyph+W) wide,
//     font size (format+2) tall.  This is read from PutGlyph's own prologue.
//   * Text is shown by a text primitive (`PrimSetText` writes the buffer index
//     to prim+K and the prim type is 5).  The render walk draws a text prim
//     with DrawSprite(ox, oy, prim, text_object + S) where ox/oy are the
//     accumulated group offsets.  DrawSprite composes rotation (prim+0x24),
//     scale (prim+0x26/+0x28, 1000 = 1.0), the UV/WH/3D flag paths (prim+6 bits
//     0..2) and a translation by ox + prim.x + surface+0x518 (oy likewise);
//     with all of those neutral and the surface origin fields zero a surface
//     pixel lands at (ox + prim.x + sx, oy + prim.y + sy) of the design-size
//     back buffer (VM+W x VM+H, read from DrawSprite's own 3D-centre code).
//   * Input: the window procedure turns WM_LBUTTONDOWN / UP into the engine's
//     input state (InputGetDown / InputGetState syscalls); there is no
//     GetAsyncKeyState / DirectInput import, so a swallowed down/up pair never
//     reaches the script.
//
// Every site is proven by a byte shape plus structural cross-checks (the
// syscall registration names, the shared VM global and text-buffer array in
// both the TextPrint handler and the render case, PrimSetText's field in the
// render case).  No hash, file name or title is consulted; anything missing or
// ambiguous installs nothing.

#include <windows.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "exact_lookup_signature.h"
#include "../lookup_line_text_match.h"

namespace fushi_voice_hook::fvp_lookup {

namespace exact = fushi_voice_hook::exact_lookup;

inline constexpr size_t kMaxTextBytes = 512u;   // TextPrint refuses >= 0x200
inline constexpr size_t kMaxUnits = 256u;
inline constexpr size_t kMaxGlyphs = 320u;      // ruby + base glyphs per print
inline constexpr int32_t kMaxCellSide = 256;
inline constexpr int32_t kMinDesignSide = 64;
inline constexpr int32_t kMaxDesignSide = 8192;
inline constexpr uint32_t kTextBufferCount = 32u;  // `cmp eax,0x1f`
inline constexpr int16_t kScaleIdentity = 1000;
inline constexpr uint8_t kPrimTypeText = 5u;
inline constexpr uint8_t kPrimTransformFlags = 0x07u;  // UV / WH / 3D paths

// ── byte shapes ────────────────────────────────────────────────────────────

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

#define FVP_SHAPE(name, ...)                                         \
  inline constexpr uint8_t name##Bytes[] = {__VA_ARGS__};

// TextPrint handler: `cmp eax,0x1f; jg rel32; mov edx,[G]; push ebp;
// mov ebp,[edx+eax*4+A]` — the bounded buffer index and the text array.
inline constexpr uint8_t kBufferLoadBytes[] = {
    0x83, 0xf8, 0x1f, 0x0f, 0x8f, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x15,
    0x00, 0x00, 0x00, 0x00, 0x55, 0x8b, 0xac, 0x82, 0x00, 0x00, 0x00, 0x00};
inline constexpr uint8_t kBufferLoadMask[] = {
    1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0};
inline constexpr Shape kBufferLoad = {kBufferLoadBytes, kBufferLoadMask,
                                      sizeof(kBufferLoadBytes)};
inline constexpr size_t kBufferLoadGlobalByte = 11u;
inline constexpr size_t kBufferLoadArrayByte = 19u;
// `call [imm32]; cmp eax,0x200; jl` — the string length bound.
inline constexpr uint8_t kLengthBoundBytes[] = {0xff, 0x15, 0x00, 0x00, 0x00,
                                                0x00, 0x3d, 0x00, 0x02, 0x00,
                                                0x00, 0x7c};
inline constexpr uint8_t kLengthBoundMask[] = {1, 1, 0, 0, 0, 0,
                                               1, 1, 1, 1, 1, 1};
inline constexpr Shape kLengthBound = {kLengthBoundBytes, kLengthBoundMask,
                                       sizeof(kLengthBoundBytes)};
// `push esi; mov ecx,ebp; call Print` — the string handed to the text object.
inline constexpr uint8_t kPrintCallBytes[] = {0x56, 0x8b, 0xcd, 0xe8,
                                              0x00, 0x00, 0x00, 0x00};
inline constexpr uint8_t kPrintCallMask[] = {1, 1, 1, 1, 0, 0, 0, 0};
inline constexpr Shape kPrintCall = {kPrintCallBytes, kPrintCallMask,
                                     sizeof(kPrintCallBytes)};
inline constexpr size_t kHandlerSpan = 0x140u;

// Print: `push 1; push 0; push 0; mov ecx,edi; call Layout` (lay the whole
// queue out from the start).
inline constexpr uint8_t kLayoutCallBytes[] = {0x6a, 0x01, 0x6a, 0x00, 0x6a,
                                               0x00, 0x8b, 0xcf, 0xe8, 0x00,
                                               0x00, 0x00, 0x00};
inline constexpr uint8_t kLayoutCallMask[] = {1, 1, 1, 1, 1, 1, 1,
                                              1, 1, 0, 0, 0, 0};
inline constexpr Shape kLayoutCall = {kLayoutCallBytes, kLayoutCallMask,
                                      sizeof(kLayoutCallBytes)};
inline constexpr size_t kPrintSpan = 0x140u;
inline constexpr size_t kLayoutSpan = 0xc00u;

// PutGlyph prologue: pen y / glyph advance / pen x fields and the base-glyph
// ruby offset rule (format+2 size, +4 ruby size, +0x14 == 2, +0x24 gap).
inline constexpr uint8_t kPutGlyphBytes[] = {
    0x83, 0xec, 0x14, 0x80, 0x7c, 0x24, 0x20, 0x00, 0x8b, 0x54, 0x24, 0x1c,
    0x0f, 0xbf, 0x81, 0x00, 0x00, 0x00, 0x00,              // movsx eax,[ecx+Y]
    0x53, 0x8b, 0x9a, 0x00, 0x00, 0x00, 0x00,              // mov ebx,[edx+W]
    0x8b, 0x54, 0x24, 0x1c, 0x55, 0x0f, 0xbf, 0xa9,
    0x00, 0x00, 0x00, 0x00,                                // movsx ebp,[ecx+X]
    0x56, 0x57, 0x0f, 0xb6, 0x7a, 0x02,                    // size = fmt+2
    0x89, 0x6c, 0x24, 0x18, 0x89, 0x44, 0x24, 0x10, 0x89, 0x5c, 0x24, 0x14,
    0x74, 0x06, 0x0f, 0xb6, 0x7a, 0x04, 0xeb, 0x18,        // ruby size fmt+4
    0x80, 0x7a, 0x14, 0x02, 0x75, 0x12, 0x0f, 0xbf, 0x72, 0x24,
    0x0f, 0xb6, 0x52, 0x04, 0x03, 0xd0, 0x03, 0xd6};
inline constexpr uint8_t kPutGlyphMask[] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  // prologue, movsx eax,
    0, 0, 0, 0,                                     // Y
    1, 1, 1,                                        // push ebx; mov ebx,
    0, 0, 0, 0,                                     // W
    1, 1, 1, 1, 1, 1, 1, 1,                         // …; movsx ebp,
    0, 0, 0, 0,                                     // X
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
inline constexpr Shape kPutGlyph = {kPutGlyphBytes, kPutGlyphMask,
                                    sizeof(kPutGlyphBytes)};
static_assert(sizeof(kPutGlyphBytes) == sizeof(kPutGlyphMask));
inline constexpr size_t kPutGlyphPenYByte = 15u;
inline constexpr size_t kPutGlyphAdvanceByte = 22u;
inline constexpr size_t kPutGlyphPenXByte = 34u;

// PrimSetText handler: `push 5; push eax; call GetPrim` (text prim type) and
// `cmp ecx,0x1f; jg; mov dx,cx; mov [eax+K],dx` (the buffer-index field).
inline constexpr uint8_t kPrimTypeBytes[] = {0x6a, 0x05, 0x50, 0xe8};
inline constexpr uint8_t kPrimTypeMask[] = {1, 1, 1, 1};
inline constexpr Shape kPrimType = {kPrimTypeBytes, kPrimTypeMask, 4u};
inline constexpr uint8_t kPrimFieldBytes[] = {0x83, 0xf9, 0x1f, 0x7f, 0x00,
                                              0x66, 0x8b, 0xd1, 0x66, 0x89,
                                              0x50, 0x00};
inline constexpr uint8_t kPrimFieldMask[] = {1, 1, 1, 1, 0, 1,
                                             1, 1, 1, 1, 1, 0};
inline constexpr Shape kPrimField = {kPrimFieldBytes, kPrimFieldMask,
                                     sizeof(kPrimFieldBytes)};
inline constexpr size_t kPrimFieldByte = 11u;
inline constexpr size_t kPrimHandlerSpan = 0x80u;

// Render walk, text case: `movsx ecx,[esi+K]; mov eax,[G];
// mov edx,[eax+ecx*4+A]; mov ecx,[esp+d]; add edx,S; push edx;
// mov edx,[esp+d]; push esi; push ecx; mov ecx,[eax+R]; push edx; call Draw`.
inline constexpr uint8_t kRenderTextBytes[] = {
    0x0f, 0xbf, 0x4e, 0x00, 0xa1, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x94, 0x88,
    0x00, 0x00, 0x00, 0x00, 0x8b, 0x4c, 0x24, 0x00, 0x83, 0xc2, 0x00, 0x52,
    0x8b, 0x54, 0x24, 0x00, 0x56, 0x51, 0x8b, 0x88, 0x00, 0x00, 0x00, 0x00,
    0x52, 0xe8, 0x00, 0x00, 0x00, 0x00};
inline constexpr uint8_t kRenderTextMask[] = {
    1, 1, 1, 0, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 1,
    1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0};
inline constexpr Shape kRenderText = {kRenderTextBytes, kRenderTextMask,
                                      sizeof(kRenderTextBytes)};
static_assert(sizeof(kRenderTextBytes) == sizeof(kRenderTextMask));
inline constexpr size_t kRenderTextFieldByte = 3u;
inline constexpr size_t kRenderTextGlobalByte = 5u;
inline constexpr size_t kRenderTextArrayByte = 12u;
inline constexpr size_t kRenderTextSurfaceByte = 22u;
inline constexpr size_t kRenderTextCallByte = 37u;

// DrawSprite(ox, oy, prim, surface) prologue (`push ebp; mov ebp,esp;
// and esp,-8; sub esp,imm32; push ebx; mov ebx,[ebp+0x14];
// cmp byte [ebx+READY],0`).
inline constexpr uint8_t kDrawPrologueBytes[] = {
    0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0x81, 0xec, 0x00, 0x00, 0x00, 0x00,
    0x53, 0x8b, 0x5d, 0x14, 0x80, 0xbb, 0x00, 0x00, 0x00, 0x00, 0x00};
inline constexpr uint8_t kDrawPrologueMask[] = {
    1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1};
inline constexpr Shape kDrawPrologue = {kDrawPrologueBytes, kDrawPrologueMask,
                                        sizeof(kDrawPrologueBytes)};
inline constexpr size_t kDrawReadyByte = 18u;
inline constexpr size_t kDrawSpan = 0x900u;
// The non-flag translation: `mov ebx,[ebp+0x14]; movsx ecx,[ebx+OY];
// add ecx,[ebp+0xc]; movsx edx,[edi+PY]; movsx eax,[ebx+OX]; add eax,[ebp+8];
// add edx,ecx; movsx ecx,[edi+PX]`.
inline constexpr uint8_t kTranslateBytes[] = {
    0x8b, 0x5d, 0x14, 0x0f, 0xbf, 0x8b, 0x00, 0x00, 0x00, 0x00, 0x03, 0x4d,
    0x0c, 0x0f, 0xbf, 0x57, 0x00, 0x0f, 0xbf, 0x83, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x45, 0x08, 0x03, 0xd1, 0x0f, 0xbf, 0x4f, 0x00};
inline constexpr uint8_t kTranslateMask[] = {
    1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0,
    1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0};
inline constexpr Shape kTranslate = {kTranslateBytes, kTranslateMask,
                                     sizeof(kTranslateBytes)};
inline constexpr size_t kTranslateSurfaceYByte = 6u;
inline constexpr size_t kTranslatePrimYByte = 16u;
inline constexpr size_t kTranslateSurfaceXByte = 20u;
inline constexpr size_t kTranslatePrimXByte = 32u;
// Scale identity: `movzx eax,[edi+SX]; mov edx,1000; cmp ax,dx; jne; mov ecx,edx;
// cmp [edi+SY],cx`.
inline constexpr uint8_t kScaleBytes[] = {0x0f, 0xb7, 0x47, 0x00, 0xba, 0xe8,
                                          0x03, 0x00, 0x00, 0x66, 0x3b, 0xc2,
                                          0x75, 0x00, 0x8b, 0xca, 0x66, 0x39,
                                          0x4f, 0x00};
inline constexpr uint8_t kScaleMask[] = {1, 1, 1, 0, 1, 1, 1, 1, 1, 1,
                                         1, 1, 1, 0, 1, 1, 1, 1, 1, 0};
inline constexpr Shape kScale = {kScaleBytes, kScaleMask, sizeof(kScaleBytes)};
inline constexpr size_t kScaleXByte = 3u;
inline constexpr size_t kScaleYByte = 19u;
// Rotation: `movzx eax,[edi+R]` … `test ax,ax; je`.
inline constexpr uint8_t kRotationLoadBytes[] = {0x0f, 0xb7, 0x47, 0x00};
inline constexpr uint8_t kRotationLoadMask[] = {1, 1, 1, 0};
inline constexpr Shape kRotationLoad = {kRotationLoadBytes, kRotationLoadMask,
                                        4u};
inline constexpr uint8_t kRotationTestBytes[] = {0x66, 0x85, 0xc0, 0x74};
inline constexpr size_t kRotationTestWindow = 0x40u;
// The three transform flag tests on prim+6 and the alpha load (prim+7).
inline constexpr uint8_t kFlagTest1[] = {0xf6, 0x47, 0x06, 0x01};
inline constexpr uint8_t kFlagTest2[] = {0xf6, 0x47, 0x06, 0x02};
inline constexpr uint8_t kFlagTest4[] = {0xf6, 0x47, 0x06, 0x04};
inline constexpr uint8_t kAlphaLoad[] = {0x0f, 0xb6, 0x47, 0x07};
// Design size from the 3D centre: `mov ecx,[G]; fldz; mov eax,[ecx+H];
// cdq; sub eax,edx; sar eax,1; mov [esp+d],eax; mov eax,[ecx+W]`.
inline constexpr uint8_t kDesignBytes[] = {
    0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00, 0xd9, 0xee, 0x8b, 0x41, 0x00, 0x99,
    0x2b, 0xc2, 0xd1, 0xf8, 0x89, 0x44, 0x24, 0x00, 0x8b, 0x41, 0x00};
inline constexpr uint8_t kDesignMask[] = {1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1,
                                          1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0};
inline constexpr Shape kDesign = {kDesignBytes, kDesignMask,
                                  sizeof(kDesignBytes)};
inline constexpr size_t kDesignGlobalByte = 2u;
inline constexpr size_t kDesignHeightByte = 10u;
inline constexpr size_t kDesignWidthByte = 22u;

#undef FVP_SHAPE

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
  return image.absolute_base != 0u ? image.absolute_base
                                   : reinterpret_cast<uintptr_t>(image.base);
}

inline uint32_t ReadU32(const uint8_t* at) {
  uint32_t value = 0u;
  std::memcpy(&value, at, sizeof(value));
  return value;
}

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

inline const uint8_t* BytesAt(const exact::LoadedPeImage& image, uintptr_t rva,
                              size_t bytes) {
  if (exact::FindSectionForRva(image, rva, bytes) == nullptr) return nullptr;
  return image.base + rva;
}

// Bytes [rva, rva+span) clipped to the containing section.
inline size_t SpanAt(const exact::LoadedPeImage& image, uintptr_t rva,
                     size_t span) {
  const exact::LoadedPeSection* section =
      exact::FindSectionForRva(image, rva, 1u);
  if (section == nullptr) return 0u;
  const size_t left = section->rva + section->size - rva;
  return left < span ? left : span;
}

template <typename Fn>
void ForEachSection(const exact::LoadedPeImage& image, bool executable,
                    Fn&& fn) {
  for (size_t index = 0u; index < image.section_count; ++index) {
    const exact::LoadedPeSection& section = image.sections[index];
    const bool is_exec =
        (section.characteristics & IMAGE_SCN_MEM_EXECUTE) != 0u;
    if (is_exec != executable || section.bytes == nullptr ||
        section.size == 0u) {
      continue;
    }
    fn(static_cast<uintptr_t>(section.rva), section.bytes, section.size);
  }
}

inline bool DecodeRel32At(const exact::LoadedPeImage& image, uintptr_t at,
                          uintptr_t* target) {
  const uint8_t* bytes = BytesAt(image, at, 5u);
  if (bytes == nullptr || bytes[0] != 0xe8u) return false;
  int32_t rel = 0;
  std::memcpy(&rel, bytes + 1u, sizeof(rel));
  const int64_t value = static_cast<int64_t>(at + 5u) + rel;
  if (value <= 0 || static_cast<uint64_t>(value) >= image.size ||
      !IsExecutableRva(image, static_cast<uintptr_t>(value), 16u)) {
    return false;
  }
  *target = static_cast<uintptr_t>(value);
  return true;
}

// Every match of `shape` in [rva, rva+span); returns the count (offsets of
// the first `capacity` matches are stored).
inline size_t FindShapesIn(const exact::LoadedPeImage& image, uintptr_t rva,
                           size_t span, const Shape& shape, uintptr_t* out,
                           size_t capacity) {
  const size_t size = SpanAt(image, rva, span);
  const uint8_t* bytes = BytesAt(image, rva, size == 0u ? 1u : size);
  if (bytes == nullptr || size < shape.size) return 0u;
  size_t found = 0u;
  for (size_t offset = 0u; offset + shape.size <= size; ++offset) {
    if (!ShapeAt(bytes + offset, bytes + size, shape)) continue;
    if (found < capacity && out != nullptr) out[found] = rva + offset;
    ++found;
  }
  return found;
}

inline bool ContainsBytes(const exact::LoadedPeImage& image, uintptr_t rva,
                          size_t span, const uint8_t* needle, size_t bytes) {
  const size_t size = SpanAt(image, rva, span);
  const uint8_t* begin = BytesAt(image, rva, size == 0u ? 1u : size);
  if (begin == nullptr) return false;
  for (size_t offset = 0u; offset + bytes <= size; ++offset) {
    if (std::memcmp(begin + offset, needle, bytes) == 0) return true;
  }
  return false;
}

// RVA of the unique `<name>\0` string (preceded by NUL) in a read-only data
// section.
inline bool FindUniqueName(const exact::LoadedPeImage& image, const char* name,
                           uintptr_t* rva) {
  const size_t length = std::strlen(name) + 1u;  // with the NUL
  size_t found = 0u;
  uintptr_t at = 0u;
  ForEachSection(image, false,
                 [&](uintptr_t section_rva, const uint8_t* bytes, size_t size) {
                   for (size_t offset = 1u; offset + length <= size;
                        ++offset) {
                     if (bytes[offset - 1u] != 0u ||
                         std::memcmp(bytes + offset, name, length) != 0) {
                       continue;
                     }
                     ++found;
                     at = section_rva + offset;
                   }
                 });
  if (found != 1u) return false;
  *rva = at;
  return true;
}

// ── syscall registration ───────────────────────────────────────────────────

struct Registration {
  uintptr_t register_function = 0u;  // RVA
  uintptr_t handler = 0u;            // RVA
};

enum class RegistrationResult : uint32_t {
  kOk = 0,
  kNameMissing = 1,
  kSiteMissing = 2,
  kSiteAmbiguous = 3,
  kHandlerMissing = 4,
};

// `push imm32(name); mov ecx,r32; call Register`, preceded (within 0x20
// bytes) by `push argc` and `mov r32,handler; …; mov [eax],r32`.
inline RegistrationResult FindRegistration(const exact::LoadedPeImage& image,
                                           const char* name, uint8_t argc,
                                           Registration* out) {
  uintptr_t name_rva = 0u;
  if (!FindUniqueName(image, name, &name_rva)) {
    return RegistrationResult::kNameMissing;
  }
  const uint32_t name_va = RvaToVa(image, name_rva);
  size_t sites = 0u;
  uintptr_t site = 0u;
  uintptr_t call = 0u;
  // The call follows the push within a few bytes (the compiler interleaves
  // the remaining block stores); `mov ecx,r32` (the registry) precedes it.
  constexpr size_t kCallWindow = 12u;
  ForEachSection(
      image, true,
      [&](uintptr_t section_rva, const uint8_t* bytes, size_t size) {
        for (size_t offset = 0u; offset + 5u + kCallWindow + 4u <= size;
             ++offset) {
          if (bytes[offset] != 0x68u ||
              ReadU32(bytes + offset + 1u) != name_va) {
            continue;
          }
          bool this_set = false;
          for (size_t k = offset + 5u; k < offset + 5u + kCallWindow; ++k) {
            if (bytes[k] == 0x8bu && (bytes[k + 1u] & 0xf8u) == 0xc8u) {
              this_set = true;
            }
            if (bytes[k] == 0xe8u && this_set) {
              ++sites;
              site = section_rva + offset;
              call = section_rva + k;
              break;
            }
          }
        }
      });
  if (sites == 0u) return RegistrationResult::kSiteMissing;
  if (sites != 1u) return RegistrationResult::kSiteAmbiguous;
  Registration result;
  if (!DecodeRel32At(image, call, &result.register_function)) {
    return RegistrationResult::kSiteMissing;
  }
  constexpr size_t kWindow = 0x20u;
  if (site < kWindow) return RegistrationResult::kHandlerMissing;
  const uint8_t* window = BytesAt(image, site - kWindow, kWindow);
  if (window == nullptr) return RegistrationResult::kHandlerMissing;
  // `push argc` must be in the window.
  bool argc_seen = false;
  for (size_t k = 0u; k + 2u <= kWindow; ++k) {
    if (window[k] == 0x6au && window[k + 1u] == argc) argc_seen = true;
  }
  if (!argc_seen) return RegistrationResult::kHandlerMissing;
  // The closest `mov r32,imm32` (executable target) whose register is then
  // stored to [eax] before the push.
  for (size_t k = kWindow - 5u + 1u; k-- > 0u;) {
    const uint8_t opcode = window[k];
    if (opcode < 0xb8u || opcode > 0xbfu) continue;
    uintptr_t handler = 0u;
    if (!VaToRva(image, ReadU32(window + k + 1u), &handler) ||
        !IsExecutableRva(image, handler, 16u)) {
      continue;
    }
    const uint8_t reg = static_cast<uint8_t>(opcode - 0xb8u);
    const uint8_t store = static_cast<uint8_t>(reg << 3);  // mod 00, rm eax
    bool stored = false;
    for (size_t j = k + 5u; j + 2u <= kWindow; ++j) {
      if (window[j] == 0x89u && window[j + 1u] == store) stored = true;
    }
    if (!stored) continue;
    result.handler = handler;
    *out = result;
    return RegistrationResult::kOk;
  }
  return RegistrationResult::kHandlerMissing;
}

// ── site resolution ────────────────────────────────────────────────────────

struct Sites {
  uintptr_t text_print_handler = 0u;  // RVA (proof only)
  uintptr_t print = 0u;               // RVA, hooked
  uintptr_t layout = 0u;              // RVA (proof only)
  uintptr_t put_glyph = 0u;           // RVA, hooked
  uintptr_t draw = 0u;                // RVA, hooked
  uintptr_t vm_global = 0u;           // RVA of the VM pointer
  uint32_t text_array = 0u;           // VM + text_array + 4*i → text object
  uint32_t prim_text_field = 0u;      // prim + K: buffer index (i16)
  uint32_t surface_offset = 0u;       // text object + S → drawn surface
  uint32_t surface_ready = 0u;        // surface + R: drawable flag (u8)
  uint32_t surface_origin_x = 0u;     // surface + 0x518 (i16); origin pair
  uint32_t surface_origin_y = 0u;     //   is the next field pair down
  uint32_t pen_x = 0u;                // text object + X (i16)
  uint32_t pen_y = 0u;                // text object + Y (i16)
  uint32_t glyph_advance = 0u;        // glyph + W (i32)
  uint32_t prim_x = 0u;               // prim + 0x14 (i16)
  uint32_t prim_y = 0u;               // prim + 0x16 (i16)
  uint32_t prim_rotation = 0u;        // prim + 0x24 (u16)
  uint32_t prim_scale_x = 0u;         // prim + 0x26 (i16, 1000 = 1.0)
  uint32_t prim_scale_y = 0u;         // prim + 0x28
  uint32_t design_w = 0u;             // VM + W (i32)
  uint32_t design_h = 0u;             // VM + H (i32)
};

enum class SiteResult : uint32_t {
  kResolved = 0,
  kNotX86 = 1,
  kTextPrintMissing = 2,
  kPrimSetTextMissing = 3,
  kRegistrationMismatch = 4,
  kBufferLoadMissing = 5,
  kPrintMissing = 6,
  kLayoutMissing = 7,
  kPutGlyphMissing = 8,
  kPrimFieldMissing = 9,
  kRenderMissing = 10,
  kDrawShape = 11,
  kDesignMissing = 12,
};

inline SiteResult ResolveSites(const exact::LoadedPeImage& image, Sites* out) {
  if (image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u ||
      out == nullptr) {
    return SiteResult::kNotX86;
  }
  Sites sites;
  Registration print_reg;
  if (FindRegistration(image, "TextPrint", 2u, &print_reg) !=
      RegistrationResult::kOk) {
    return SiteResult::kTextPrintMissing;
  }
  Registration prim_reg;
  if (FindRegistration(image, "PrimSetText", 4u, &prim_reg) !=
      RegistrationResult::kOk) {
    return SiteResult::kPrimSetTextMissing;
  }
  if (print_reg.register_function != prim_reg.register_function ||
      print_reg.handler == prim_reg.handler) {
    return SiteResult::kRegistrationMismatch;
  }
  sites.text_print_handler = print_reg.handler;

  // TextPrint handler: buffer array, length bound, Print call.
  uintptr_t hits[2] = {};
  if (FindShapesIn(image, print_reg.handler, kHandlerSpan, kBufferLoad, hits,
                   2u) != 1u) {
    return SiteResult::kBufferLoadMissing;
  }
  const uint8_t* load = BytesAt(image, hits[0], kBufferLoad.size);
  uintptr_t global = 0u;
  if (load == nullptr ||
      !VaToRva(image, ReadU32(load + kBufferLoadGlobalByte), &global) ||
      !IsDataRva(image, global, 4u)) {
    return SiteResult::kBufferLoadMissing;
  }
  sites.vm_global = global;
  sites.text_array = ReadU32(load + kBufferLoadArrayByte);
  if (sites.text_array == 0u || sites.text_array > 0x100000u) {
    return SiteResult::kBufferLoadMissing;
  }
  if (FindShapesIn(image, print_reg.handler, kHandlerSpan, kLengthBound,
                   nullptr, 0u) != 1u ||
      FindShapesIn(image, print_reg.handler, kHandlerSpan, kPrintCall, hits,
                   2u) != 1u ||
      !DecodeRel32At(image, hits[0] + 3u, &sites.print)) {
    return SiteResult::kPrintMissing;
  }

  // Print → Layout → PutGlyph (called at least twice from the layout).
  if (FindShapesIn(image, sites.print, kPrintSpan, kLayoutCall, hits, 2u) !=
          1u ||
      !DecodeRel32At(image, hits[0] + 8u, &sites.layout)) {
    return SiteResult::kLayoutMissing;
  }
  {
    const size_t span = SpanAt(image, sites.layout, kLayoutSpan);
    const uint8_t* bytes = BytesAt(image, sites.layout, span);
    uintptr_t glyph = 0u;
    size_t calls = 0u;
    bool conflict = false;
    for (size_t offset = 0u; bytes != nullptr && offset + 5u <= span;
         ++offset) {
      uintptr_t target = 0u;
      if (bytes[offset] != 0xe8u ||
          !DecodeRel32At(image, sites.layout + offset, &target)) {
        continue;
      }
      const uint8_t* head = BytesAt(image, target, kPutGlyph.size);
      if (head == nullptr || !ShapeAt(head, head + kPutGlyph.size, kPutGlyph)) {
        continue;
      }
      if (glyph != 0u && glyph != target) conflict = true;
      glyph = target;
      ++calls;
    }
    if (glyph == 0u || conflict || calls < 2u) {
      return SiteResult::kPutGlyphMissing;
    }
    const uint8_t* head = BytesAt(image, glyph, kPutGlyph.size);
    sites.put_glyph = glyph;
    sites.pen_y = ReadU32(head + kPutGlyphPenYByte);
    sites.glyph_advance = ReadU32(head + kPutGlyphAdvanceByte);
    sites.pen_x = ReadU32(head + kPutGlyphPenXByte);
    if (sites.pen_x == 0u || sites.pen_x > 0x100000u ||
        sites.pen_y != sites.pen_x + 2u || sites.glyph_advance == 0u ||
        sites.glyph_advance > 0x100000u) {
      return SiteResult::kPutGlyphMissing;
    }
  }

  // PrimSetText: text prim type and buffer-index field.
  if (FindShapesIn(image, prim_reg.handler, kPrimHandlerSpan, kPrimType,
                   nullptr, 0u) != 1u ||
      FindShapesIn(image, prim_reg.handler, kPrimHandlerSpan, kPrimField, hits,
                   2u) != 1u) {
    return SiteResult::kPrimFieldMissing;
  }
  sites.prim_text_field =
      BytesAt(image, hits[0], kPrimField.size)[kPrimFieldByte];

  // Render walk text case: same field, VM global and text array.
  {
    uint8_t bytes[sizeof(kRenderTextBytes)];
    uint8_t mask[sizeof(kRenderTextMask)];
    std::memcpy(bytes, kRenderTextBytes, sizeof(bytes));
    std::memcpy(mask, kRenderTextMask, sizeof(mask));
    bytes[kRenderTextFieldByte] = static_cast<uint8_t>(sites.prim_text_field);
    mask[kRenderTextFieldByte] = 1u;
    const uint32_t global_va = RvaToVa(image, sites.vm_global);
    std::memcpy(bytes + kRenderTextGlobalByte, &global_va, 4u);
    std::memcpy(bytes + kRenderTextArrayByte, &sites.text_array, 4u);
    for (size_t k = 0u; k < 4u; ++k) {
      mask[kRenderTextGlobalByte + k] = 1u;
      mask[kRenderTextArrayByte + k] = 1u;
    }
    const Shape render = {bytes, mask, sizeof(bytes)};
    size_t found = 0u;
    uintptr_t at = 0u;
    ForEachSection(image, true,
                   [&](uintptr_t section_rva, const uint8_t* code, size_t size) {
                     for (size_t offset = 0u; offset + render.size <= size;
                          ++offset) {
                       if (!ShapeAt(code + offset, code + size, render)) {
                         continue;
                       }
                       ++found;
                       at = section_rva + offset;
                     }
                   });
    if (found != 1u ||
        !DecodeRel32At(image, at + kRenderTextCallByte, &sites.draw)) {
      return SiteResult::kRenderMissing;
    }
    sites.surface_offset =
        BytesAt(image, at, render.size)[kRenderTextSurfaceByte];
    if (sites.surface_offset == 0u || sites.surface_offset >= 0x80u) {
      return SiteResult::kRenderMissing;
    }
  }

  // DrawSprite: prologue, translation, scale, rotation, flag paths, alpha.
  {
    const uint8_t* head = BytesAt(image, sites.draw, kDrawPrologue.size);
    if (head == nullptr ||
        !ShapeAt(head, head + kDrawPrologue.size, kDrawPrologue)) {
      return SiteResult::kDrawShape;
    }
    sites.surface_ready = ReadU32(head + kDrawReadyByte);
    if (FindShapesIn(image, sites.draw, kDrawSpan, kTranslate, hits, 2u) !=
        1u) {
      return SiteResult::kDrawShape;
    }
    const uint8_t* translate = BytesAt(image, hits[0], kTranslate.size);
    sites.surface_origin_y = ReadU32(translate + kTranslateSurfaceYByte);
    sites.surface_origin_x = ReadU32(translate + kTranslateSurfaceXByte);
    sites.prim_y = translate[kTranslatePrimYByte];
    sites.prim_x = translate[kTranslatePrimXByte];
    if (sites.surface_origin_y != sites.surface_origin_x + 2u ||
        sites.prim_y != sites.prim_x + 2u || sites.surface_ready == 0u ||
        sites.surface_ready > 0x100000u || sites.surface_origin_x < 4u ||
        sites.surface_origin_x > 0x100000u) {
      return SiteResult::kDrawShape;
    }
    if (FindShapesIn(image, sites.draw, kDrawSpan, kScale, hits, 2u) != 1u) {
      return SiteResult::kDrawShape;
    }
    const uint8_t* scale = BytesAt(image, hits[0], kScale.size);
    sites.prim_scale_x = scale[kScaleXByte];
    sites.prim_scale_y = scale[kScaleYByte];
    // The rotation field is the one loaded right before a `test ax,ax; je`
    // and is neither a scale nor a position field.
    uintptr_t rotations[8] = {};
    const size_t loads = FindShapesIn(image, sites.draw, kDrawSpan,
                                      kRotationLoad, rotations, 8u);
    uint32_t rotation = 0u;
    for (size_t k = 0u; k < loads && k < 8u; ++k) {
      const uint8_t field = BytesAt(image, rotations[k], 4u)[3];
      if (field == sites.prim_scale_x || field == sites.prim_scale_y) continue;
      if (!ContainsBytes(image, rotations[k], kRotationTestWindow,
                         kRotationTestBytes, sizeof(kRotationTestBytes))) {
        continue;
      }
      if (rotation != 0u && rotation != field) return SiteResult::kDrawShape;
      rotation = field;
    }
    sites.prim_rotation = rotation;
    if (rotation == 0u ||
        !ContainsBytes(image, sites.draw, kDrawSpan, kFlagTest1, 4u) ||
        !ContainsBytes(image, sites.draw, kDrawSpan, kFlagTest2, 4u) ||
        !ContainsBytes(image, sites.draw, kDrawSpan, kFlagTest4, 4u) ||
        !ContainsBytes(image, sites.draw, kDrawSpan, kAlphaLoad, 4u)) {
      return SiteResult::kDrawShape;
    }
    if (FindShapesIn(image, sites.draw, kDrawSpan, kDesign, hits, 2u) != 1u) {
      return SiteResult::kDesignMissing;
    }
    const uint8_t* design = BytesAt(image, hits[0], kDesign.size);
    uintptr_t design_global = 0u;
    if (!VaToRva(image, ReadU32(design + kDesignGlobalByte), &design_global) ||
        design_global != sites.vm_global) {
      return SiteResult::kDesignMissing;
    }
    sites.design_h = design[kDesignHeightByte];
    sites.design_w = design[kDesignWidthByte];
    if (sites.design_h != sites.design_w + 4u) {
      return SiteResult::kDesignMissing;
    }
  }
  *out = sites;
  return SiteResult::kResolved;
}

// ── audio: the decoder input of AudioPlay ──────────────────────────────────
//
// `AudioPlay` (argc 2: channel 0..3, loop) loads the channel's audio object
// from the VM's channel array and calls ChannelPlay(this, loop, …).
// ChannelPlay reads the whole named resource into the VM's file buffer
// (`mov eax,[esi+NAME]; mov ecx,[G]; push eax; add ecx,FS; call Load`) and
// hands that memory to the channel's sound object:
// `mov eax,[G]; mov ecx,[eax+SIZE]; mov edx,[eax+BUF]; push ebx; push ecx;
// mov ecx,[esi+SOUND]; push edx; call SoundLoad`.  SoundLoad(this, data,
// size, flag) is the decoder's input: it sniffs RIFF/WAVE or OggS and opens
// the stream from that memory.  The detours copy the bytes SoundLoad receives
// (bounded) together with the channel's resource name; nothing reads the
// archive.

inline constexpr uint8_t kAudioChannelLoadBytes[] = {
    0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x8b, 0x91, 0x00, 0x00, 0x00, 0x00,
    0x8b, 0x8c, 0x82, 0x00, 0x00, 0x00, 0x00};
inline constexpr uint8_t kAudioChannelLoadMask[] = {
    1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0};
inline constexpr Shape kAudioChannelLoad = {kAudioChannelLoadBytes,
                                            kAudioChannelLoadMask,
                                            sizeof(kAudioChannelLoadBytes)};
inline constexpr size_t kAudioChannelLoadGlobalByte = 2u;
inline constexpr uint8_t kAudioChannelBound[] = {0x83, 0xf8, 0x03};
inline constexpr size_t kAudioHandlerSpan = 0x50u;

inline constexpr uint8_t kChannelPlayBytes[] = {
    0x8b, 0x46, 0x00,                          // mov eax,[esi+NAME]
    0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00,        // mov ecx,[G]
    0x50, 0x81, 0xc1, 0x00, 0x00, 0x00, 0x00,  // push eax; add ecx,FS
    0xe8, 0x00, 0x00, 0x00, 0x00,              // call Load
    0xa1, 0x00, 0x00, 0x00, 0x00,              // mov eax,[G]
    0x8b, 0x88, 0x00, 0x00, 0x00, 0x00,        // mov ecx,[eax+SIZE]
    0x8b, 0x90, 0x00, 0x00, 0x00, 0x00,        // mov edx,[eax+BUF]
    0x53, 0x51, 0x8b, 0x4e, 0x00, 0x52,        // push ebx; push ecx;
                                               // mov ecx,[esi+SOUND]; push edx
    0xe8, 0x00, 0x00, 0x00, 0x00};             // call SoundLoad
inline constexpr uint8_t kChannelPlayMask[] = {
    1, 1, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0,
    0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 1, 0, 0, 0,
    0};
inline constexpr Shape kChannelPlay = {kChannelPlayBytes, kChannelPlayMask,
                                       sizeof(kChannelPlayBytes)};
static_assert(sizeof(kChannelPlayBytes) == sizeof(kChannelPlayMask));
inline constexpr size_t kChannelPlayNameByte = 2u;
inline constexpr size_t kChannelPlayGlobalByte = 5u;
inline constexpr size_t kChannelPlayGlobal2Byte = 22u;
inline constexpr size_t kChannelPlaySizeByte = 28u;
inline constexpr size_t kChannelPlayBufferByte = 34u;
inline constexpr size_t kChannelPlaySoundByte = 42u;
inline constexpr size_t kChannelPlayCallByte = 44u;
inline constexpr size_t kChannelPlaySpan = 0x80u;

// SoundLoad: `mov al,[esp+0xc]; mov edx,[esp+4]; mov [ecx+F],al;
// mov eax,[esp+8]; cmp eax,0xc; jb; cmp dword [edx],'RIFF'` … `'OggS'`.
inline constexpr uint8_t kSoundLoadBytes[] = {
    0x8a, 0x44, 0x24, 0x0c, 0x8b, 0x54, 0x24, 0x04, 0x88, 0x41, 0x00,
    0x8b, 0x44, 0x24, 0x08, 0x83, 0xf8, 0x0c, 0x72, 0x00, 0x81, 0x3a,
    0x52, 0x49, 0x46, 0x46};
inline constexpr uint8_t kSoundLoadMask[] = {1, 1, 1, 1, 1, 1, 1, 1, 1,
                                             1, 0, 1, 1, 1, 1, 1, 1, 1,
                                             1, 0, 1, 1, 1, 1, 1, 1};
inline constexpr Shape kSoundLoad = {kSoundLoadBytes, kSoundLoadMask,
                                     sizeof(kSoundLoadBytes)};
inline constexpr uint8_t kSoundLoadOgg[] = {0x81, 0x3a, 0x4f, 0x67, 0x67, 0x53};
inline constexpr size_t kSoundLoadSpan = 0x70u;

struct AudioSites {
  uintptr_t audio_play_handler = 0u;  // RVA (proof only)
  uintptr_t channel_play = 0u;        // RVA, hooked
  uintptr_t sound_load = 0u;          // RVA, hooked
  uint32_t channel_name = 0u;         // channel + NAME: char* resource name
};

enum class AudioSiteResult : uint32_t {
  kResolved = 0,
  kNotX86 = 1,
  kAudioPlayMissing = 2,
  kChannelLoadMissing = 3,
  kChannelPlayMissing = 4,
  kSoundLoadMissing = 5,
};

// `vm_global` is the VM pointer RVA proven by ResolveSites (the same global
// must load the channel array and the file buffer).
inline AudioSiteResult ResolveAudioSites(const exact::LoadedPeImage& image,
                                         uintptr_t vm_global,
                                         AudioSites* out) {
  if (image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u ||
      out == nullptr || vm_global == 0u) {
    return AudioSiteResult::kNotX86;
  }
  const uint32_t global_va = RvaToVa(image, vm_global);
  Registration reg;
  if (FindRegistration(image, "AudioPlay", 2u, &reg) !=
      RegistrationResult::kOk) {
    return AudioSiteResult::kAudioPlayMissing;
  }
  AudioSites sites;
  sites.audio_play_handler = reg.handler;
  uintptr_t hits[2] = {};
  if (FindShapesIn(image, reg.handler, kAudioHandlerSpan, kAudioChannelLoad,
                   hits, 2u) != 1u ||
      ReadU32(BytesAt(image, hits[0], kAudioChannelLoad.size) +
              kAudioChannelLoadGlobalByte) != global_va ||
      !ContainsBytes(image, reg.handler, kAudioHandlerSpan,
                     kAudioChannelBound, sizeof(kAudioChannelBound))) {
    return AudioSiteResult::kChannelLoadMissing;
  }
  // Every call after the channel load goes to one ChannelPlay.
  {
    const size_t span = SpanAt(image, hits[0], kAudioHandlerSpan);
    const uint8_t* bytes = BytesAt(image, hits[0], span);
    uintptr_t target = 0u;
    size_t calls = 0u;
    for (size_t offset = 0u; bytes != nullptr && offset + 5u <= span;
         ++offset) {
      if (bytes[offset] == 0xc2u && offset + 3u <= span &&
          bytes[offset + 1u] == 0x04u && bytes[offset + 2u] == 0x00u &&
          calls > 0u && offset + 3u < span && bytes[offset + 3u] == 0xccu) {
        break;  // end of the handler
      }
      uintptr_t callee = 0u;
      if (bytes[offset] != 0xe8u ||
          !DecodeRel32At(image, hits[0] + offset, &callee)) {
        continue;
      }
      if (target != 0u && target != callee) {
        return AudioSiteResult::kChannelPlayMissing;
      }
      target = callee;
      ++calls;
    }
    if (target == 0u) return AudioSiteResult::kChannelPlayMissing;
    sites.channel_play = target;
  }
  if (FindShapesIn(image, sites.channel_play, kChannelPlaySpan, kChannelPlay,
                   hits, 2u) != 1u) {
    return AudioSiteResult::kChannelPlayMissing;
  }
  const uint8_t* play = BytesAt(image, hits[0], kChannelPlay.size);
  const uint32_t size_field = ReadU32(play + kChannelPlaySizeByte);
  const uint32_t buffer_field = ReadU32(play + kChannelPlayBufferByte);
  if (ReadU32(play + kChannelPlayGlobalByte) != global_va ||
      ReadU32(play + kChannelPlayGlobal2Byte) != global_va ||
      size_field != buffer_field + 4u ||
      !DecodeRel32At(image, hits[0] + kChannelPlayCallByte,
                     &sites.sound_load)) {
    return AudioSiteResult::kChannelPlayMissing;
  }
  sites.channel_name = play[kChannelPlayNameByte];
  const uint8_t* head = BytesAt(image, sites.sound_load, kSoundLoad.size);
  if (head == nullptr || !ShapeAt(head, head + kSoundLoad.size, kSoundLoad) ||
      !ContainsBytes(image, sites.sound_load, kSoundLoadSpan, kSoundLoadOgg,
                     sizeof(kSoundLoadOgg))) {
    return AudioSiteResult::kSoundLoadMissing;
  }
  *out = sites;
  return AudioSiteResult::kResolved;
}

// Storage name for a decoded resource: the engine's resource name
// (`voice/02000750`) with path separators flattened, plus `.ogg`.  Only
// identifier-like bytes survive; an empty name falls back to `voice`.
inline size_t AudioStorageName(const char* name, size_t name_bytes,
                               wchar_t* out, size_t out_chars) {
  if (out == nullptr || out_chars < 10u) return 0u;
  size_t written = 0u;
  for (size_t index = 0u; name != nullptr && index < name_bytes &&
                          name[index] != 0 && written + 5u < out_chars;
       ++index) {
    const char c = name[index];
    const bool keep = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                      (c >= 'a' && c <= 'z') || c == '_' || c == '-';
    out[written++] = keep ? static_cast<wchar_t>(c) : L'_';
  }
  if (written == 0u) {
    const wchar_t fallback[] = L"voice";
    for (const wchar_t* c = fallback; *c != 0; ++c) out[written++] = *c;
  }
  const wchar_t extension[] = L".ogg";
  for (const wchar_t* c = extension; *c != 0; ++c) out[written++] = *c;
  out[written] = 0;
  return written;
}

// Voice ↔ dialogue binding by script order.
//
// TextPrint and AudioPlay are both VM syscalls on the game thread, so the
// Print and ChannelPlay detours take their position from one shared step
// counter: the order the script executed them in.  The VM runs a batch of
// instructions per frame and stops at the click wait; the engine then draws.
// A "dispatch" is the run of steps between two draws: the detours record the
// draw counter as the step's epoch, and two steps with the same epoch ran in
// the same dispatch (no frame was drawn between them).  One line's voice and
// its dialogue print run in one dispatch — whichever the script orders first
// (`AudioPlay; TextPrint` or `TextPrint; AudioPlay`) — while the next line
// only starts after a click wait, i.e. after frames were drawn.
struct PublishedText {
  uint64_t event = 0u;
  uint64_t thread = 0u;
  uint64_t tick = 0u;
  uint64_t step = 0u;   // script position of the print
  uint64_t epoch = 0u;  // draws counted when it ran (its dispatch)
};

struct VoiceOrder {
  uint64_t tick = 0u;
  uint64_t step = 0u;
  uint64_t epoch = 0u;
};

struct DispatchBinding {
  uint64_t event = 0u;
  // The dispatch has been decided: either a dialogue print of the same
  // dispatch was found, or the dispatch ended (a frame was drawn after it)
  // without one.  While false a print of the same dispatch may still come.
  bool settled = false;
};

// The dialogue print (selected lane) that ran in the same dispatch as the
// voice: the first one after the voice in script order (the usual
// `AudioPlay; TextPrint`), else — once the dispatch has ended — the last one
// before it (`TextPrint; AudioPlay`).  A print of another dispatch is never
// taken here: that is another line.
inline DispatchBinding BindVoiceInDispatch(const PublishedText* texts,
                                           size_t count,
                                           const VoiceOrder& voice,
                                           uint64_t selected_thread,
                                           uint64_t current_epoch) {
  DispatchBinding binding;
  const bool dispatch_ended = current_epoch != voice.epoch;
  if (texts == nullptr || selected_thread == 0u || voice.step == 0u) {
    binding.settled = dispatch_ended;
    return binding;
  }
  uint64_t after_event = 0u, after_step = 0u;
  uint64_t before_event = 0u, before_step = 0u;
  for (size_t index = 0u; index < count; ++index) {
    const PublishedText& text = texts[index];
    if (text.event == 0u || text.thread != selected_thread ||
        text.epoch != voice.epoch || text.step == 0u) {
      continue;
    }
    if (text.step > voice.step) {
      if (after_event == 0u || text.step < after_step) {
        after_event = text.event;
        after_step = text.step;
      }
    } else if (text.step < voice.step) {
      if (before_event == 0u || text.step > before_step) {
        before_event = text.event;
        before_step = text.step;
      }
    }
  }
  if (after_event != 0u) {
    binding.event = after_event;
    binding.settled = true;
    return binding;
  }
  if (!dispatch_ended) return binding;  // a following print may still come
  binding.event = before_event;
  binding.settled = true;
  return binding;
}

// Fallback when the voice's dispatch printed no dialogue (a script that waits
// a few frames between AudioPlay and TextPrint): the first dialogue print
// after the voice in script order, published within `window_ms` of it.  A
// print that ran before the voice — the previous line — is never taken.
inline uint64_t BindVoiceToFollowingText(const PublishedText* texts,
                                         size_t count, const VoiceOrder& voice,
                                         uint64_t selected_thread,
                                         uint64_t window_ms) {
  if (texts == nullptr || selected_thread == 0u || voice.step == 0u) {
    return 0u;
  }
  uint64_t best_event = 0u;
  uint64_t best_step = 0u;
  for (size_t index = 0u; index < count; ++index) {
    const PublishedText& text = texts[index];
    if (text.event == 0u || text.thread != selected_thread ||
        text.step <= voice.step ||
        (text.tick > voice.tick && text.tick - voice.tick > window_ms)) {
      continue;
    }
    if (best_event == 0u || text.step < best_step) {
      best_event = text.event;
      best_step = text.step;
    }
  }
  return best_event;
}

// ── CP932 line with inline ruby ────────────────────────────────────────────

inline bool IsCp932Lead(uint8_t byte) {
  return (byte >= 0x81u && byte <= 0x9fu) || (byte >= 0xe0u && byte <= 0xfcu);
}

struct TextUnit {
  uint16_t offset = 0u;  // byte offset in the line
  uint8_t length = 0u;   // 1 or 2 CP932 bytes
  bool ruby = false;     // a ruby reading glyph, not part of the line text
};

struct ParsedLine {
  uint32_t count = 0u;       // displayed units (ruby + base/plain)
  uint32_t text_units = 0u;  // units that are line text (not ruby)
  uint32_t ruby_units = 0u;
  bool malformed = false;    // unbalanced `[ … | … ]`
  bool truncated = false;    // more units than kMaxUnits
  std::array<TextUnit, kMaxUnits> units{};
};

// `[ruby|base]` is the engine's inline ruby: the ruby characters are drawn as
// small glyphs above, the base characters are the line text.  Outside a ruby
// group every character is displayed and is line text.
inline ParsedLine ParseLine(const uint8_t* bytes, size_t length) {
  ParsedLine out;
  enum { kPlain, kRuby, kBase } state = kPlain;
  size_t at = 0u;
  while (at < length && bytes[at] != 0u) {
    const uint8_t byte = bytes[at];
    if (byte == '[' && state == kPlain) {
      state = kRuby;
      ++at;
      continue;
    }
    if (byte == '|' && state == kRuby) {
      state = kBase;
      ++at;
      continue;
    }
    if (byte == ']' && state == kBase) {
      state = kPlain;
      ++at;
      continue;
    }
    if (byte == '[' || byte == ']' || (byte == '|' && state != kPlain)) {
      out.malformed = true;
      return out;
    }
    uint8_t unit_length = 1u;
    if (IsCp932Lead(byte)) {
      if (at + 1u >= length || bytes[at + 1u] == 0u) {
        out.malformed = true;
        return out;
      }
      unit_length = 2u;
    }
    if (out.count >= kMaxUnits) {
      out.truncated = true;
      return out;
    }
    TextUnit& unit = out.units[out.count++];
    unit.offset = static_cast<uint16_t>(at);
    unit.length = unit_length;
    unit.ruby = state == kRuby;
    if (unit.ruby) {
      ++out.ruby_units;
    } else {
      ++out.text_units;
    }
    at += unit_length;
  }
  if (state != kPlain) out.malformed = true;
  return out;
}

// ── page glyphs ────────────────────────────────────────────────────────────

inline constexpr uint16_t kNoSource = 0xffffu;

// What the PutGlyph detour copies before the engine moves the pen.
struct GlyphRecord {
  uint8_t ruby = 0u;
  int16_t pen_x = 0;
  int16_t pen_y = 0;
  int32_t advance = 0;
  uint8_t size = 0u;        // format+2
  uint8_t ruby_size = 0u;   // format+4
  uint8_t ruby_mode = 0u;   // format+0x14
  int16_t ruby_gap = 0;     // format+0x24
};

struct Cell {
  int32_t x = 0;  // surface pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

// The cell PutGlyph blends a base glyph into (see the engine facts).
inline bool BaseGlyphCell(const GlyphRecord& record, Cell* out) {
  if (record.ruby != 0u || record.advance <= 0 ||
      record.advance > kMaxCellSide || record.size == 0u) {
    return false;
  }
  Cell cell;
  cell.x = record.pen_x;
  cell.y = record.pen_y;
  if (record.ruby_mode == 2u) cell.y += record.ruby_size + record.ruby_gap;
  cell.w = record.advance;
  cell.h = record.size;
  *out = cell;
  return true;
}

struct LineGlyph {
  uint32_t codepoint = 0u;
  int32_t x = 0;  // design pixels
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
  uint16_t source_index = kNoSource;
  uint8_t source_length = 0u;
};

// Pairs the parsed line with the glyph records PutGlyph saw during the same
// Print: the records must be exactly the displayed units in order (ruby flag
// equal unit by unit), and every line-text unit gets the cell of its base
// glyph.  `codepoints[i]` / `sources[i]` describe text unit i (in line-text
// order).  Returns the number of cells written (== text_units), or 0 when the
// print cannot be mapped.
inline size_t PairLineGlyphs(const ParsedLine& line,
                             const GlyphRecord* records, size_t record_count,
                             Cell* cells, size_t capacity) {
  if (line.malformed || line.truncated || records == nullptr ||
      cells == nullptr || line.count == 0u || record_count != line.count ||
      line.text_units > capacity) {
    return 0u;
  }
  size_t written = 0u;
  for (size_t index = 0u; index < line.count; ++index) {
    const bool ruby = records[index].ruby != 0u;
    if (ruby != line.units[index].ruby) return 0u;
    if (ruby) continue;
    if (!BaseGlyphCell(records[index], &cells[written])) return 0u;
    ++written;
  }
  return written == line.text_units ? written : 0u;
}

inline bool CellPlausible(const Cell& cell) {
  return cell.w > 0 && cell.h > 0 && cell.w <= kMaxCellSide &&
         cell.h <= kMaxCellSide && cell.x >= 0 && cell.x < kMaxDesignSide &&
         cell.y >= 0 && cell.y < kMaxDesignSide;
}

inline size_t BuildPageGlyphs(const Cell* cells, size_t count,
                              const uint32_t* codepoints,
                              const uint16_t* sources, int32_t origin_x,
                              int32_t origin_y, LineGlyph* out,
                              size_t capacity) {
  if (cells == nullptr || codepoints == nullptr || sources == nullptr ||
      out == nullptr || count == 0u || count > capacity) {
    return 0u;
  }
  for (size_t index = 0u; index < count; ++index) {
    if (!CellPlausible(cells[index])) return 0u;
    LineGlyph& glyph = out[index];
    glyph.codepoint = codepoints[index];
    glyph.x = origin_x + cells[index].x;
    glyph.y = origin_y + cells[index].y;
    glyph.w = cells[index].w;
    glyph.h = cells[index].h;
    glyph.source_index = sources[index];
    glyph.source_length = sources[index] == kNoSource ? 0u : 1u;
  }
  return count;
}

// The selected line is matched as the render-order suffix of the print
// (whitespace-insensitive); every character of it must be a glyph.  Glyphs
// before the match stay unmapped.  Returns the first mapped index, or `count`.
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

// ── draw state ─────────────────────────────────────────────────────────────

// What the DrawSprite detour copies when it draws a watched text surface.
struct DrawState {
  int32_t ox = 0;
  int32_t oy = 0;
  int16_t prim_x = 0;
  int16_t prim_y = 0;
  uint8_t flags = 0u;
  uint8_t alpha = 0u;
  uint16_t rotation = 0u;
  int16_t scale_x = 0;
  int16_t scale_y = 0;
  uint8_t ready = 0u;
  int16_t surface_origin[4] = {};  // origin x/y, offset x/y
};

// Where surface pixel (0,0) lands on the design back buffer, when the draw is
// a plain visible translation; false for any other transform.
inline bool DrawOrigin(const DrawState& state, int32_t* x, int32_t* y) {
  if (state.ready == 0u || state.alpha == 0u ||
      (state.flags & kPrimTransformFlags) != 0u || state.rotation != 0u ||
      state.scale_x != kScaleIdentity || state.scale_y != kScaleIdentity ||
      state.surface_origin[0] != 0 || state.surface_origin[1] != 0 ||
      state.surface_origin[2] != 0 || state.surface_origin[3] != 0) {
    return false;
  }
  *x = state.ox + state.prim_x;
  *y = state.oy + state.prim_y;
  return *x > -kMaxDesignSide && *x < kMaxDesignSide &&
         *y > -kMaxDesignSide && *y < kMaxDesignSide;
}

inline bool DesignPlausible(int32_t w, int32_t h) {
  return w >= kMinDesignSide && h >= kMinDesignSide && w <= kMaxDesignSide &&
         h <= kMaxDesignSide;
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
// so the engine's input state never sees the click.
//
// Input coverage: only WM_LBUTTON* is decided here.  A Windows touch tap that
// the engine does not handle as WM_POINTER* (it forwards those to
// DefWindowProc) is promoted by the system to back-to-back WM_LBUTTONDOWN /
// WM_LBUTTONUP on lift, so a tap reaches this decision like a mouse click.
// A long press is promoted to a right click (WM_RBUTTON*) and a swipe to
// WM_POINTERUPDATE / a promoted drag; neither is claimed — they reach the
// engine unchanged.  None of this is verified with real touch input yet.
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

// ── is the model still what is on screen? ─────────────────────────────────

// The engine draws only while something changes and may stop drawing while
// it is not foreground (a lookup card is up), so "drawn recently" is not a
// time.  The Draw detour counts every primitive drawn; the watched text
// surface is off screen once the engine drew more than about two of its own
// draw periods of other primitives without it (the render walk skips an
// inactive group entirely).  The period is the draw count between the last
// two draws of the watched surface, bounded so that one long absence cannot
// make the gate lenient for long.  A static screen (no draws at all) keeps
// the model.
inline constexpr uint64_t kMinStaleDraws = 64u;
inline constexpr uint64_t kMaxStaleDraws = 1024u;

inline bool WatchedSurfaceDrawn(uint64_t draws_now, uint64_t watched_at,
                                uint64_t watched_period) {
  if (watched_at == 0u || draws_now < watched_at) return false;
  uint64_t limit = watched_period > kMaxStaleDraws / 2u ? kMaxStaleDraws
                                                         : 2u * watched_period;
  if (limit < kMinStaleDraws) limit = kMinStaleDraws;
  return draws_now - watched_at <= limit;
}

// Prints counted per text buffer: only a print on the model's own buffer
// invalidates it (a HUD or name-plate buffer printing does not).  `buffer`
// outside [0, kTextBufferCount) counts nowhere.
// One writer (the game thread's Print detour), any reader.
class BufferPrintCounts {
 public:
  uint64_t Note(int32_t buffer) {
    if (buffer < 0 || buffer >= static_cast<int32_t>(kTextBufferCount)) {
      return 0u;
    }
    return counts_[static_cast<size_t>(buffer)].fetch_add(
               1u, std::memory_order_acq_rel) +
           1u;
  }
  uint64_t Of(int32_t buffer) const {
    if (buffer < 0 || buffer >= static_cast<int32_t>(kTextBufferCount)) {
      return 0u;
    }
    return counts_[static_cast<size_t>(buffer)].load(
        std::memory_order_acquire);
  }

 private:
  std::array<std::atomic<uint64_t>, kTextBufferCount> counts_{};
};

// ── which window to hook ───────────────────────────────────────────────────

// A rejection is bound to the window set it was made for, never permanent: a
// splash / movie window or an ambiguous moment is rejected only until the
// candidate changes (a destroyed and recreated window has another HWND — the
// handle's upper word is the window manager's reuse counter).  A hooked
// window procedure stays hooked for the process; a new window of an already
// hooked procedure is only re-bound.
inline constexpr uint32_t kMaxWindowProcedures = 4u;

struct WindowCandidate {
  uint64_t identity = 0u;  // 0 = no candidate window yet
  uintptr_t window = 0u;
  uint32_t procedure_count = 0u;  // in-image procedures (frame + children)
  uintptr_t procedures[kMaxWindowProcedures] = {};
  bool acceptable = false;  // the candidate passes the identity checks
};

struct WindowBindingState {
  uintptr_t bound = 0u;          // window currently bound (0 = none)
  bool bound_alive = false;      // it still exists and is visible
  uint64_t rejected_identity = 0u;
  uint32_t hooked_count = 0u;
  uintptr_t hooked[kMaxWindowProcedures] = {};
};

enum class WindowStep : uint32_t {
  kKeep = 0,       // the bound window is alive
  kWait = 1,       // nothing (new) to evaluate
  kReject = 2,     // remember this candidate's identity as rejected
  kBind = 3,       // every procedure is hooked already: bind the window
  kHook = 4,       // hook the missing procedures, then bind
};

inline bool WindowProcedureHooked(const WindowBindingState& state,
                                  uintptr_t procedure) {
  for (uint32_t k = 0u; k < state.hooked_count && k < kMaxWindowProcedures;
       ++k) {
    if (state.hooked[k] == procedure) return true;
  }
  return false;
}

inline WindowStep DecideWindowStep(const WindowCandidate& candidate,
                                   const WindowBindingState& state) {
  if (state.bound != 0u && state.bound_alive) return WindowStep::kKeep;
  if (candidate.identity == 0u) return WindowStep::kWait;
  if (candidate.identity == state.rejected_identity) return WindowStep::kWait;
  if (!candidate.acceptable || candidate.procedure_count == 0u ||
      candidate.procedure_count > kMaxWindowProcedures) {
    return WindowStep::kReject;
  }
  uint32_t missing = 0u;
  for (uint32_t k = 0u; k < candidate.procedure_count; ++k) {
    if (!WindowProcedureHooked(state, candidate.procedures[k])) ++missing;
  }
  if (missing == 0u) return WindowStep::kBind;
  if (state.hooked_count + missing > kMaxWindowProcedures) {
    return WindowStep::kReject;
  }
  return WindowStep::kHook;
}

// ── published models ───────────────────────────────────────────────────────

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

}  // namespace fushi_voice_hook::fvp_lookup
