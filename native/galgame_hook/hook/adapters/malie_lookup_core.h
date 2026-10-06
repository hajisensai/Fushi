#pragma once

// Malie (light / Greenwood) message text + in-game lookup: pure, unit-tested
// half.
//
// Engine facts (x86 MSVC; measured 2026-10-03 on the 2016 build of
// Dies irae ~Interview with Kaziklu Bey~, never an identity input):
//   * Scene-graph node classes register a method table built on the stack of
//     a small function: the class name (UTF-16 literal) is copied in word by
//     word and the methods are stored as `mov [ebp+d], imm32`, then the table
//     goes to the class registrar.  The text node class is "RICHTEXT3D".
//   * One RICHTEXT3D method draws the node every frame (node, parent world
//     matrix).  Its data object is node+D (0x1c) and holds the laid-out page:
//       +G glyph records (0x84; stride 0x34: +0 UTF-16 code unit,
//          +4/+8/+0xc/+0x10 left/top/right/bottom in node-local pixels)
//       +C glyph count (0x88)        +V per-glyph texture pointers (0x8c)
//       +R0/+R1 reveal range [start,end) (0xa4/0xa8)
//       +T  translation x,y,z floats (0x90/0x94/0x98)
//     and the method composes world = Translate(T) * parent before drawing
//     the glyph quads.  The loop recognises U+2015 runs (`cmp word ptr
//     [glyph+stride], 0x2015`), which pins the record stride.
//   * Everything is decoded from the draw method's own bytes; any other shape
//     resolves nothing.

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

#include "malie_engine_io_core.h"

namespace fushi_voice_hook::malie_lookup {

namespace exact = fushi_voice_hook::exact_lookup;
namespace mio = fushi_voice_hook::malie_io;

inline constexpr wchar_t kTextClassName[] = L"RICHTEXT3D";
inline constexpr size_t kClassTableScan = 0x80u;
inline constexpr size_t kMaxMethods = 16u;
inline constexpr size_t kDrawScan = 0x500u;

struct DrawSites {
  uintptr_t draw = 0u;       // mapped
  uint32_t data_field = 0u;  // node -> page data
  uint32_t glyphs = 0u;      // page data -> glyph record array
  uint32_t count = 0u;       // page data -> glyph count
  uint32_t textures = 0u;    // page data -> per-glyph texture array
  uint32_t stride = 0u;      // glyph record size
  uint32_t reveal_start = 0u;
  uint32_t reveal_end = 0u;
  uint32_t translate = 0u;   // page data -> float x,y,z
};

enum class DrawResult : uint32_t {
  kResolved = 0,
  kNotX86 = 1,
  kNoClassName = 2,
  kNoClassTable = 3,
  kNoDrawMethod = 4,
  kAmbiguousDrawMethod = 5,
  kRevealShape = 6,
  kTranslateShape = 7,
};

// Methods stored by the class-table function around one name copy: every
// `c7 45 disp8 imm32` from the frame prologue to the next ret whose value is
// a frame function of the image.
inline std::vector<size_t> ClassMethods(const exact::LoadedPeImage& image,
                                        size_t copy) {
  std::vector<size_t> methods;
  size_t prologue = SIZE_MAX;
  for (size_t back = 0u; back <= mio::kPrologueBackScan && back <= copy;
       ++back) {
    if (mio::HasFramePrologue(image, copy - back)) {
      prologue = copy - back;
      break;
    }
  }
  if (prologue == SIZE_MAX) return methods;
  const size_t end = (std::min)(image.size, copy + kClassTableScan);
  for (size_t at = prologue; at + 7u <= end; ++at) {
    const uint8_t* p = image.base + at;
    if (p[0] != 0xc7u || p[1] != 0x45u) continue;
    size_t target = 0u;
    if (mio::AbsoluteToRva(image, mio::Load32(p + 3u), &target) &&
        mio::HasFramePrologue(image, target) &&
        methods.size() < kMaxMethods) {
      methods.push_back(target);
    }
  }
  return methods;
}

// Loop head of the glyph pass (masked):
//   8b 81 C32          mov eax,[ecx+C]       ; glyph count
//   89 45 ??           mov [ebp-x],eax
//   85 c0 0f 8e ????   test eax,eax; jle
inline constexpr uint8_t kCountBytes[] = {0x8b, 0x81, 0, 0, 0, 0, 0x89, 0x45,
                                          0,    0x85, 0xc0, 0x0f, 0x8e};
inline constexpr uint8_t kCountMask[] = {1, 1, 0, 0, 0, 0, 1, 1,
                                         0, 1, 1, 1, 1};
//   8b 81 V32          mov eax,[ecx+V]       ; texture array
//   83 3c b0 00        cmp dword ptr [eax+esi*4],0
//   0f 84 ????         je
//   8b 91 G32          mov edx,[ecx+G]       ; glyph records
//   66 39 1c 3a        cmp word ptr [edx+edi],bx   (bx = 0x2015)
inline constexpr uint8_t kGlyphBytes[] = {
    0x8b, 0x81, 0, 0, 0, 0, 0x83, 0x3c, 0xb0, 0x00, 0x0f, 0x84, 0, 0,
    0,    0,    0x8b, 0x91, 0, 0, 0, 0, 0x66, 0x39, 0x1c, 0x3a};
inline constexpr uint8_t kGlyphMask[] = {1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0,
                                         0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1};
// `66 81 7c 3a S8 15 20`: cmp word ptr [edx+edi+stride],0x2015
inline constexpr uint8_t kStrideBytes[] = {0x66, 0x81, 0x7c, 0x3a,
                                           0,    0x15, 0x20};
inline constexpr uint8_t kStrideMask[] = {1, 1, 1, 1, 0, 1, 1};

inline bool MatchAt(const uint8_t* p, const uint8_t* bytes, const uint8_t* mask,
                    size_t size) {
  for (size_t i = 0u; i < size; ++i) {
    if (mask[i] != 0u && p[i] != bytes[i]) return false;
  }
  return true;
}

// Decodes one candidate draw method; false unless the whole shape is there.
inline bool DecodeDraw(const exact::LoadedPeImage& image, size_t method,
                       DrawSites* out, DrawResult* why) {
  size_t end = (std::min)(image.size, method + kDrawScan);
  if (!mio::ExecutableAt(image, method, end - method)) return false;
  const uint8_t* base = image.base;
  // The method body ends at the int3 padding before the next function.
  for (size_t at = method; at + 2u <= end; ++at) {
    if (base[at] == 0xccu && base[at + 1u] == 0xccu) {
      end = at;
      break;
    }
  }
  size_t count_at = SIZE_MAX;
  for (size_t at = method; at + sizeof(kCountBytes) <= end; ++at) {
    if (MatchAt(base + at, kCountBytes, kCountMask, sizeof(kCountBytes))) {
      count_at = at;  // the last loop head wins (the debug pass comes first)
    }
  }
  if (count_at == SIZE_MAX) return false;
  size_t glyph_at = SIZE_MAX;
  for (size_t at = count_at; at + sizeof(kGlyphBytes) <= end &&
                             at <= count_at + 0x40u;
       ++at) {
    if (MatchAt(base + at, kGlyphBytes, kGlyphMask, sizeof(kGlyphBytes))) {
      glyph_at = at;
      break;
    }
  }
  if (glyph_at == SIZE_MAX) return false;
  // The data object: `mov ecx,[reg+D]` (8b 4b/4e D8) right before the head.
  uint32_t data_field = 0u;
  for (size_t at = count_at > 8u ? count_at - 8u : 0u; at + 3u <= count_at;
       ++at) {
    if (base[at] == 0x8bu && (base[at + 1u] & 0xf8u) == 0x48u &&
        (base[at + 1u] & 0x07u) != 0x04u && (base[at + 1u] & 0x07u) != 0x05u) {
      data_field = base[at + 2u];
    }
  }
  // `mov ebx,0x2015` between the head and the glyph compare.
  bool dash = false;
  for (size_t at = count_at; at + 5u <= glyph_at; ++at) {
    dash = dash || (base[at] == 0xbbu && mio::Load32(base + at + 1u) == 0x2015u);
  }
  size_t stride_at = SIZE_MAX;
  for (size_t at = glyph_at; at + sizeof(kStrideBytes) <= end &&
                             at <= glyph_at + 0x30u;
       ++at) {
    if (MatchAt(base + at, kStrideBytes, kStrideMask, sizeof(kStrideBytes))) {
      stride_at = at;
      break;
    }
  }
  if (data_field == 0u || !dash || stride_at == SIZE_MAX) return false;
  DrawSites sites;
  sites.data_field = data_field;
  sites.count = mio::Load32(base + count_at + 2u);
  sites.textures = mio::Load32(base + glyph_at + 2u);
  sites.glyphs = mio::Load32(base + glyph_at + 18u);
  sites.stride = base[stride_at + 4u];
  // Reveal range: the first `cmp esi,[ecx+A]` after the glyph compare and a
  // later `cmp esi,[ecx+A+4]` (3b b1 imm32).
  size_t reveal_at = SIZE_MAX;
  for (size_t at = glyph_at; at + 6u <= end; ++at) {
    if (base[at] == 0x3bu && base[at + 1u] == 0xb1u) {
      reveal_at = at;
      break;
    }
  }
  if (reveal_at == SIZE_MAX) {
    *why = DrawResult::kRevealShape;
    return false;
  }
  sites.reveal_start = mio::Load32(base + reveal_at + 2u);
  bool reveal_end = false;
  for (size_t at = reveal_at + 6u; at + 6u <= end && at <= reveal_at + 0x20u;
       ++at) {
    reveal_end = reveal_end ||
                 (base[at] == 0x3bu && base[at + 1u] == 0xb1u &&
                  mio::Load32(base + at + 2u) == sites.reveal_start + 4u);
  }
  if (!reveal_end) {
    *why = DrawResult::kRevealShape;
    return false;
  }
  sites.reveal_end = sites.reveal_start + 4u;
  // Translation: three `movss xmm0,[eax+T+k]` (f3 0f 10 80 imm32) before the
  // first loop head, k = 8, 4, 0.
  uint32_t loads[3] = {};
  size_t found = 0u;
  for (size_t at = method; at + 8u <= count_at && found < 3u; ++at) {
    if (base[at] == 0xf3u && base[at + 1u] == 0x0fu && base[at + 2u] == 0x10u &&
        base[at + 3u] == 0x80u) {
      loads[found++] = mio::Load32(base + at + 4u);
    }
  }
  if (found != 3u || loads[1] + 4u != loads[0] || loads[2] + 4u != loads[1]) {
    *why = DrawResult::kTranslateShape;
    return false;
  }
  sites.translate = loads[2];
  if (sites.stride < 0x14u || sites.count == 0u || sites.glyphs == 0u ||
      sites.count >= 0x1000u || sites.glyphs >= 0x1000u ||
      sites.textures >= 0x1000u || sites.reveal_start >= 0x1000u ||
      sites.translate >= 0x1000u) {
    return false;
  }
  sites.draw = reinterpret_cast<uintptr_t>(image.base) + method;
  *out = sites;
  return true;
}

inline DrawResult ResolveDraw(const exact::LoadedPeImage& image,
                              DrawSites* out) {
  *out = DrawSites();
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u) {
    return DrawResult::kNotX86;
  }
  const auto literals = mio::FindWideLiteral(image, kTextClassName);
  if (literals.empty()) return DrawResult::kNoClassName;
  std::vector<size_t> copies;
  for (size_t literal : literals) {
    for (size_t copy : mio::FindNameCopies(image, literal)) {
      copies.push_back(copy);
    }
  }
  if (copies.size() != 1u) return DrawResult::kNoClassTable;
  const auto methods = ClassMethods(image, copies[0]);
  if (methods.empty()) return DrawResult::kNoClassTable;
  DrawResult why = DrawResult::kNoDrawMethod;
  size_t matches = 0u;
  DrawSites sites;
  for (size_t method : methods) {
    DrawSites candidate;
    if (DecodeDraw(image, method, &candidate, &why)) {
      if (matches == 0u || candidate.draw != sites.draw) ++matches;
      sites = candidate;
    }
  }
  if (matches == 0u) return why;
  if (matches != 1u) return DrawResult::kAmbiguousDrawMethod;
  *out = sites;
  return DrawResult::kResolved;
}

// ── segment lane: parser and reveal setter ─────────────────────────────────
//
// The message window advances one click unit at a time.  Its progress
// function asks the segment parser for the next unit of the formatted page
// text: `end = parse(page, start, &glyphs)` returns the end index of the unit
// and the number of glyphs it adds, then hands [shown, shown + glyphs) to the
// text node's reveal setter `set_reveal(node, shown, shown + glyphs)`.  The
// parser has exactly that one caller.

// set_reveal(node, start, end):
//   push ebp; mov ebp,esp; mov edx,[ebp+8]; test edx,edx; je +x;
//   mov ecx,[edx+D]; mov eax,[ebp+0xc]; mov [ecx+R0],eax;
//   mov ecx,[edx+D]; mov eax,[ebp+0x10]; mov [ecx+R1],eax; pop ebp; ret
inline constexpr uint8_t kRevealBytes[] = {
    0x55, 0x8b, 0xec, 0x8b, 0x55, 0x08, 0x85, 0xd2, 0x74, 0,    0x8b, 0x4a,
    0,    0x8b, 0x45, 0x0c, 0x89, 0x81, 0,    0,    0,    0,    0x8b, 0x4a,
    0,    0x8b, 0x45, 0x10, 0x89, 0x81, 0,    0,    0,    0,    0x5d, 0xc3};
inline constexpr uint8_t kRevealMask[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1,
                                          0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1,
                                          0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1};

// parse(text, start, &glyphs):
//   push ebp; mov ebp,esp; sub esp,0x10; mov ecx,[ebp+0xc]; xor edx,edx;
//   mov eax,[ebp+8]; mov [ebp-4],edx; mov [ebp-8],ecx; mov [ebp-0x10],eax;
//   cmp [eax+ecx*2],dx; je +x; lea eax,[ebp-0x10]; push eax; call tokenizer;
//   mov edx,[ebp-4]; add esp,4; mov ecx,[ebp-8]; mov eax,[ebp+0x10];
//   test eax,eax; je +2; mov [eax],edx; mov eax,ecx; mov esp,ebp; pop ebp; ret
inline constexpr uint8_t kParserBytes[] = {
    0x55, 0x8b, 0xec, 0x83, 0xec, 0x10, 0x8b, 0x4d, 0x0c, 0x33, 0xd2, 0x8b,
    0x45, 0x08, 0x89, 0x55, 0xfc, 0x89, 0x4d, 0xf8, 0x89, 0x45, 0xf0, 0x66,
    0x39, 0x14, 0x48, 0x74, 0,    0x8d, 0x45, 0xf0, 0x50, 0xe8, 0,    0,
    0,    0,    0x8b, 0x55, 0xfc, 0x83, 0xc4, 0x04, 0x8b, 0x4d, 0xf8, 0x8b,
    0x45, 0x10, 0x85, 0xc0, 0x74, 0x02, 0x89, 0x10, 0x8b, 0xc1, 0x8b, 0xe5,
    0x5d, 0xc3};
inline constexpr uint8_t kParserMask[] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
inline constexpr size_t kRevealAfterParseScan = 0x80u;

struct SegmentSites {
  uintptr_t parser = 0u;  // mapped
  uintptr_t reveal = 0u;
};

enum class SegmentResult : uint32_t {
  kResolved = 0,
  kNoReveal = 1,
  kRevealFieldMismatch = 2,
  kNoParser = 3,
  kParserCallers = 4,
  kNoRevealAfterParse = 5,
};

inline SegmentResult ResolveSegment(const exact::LoadedPeImage& image,
                                    const DrawSites& draw, SegmentSites* out) {
  *out = SegmentSites();
  const auto reveals = mio::FindShapes(image, kRevealBytes, kRevealMask,
                                       sizeof(kRevealBytes), 8u);
  size_t reveal = SIZE_MAX;
  size_t field_mismatch = 0u;
  for (size_t at : reveals) {
    const uint8_t* p = image.base + at;
    if (p[12] != draw.data_field || p[24] != draw.data_field ||
        mio::Load32(p + 18u) != draw.reveal_start ||
        mio::Load32(p + 30u) != draw.reveal_end) {
      ++field_mismatch;
      continue;
    }
    if (reveal != SIZE_MAX) return SegmentResult::kNoReveal;  // ambiguous
    reveal = at;
  }
  if (reveal == SIZE_MAX) {
    return field_mismatch != 0u ? SegmentResult::kRevealFieldMismatch
                                : SegmentResult::kNoReveal;
  }
  const auto parsers = mio::FindShapes(image, kParserBytes, kParserMask,
                                       sizeof(kParserBytes), 4u);
  if (parsers.size() != 1u) return SegmentResult::kNoParser;
  size_t caller = SIZE_MAX;
  size_t callers = 0u;
  for (size_t s = 0u; s < image.section_count; ++s) {
    const auto& section = image.sections[s];
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u) continue;
    for (size_t at = 0u; at + 5u <= section.size; ++at) {
      size_t target = 0u;
      if (section.bytes[at] == 0xe8u &&
          mio::Rel32Target(image, section.rva + at, &target) &&
          target == parsers[0]) {
        caller = section.rva + at;
        ++callers;
      }
    }
  }
  if (callers != 1u) return SegmentResult::kParserCallers;
  bool reveal_follows = false;
  for (size_t at = caller + 5u; at + 5u <= image.size &&
                                at <= caller + kRevealAfterParseScan;
       ++at) {
    size_t target = 0u;
    reveal_follows = reveal_follows ||
                     (image.base[at] == 0xe8u &&
                      mio::Rel32Target(image, at, &target) && target == reveal);
  }
  if (!reveal_follows) return SegmentResult::kNoRevealAfterParse;
  out->parser = reinterpret_cast<uintptr_t>(image.base) + parsers[0];
  out->reveal = reinterpret_cast<uintptr_t>(image.base) + reveal;
  return SegmentResult::kResolved;
}

// ── segment text ───────────────────────────────────────────────────────────
//
// Formatted page text control codes (UTF-16): 0x07 0x08 <voice>\0 voice
// start, 0x07 0x09 voice end, 0x07 0x01 <base>\n<ruby>\0 ruby, 0x07 0x06
// click wait, 0x07 0x04 continuation; '\n' line breaks.

inline constexpr size_t kMaxSegmentUnits = 512u;
inline constexpr size_t kMaxVoiceNameUnits = 64u;

struct Segment {
  std::wstring line;   // displayed text: ruby bases, no codes, no breaks
  std::wstring voice;  // voice name of a 0x07 0x08 tag, if any
  bool markup = false; // an unknown control code was skipped
};

inline bool CleanSegment(const wchar_t* raw, size_t units, Segment* out) {
  *out = Segment();
  if (raw == nullptr) return false;
  size_t at = 0u;
  while (at < units) {
    const wchar_t c = raw[at];
    if (c == 0x07) {
      if (at + 1u >= units) {
        out->markup = true;
        break;
      }
      const wchar_t code = raw[at + 1u];
      at += 2u;
      if (code == 0x08) {
        std::wstring name;
        while (at < units && raw[at] != 0) {
          if (name.size() < kMaxVoiceNameUnits) name.push_back(raw[at]);
          ++at;
        }
        ++at;  // terminator
        out->voice = name;
      } else if (code == 0x01) {
        while (at < units && raw[at] != L'\n' && raw[at] != 0) {
          out->line.push_back(raw[at++]);
        }
        while (at < units && raw[at] != 0) ++at;  // ruby text
        ++at;
      } else if (code != 0x09 && code != 0x06 && code != 0x04) {
        out->markup = true;
      }
      continue;
    }
    ++at;
    if (c == L'\n' || c == L'\r' || c == 0) continue;
    if (c < 0x20) {
      out->markup = true;
      continue;
    }
    out->line.push_back(c);
  }
  if (out->line.size() > kMaxSegmentUnits) out->line.resize(kMaxSegmentUnits);
  return !out->line.empty();
}

// "…\voice\vir\v_vir0001.ogg" -> "v_vir0001" (lowercase).
inline std::wstring VoiceKeyFromPath(const wchar_t* path) {
  std::wstring text(path == nullptr ? L"" : path);
  const size_t slash = text.find_last_of(L"\\/");
  std::wstring leaf = slash == std::wstring::npos ? text : text.substr(slash + 1u);
  const size_t dot = leaf.find_last_of(L'.');
  if (dot != std::wstring::npos) leaf.resize(dot);
  for (wchar_t& c : leaf) c = mio::WideLower(c);
  return leaf;
}

inline std::wstring VoiceKey(const std::wstring& name) {
  std::wstring key = name;
  for (wchar_t& c : key) c = mio::WideLower(c);
  return key;
}

// ── glyph mapping ──────────────────────────────────────────────────────────

inline constexpr uint16_t kNoGlyph = 0xffffu;
inline constexpr size_t kMaxGlyphs = 1024u;

inline bool IsLineSpace(wchar_t c) {
  return c == L' ' || c == 0x3000 || c == L'\t';
}

// Assigns every non-space line unit to the next glyph with the same code unit
// in [first, first + count); glyphs that match nothing (ruby, spacing) are
// skipped.  Space units take a glyph only when the next glyph is that space.
// Fails unless every non-space unit found its glyph.
inline bool MapLine(const uint16_t* codes, size_t first, size_t count,
                    const std::wstring& line, uint16_t* glyph_of_unit) {
  if (codes == nullptr || glyph_of_unit == nullptr || line.empty() ||
      count == 0u || first + count > kMaxGlyphs) {
    return false;
  }
  size_t glyph = first;
  const size_t end = first + count;
  for (size_t unit = 0u; unit < line.size(); ++unit) {
    glyph_of_unit[unit] = kNoGlyph;
    const wchar_t c = line[unit];
    if (IsLineSpace(c)) {
      if (glyph < end && codes[glyph] == c) glyph_of_unit[unit] = static_cast<uint16_t>(glyph++);
      continue;
    }
    while (glyph < end && codes[glyph] != c) ++glyph;
    if (glyph >= end) return false;
    glyph_of_unit[unit] = static_cast<uint16_t>(glyph++);
  }
  return true;
}

// ── projection ─────────────────────────────────────────────────────────────

struct Affine {
  double sx = 0.0, sy = 0.0, dx = 0.0, dy = 0.0;
};

// world = Translate(t) * parent (row vectors).  Only an axis-aligned,
// unflipped 2D transform is accepted.
inline bool ComposeWorld(const float t[3], const float parent[16],
                         Affine* out) {
  const double m11 = parent[0], m12 = parent[1], m21 = parent[4],
               m22 = parent[5];
  auto near0 = [](double v) { return v < 1e-4 && v > -1e-4; };
  if (!near0(m12) || !near0(m21) || !near0(parent[3]) || !near0(parent[7]) ||
      !near0(parent[11]) || parent[15] < 0.999f || parent[15] > 1.001f ||
      m11 <= 1e-3 || m22 <= 1e-3 || m11 > 64.0 || m22 > 64.0) {
    return false;
  }
  out->sx = m11;
  out->sy = m22;
  out->dx = t[0] * m11 + t[1] * m21 + t[2] * parent[8] + parent[12];
  out->dy = t[0] * m12 + t[1] * m22 + t[2] * parent[9] + parent[13];
  return true;
}

struct DesignRect {
  double x0 = 0.0, y0 = 0.0, x1 = 0.0, y1 = 0.0;
};

inline bool GlyphDesignRect(const Affine& world, const int32_t box[4],
                            DesignRect* out) {
  if (box[2] <= box[0] || box[3] <= box[1] || box[2] - box[0] > 512 ||
      box[3] - box[1] > 512) {
    return false;
  }
  out->x0 = box[0] * world.sx + world.dx;
  out->y0 = box[1] * world.sy + world.dy;
  out->x1 = box[2] * world.sx + world.dx;
  out->y1 = box[3] * world.sy + world.dy;
  return true;
}

struct PixelRect {
  int32_t x = 0, y = 0, w = 0, h = 0;
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

// The engine presents its design back buffer stretched over the whole client
// (measured: a 1024x600 design in a 1280x720 window scales 1.25 x 1.2).  A
// windowed client of any size is admitted with independent axis scales; a
// client that covers its monitor (fullscreen, where a presenter may letterbox)
// must have the design aspect.
inline bool ClientScaleAdmitted(int32_t client_w, int32_t client_h,
                                int32_t design_w, int32_t design_h,
                                bool covers_monitor) {
  if (client_w <= 0 || client_h <= 0 || design_w <= 0 || design_h <= 0) {
    return false;
  }
  const double kx = static_cast<double>(client_w) / design_w;
  const double ky = static_cast<double>(client_h) / design_h;
  if (kx < 0.25 || ky < 0.25 || kx > 8.0 || ky > 8.0) return false;
  return !covers_monitor ||
         ClientMatchesDesign(client_w, client_h, design_w, design_h);
}

// Design pixels -> client pixels (independent axis scales).  The whole box
// must lie inside the design screen.
inline bool ProjectDesign(const DesignRect& r, int32_t design_w,
                          int32_t design_h, int32_t client_w, int32_t client_h,
                          PixelRect* out) {
  if (design_w <= 0 || design_h <= 0 || client_w <= 0 || client_h <= 0 ||
      r.x0 < 0.0 || r.y0 < 0.0 || r.x1 > design_w || r.y1 > design_h ||
      r.x1 - r.x0 < 1.0 || r.y1 - r.y0 < 1.0) {
    return false;
  }
  const double kx = static_cast<double>(client_w) / design_w;
  const double ky = static_cast<double>(client_h) / design_h;
  const int32_t x0 = static_cast<int32_t>(r.x0 * kx);
  const int32_t y0 = static_cast<int32_t>(r.y0 * ky);
  int32_t x1 = static_cast<int32_t>(r.x1 * kx);
  int32_t y1 = static_cast<int32_t>(r.y1 * ky);
  if (x1 < r.x1 * kx) ++x1;
  if (y1 < r.y1 * ky) ++y1;
  if (x1 > client_w || y1 > client_h || x1 - x0 < 1 || y1 - y0 < 1) {
    return false;
  }
  *out = {x0, y0, x1 - x0, y1 - y0};
  return true;
}

// Exactly one box contains the point (client pixels); -1 otherwise.
inline int HitTest(const PixelRect* boxes, size_t count, int32_t x,
                   int32_t y) {
  int found = -1;
  for (size_t i = 0u; i < count; ++i) {
    const PixelRect& b = boxes[i];
    if (b.w <= 0 || x < b.x || y < b.y || x >= b.x + b.w || y >= b.y + b.h) {
      continue;
    }
    if (found >= 0) return -1;
    found = static_cast<int>(i);
  }
  return found;
}

// ── message-thread click claim ─────────────────────────────────────────────

struct ClaimState {
  bool owned = false;
};

struct ClaimDecision {
  bool swallow = false;
  bool submit = false;
};

inline bool NeedsEligibility(uint32_t message) {
  return message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK;
}

// A claimed press owns the button until its release; both edges are
// swallowed so the engine's input dispatcher never sees the click.
//
// Touch: only the WM_LBUTTON* edges are handled.  A touch tap reaches the
// window procedure as the WM_LBUTTONDOWN / WM_LBUTTONUP pair the system
// promotes it to (possibly back to back in one message batch), so a tap on a
// glyph is claimed exactly like a mouse click.  Not handled here: a long
// press (the system turns it into WM_RBUTTON*, which this never claims, so it
// reaches the game as its right-click action), WM_POINTER* (a swipe or a
// pointer-aware path never comes through these edges) and a lookup card
// taking the foreground on touch activation.  None of this was verified with
// real touch input.
inline ClaimDecision DecideMessage(uint32_t message, bool eligible,
                                   ClaimState* claim) {
  ClaimDecision decision;
  if (NeedsEligibility(message)) {
    claim->owned = eligible;
    decision.swallow = eligible;
    decision.submit = eligible;
  } else if (message == WM_LBUTTONUP && claim->owned) {
    claim->owned = false;
    decision.swallow = true;
  }
  return decision;
}

// ── which window to hook ───────────────────────────────────────────────────

// The click window is the game's window under the main window's client
// centre.  A rejection is bound to that window and its procedure, never
// permanent: a splash / movie child or a window destroyed and recreated is
// evaluated again once the candidate changes (a recreated window has another
// HWND — the handle's upper word is the window manager's reuse counter).  A
// hooked procedure stays hooked for the process (MinHook owns the detour);
// a new window of an already hooked procedure is only re-bound.
inline constexpr uint32_t kMaxWindowProcedures = 4u;

struct WindowCandidate {
  uintptr_t window = 0u;     // 0 = no candidate yet
  uintptr_t procedure = 0u;
  bool in_image = false;     // its procedure lies in the game image's code
};

struct WindowBindingState {
  uintptr_t bound = 0u;  // window currently bound (0 = none)
  bool bound_alive = false;
  uintptr_t rejected_window = 0u;
  uintptr_t rejected_procedure = 0u;
  uint32_t hooked_count = 0u;
  uintptr_t hooked[kMaxWindowProcedures] = {};
};

enum class WindowStep : uint32_t {
  kKeep = 0,    // the bound window is alive
  kWait = 1,    // nothing (new) to evaluate
  kReject = 2,  // remember this window + procedure as rejected
  kBind = 3,    // its procedure is hooked already: bind the window
  kHook = 4,    // hook its procedure into the next free slot, then bind
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
  if (candidate.window == 0u) return WindowStep::kWait;
  if (candidate.window == state.rejected_window &&
      candidate.procedure == state.rejected_procedure) {
    return WindowStep::kWait;
  }
  if (!candidate.in_image || candidate.procedure == 0u) {
    return WindowStep::kReject;
  }
  if (WindowProcedureHooked(state, candidate.procedure)) {
    return WindowStep::kBind;
  }
  if (state.hooked_count >= kMaxWindowProcedures) return WindowStep::kReject;
  return WindowStep::kHook;
}

}  // namespace fushi_voice_hook::malie_lookup
