// LucaSystem (Prototype) in-game lookup: pure rules shared by the adapter and
// the offline tests.
//
// The engine lays every text box out as a cText object and keeps the result
// in it: a ring of rows, each row an array of glyph records with the glyph's
// UTF-16 unit and its position and size in the design screen.  The adapter
// learns the live cText objects from the layout routine's `this`, picks the
// one whose glyphs spell the published line and projects those glyphs to the
// game window's client pixels.
//
// Layout routine (__thiscall, `ret 8`): its prologue is followed by four
// identical blocks that reset the four attached sub-objects:
//
//   push ebp / mov ebp,esp / and esp,-8 / sub esp,imm8
//   mov eax,[cookie] / push esi / push edi / mov edi,ecx
//   mov [esp+a],eax / mov [esp+b],edi
//   4x { mov eax,[edi+sub] / mov [esp+s],eax / test eax,eax / je +0x4C /
//        movsx eax,word[edi+..] x4 / mov edi,[esp+s] / ... }
//
// The site is that shape, unique in the executable sections.  The cText
// fields the model reads are then required to appear in the routine's own
// code with exactly the same displacements (the row ring, its head and count,
// the integer origin), so a build whose layout differs fails closed instead
// of being read with stale offsets.  Glyph records are validated at run time:
// every record unit must equal the line's unit at its position.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "luca_text_core.h"

namespace fushi_voice_hook::luca {

// ── layout routine site ──────────────────────────────────────────────────

inline constexpr int16_t kLayoutPrologueShape[] = {
    0x55, 0x8B, 0xEC,                    // push ebp / mov ebp, esp
    0x83, 0xE4, 0xF8,                    // and esp, -8
    0x83, 0xEC, -1,                      // sub esp, imm8
    0xA1, -1,   -1,   -1,   -1,          // mov eax, [cookie]
    0x56, 0x57,                          // push esi / push edi
    0x8B, 0xF9,                          // mov edi, ecx
    0x89, 0x44, 0x24, -1,                // mov [esp+a], eax
    0x89, 0x7C, 0x24, -1,                // mov [esp+b], edi
};
inline constexpr size_t kLayoutPrologueBytes =
    sizeof(kLayoutPrologueShape) / sizeof(kLayoutPrologueShape[0]);

// One sub-object reset block; the routine carries four back to back.
inline constexpr int16_t kLayoutResetShape[] = {
    0x8B, 0x87, -1,   -1,   0x00, 0x00,  // mov eax, [edi+sub]
    0x89, 0x44, 0x24, -1,                // mov [esp+s], eax
    0x85, 0xC0,                          // test eax, eax
    0x74, 0x4C,                          // je next block
    0x0F, 0xBF, 0x87, -1,   -1,   0x00, 0x00,  // movsx eax, word [edi+..]
    0x0F, 0xBF, 0xB7, -1,   -1,   0x00, 0x00,  // movsx esi, word [edi+..]
    0x0F, 0xBF, 0x97, -1,   -1,   0x00, 0x00,  // movsx edx, word [edi+..]
    0x0F, 0xBF, 0x8F, -1,   -1,   0x00, 0x00,  // movsx ecx, word [edi+..]
    0x8B, 0x7C, 0x24, -1,                // mov edi, [esp+s]
};
inline constexpr size_t kLayoutResetBytes =
    sizeof(kLayoutResetShape) / sizeof(kLayoutResetShape[0]);
inline constexpr size_t kLayoutResetStride = 0x5Au;  // je +0x4C past 0x0E
inline constexpr uint32_t kLayoutResetBlocks = 4u;
// The routine body the field cross-check scans.
inline constexpr size_t kLayoutBodyBytes = 0xD00u;

// cText fields read by the model (displacements from `this`).
inline constexpr uint32_t kTextRowCapacity = 0x28u;   // i32
inline constexpr uint32_t kTextOriginX = 0x4Cu;       // i32, design pixels
inline constexpr uint32_t kTextOriginY = 0x50u;       // i32, design pixels
inline constexpr uint32_t kTextRowCount = 0x6Cu;      // i32
inline constexpr uint32_t kTextRows = 0x11Cu;         // row ring pointer
inline constexpr uint32_t kTextRowHead = 0x17Cu;      // i32, ring head
// Row (ring element).
inline constexpr uint32_t kRowStride = 0x50u;
inline constexpr uint32_t kRowRecordCount = 0x04u;    // u16
inline constexpr uint32_t kRowOffsetY = 0x14u;        // i32 from the origin
inline constexpr uint32_t kRowRecords = 0x48u;        // record array pointer
// Glyph record.
inline constexpr uint32_t kRecordStride = 0x18u;
inline constexpr uint32_t kRecordUnit = 0x04u;        // u16 UTF-16 unit
inline constexpr uint32_t kRecordX = 0x06u;           // i16 from the origin
inline constexpr uint32_t kRecordW = 0x0Cu;           // i16
inline constexpr uint32_t kRecordH = 0x12u;           // i16

inline constexpr uint32_t kMaxRows = 32u;
inline constexpr uint32_t kMaxRowRecords = 256u;
inline constexpr uint32_t kMaxGlyphs = 512u;
inline constexpr int32_t kMaxDesignSide = 8192;

inline bool MatchesShapeAt(const uint8_t* at, const int16_t* shape,
                           size_t bytes) {
  for (size_t i = 0; i < bytes; ++i) {
    if (shape[i] >= 0 && at[i] != static_cast<uint8_t>(shape[i])) {
      return false;
    }
  }
  return true;
}

inline bool MatchesLayoutAt(const uint8_t* at, size_t available) {
  const size_t need =
      kLayoutPrologueBytes + kLayoutResetStride * (kLayoutResetBlocks - 1u) +
      kLayoutResetBytes;
  if (available < need ||
      !MatchesShapeAt(at, kLayoutPrologueShape, kLayoutPrologueBytes)) {
    return false;
  }
  for (uint32_t i = 0; i < kLayoutResetBlocks; ++i) {
    if (!MatchesShapeAt(at + kLayoutPrologueBytes + kLayoutResetStride * i,
                        kLayoutResetShape, kLayoutResetBytes)) {
      return false;
    }
  }
  return true;
}

// `[edi+disp]` operand of `op r32, r/m32` (or the movd / movss forms): the
// ModRM byte names EDI as base with an 8- or 32-bit displacement.
inline bool ReadsEdiField(const uint8_t* body, size_t bytes, uint8_t opcode,
                          uint32_t disp) {
  const bool short_disp = disp < 0x80u;
  for (size_t i = 0; i + 6u < bytes; ++i) {
    if (body[i] != opcode) continue;
    const uint8_t modrm = body[i + 1u];
    if ((modrm & 0x07u) != 0x07u) continue;  // base = edi
    if (short_disp && (modrm & 0xC0u) == 0x40u && body[i + 2u] == disp) {
      return true;
    }
    if ((modrm & 0xC0u) == 0x80u) {
      uint32_t value = 0u;
      std::memcpy(&value, body + i + 2u, sizeof(value));
      if (value == disp) return true;
    }
  }
  return false;
}

// The fields the model reads, as the routine itself reads them.
inline bool LayoutReadsModelFields(const uint8_t* body, size_t bytes) {
  constexpr uint8_t kMov = 0x8Bu;
  constexpr uint8_t kCmp = 0x3Bu;
  constexpr uint8_t kMovd = 0x6Eu;  // 66 0F 6E /r
  return ReadsEdiField(body, bytes, kMov, kTextRowCapacity) &&
         ReadsEdiField(body, bytes, kMov, kTextRows) &&
         ReadsEdiField(body, bytes, kMov, kTextRowHead) &&
         ReadsEdiField(body, bytes, kCmp, kTextRowCount) &&
         ReadsEdiField(body, bytes, kMovd, kTextOriginX) &&
         ReadsEdiField(body, bytes, kMovd, kTextOriginY);
}

enum class LayoutSiteResult : uint8_t {
  kResolved = 0,
  kMissing,
  kAmbiguous,
  kFieldsMismatch,
};

inline LayoutSiteResult ResolveLayoutSite(const CodeSpan* spans,
                                          size_t span_count, uint32_t* out) {
  if (spans == nullptr || out == nullptr) return LayoutSiteResult::kMissing;
  const uint8_t* found = nullptr;
  size_t found_available = 0u;
  uint32_t found_rva = 0u;
  size_t matches = 0u;
  for (size_t s = 0; s < span_count; ++s) {
    const CodeSpan& span = spans[s];
    if (span.bytes == nullptr) continue;
    for (size_t at = 0; at + kLayoutPrologueBytes < span.size; ++at) {
      if (span.bytes[at] != 0x55u ||
          !MatchesLayoutAt(span.bytes + at, span.size - at)) {
        continue;
      }
      if (++matches > 1u) return LayoutSiteResult::kAmbiguous;
      found = span.bytes + at;
      found_available = span.size - at;
      found_rva = span.rva + static_cast<uint32_t>(at);
    }
  }
  if (matches == 0u) return LayoutSiteResult::kMissing;
  if (!LayoutReadsModelFields(found,
                              (std::min)(found_available, kLayoutBodyBytes))) {
    return LayoutSiteResult::kFieldsMismatch;
  }
  *out = found_rva;
  return LayoutSiteResult::kResolved;
}

// ── model ────────────────────────────────────────────────────────────────

struct GlyphRecord {
  uint16_t unit = 0u;
  int16_t x = 0;
  int16_t w = 0;
  int16_t h = 0;
};

struct Row {
  int32_t offset_y = 0;
  std::vector<GlyphRecord> records;
};

struct DesignRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

struct LineGlyph {
  uint32_t source_index = 0u;  // UTF-16 unit of the published line
  DesignRect rect;
};

inline bool IsLineWhitespace(wchar_t unit) {
  return unit == L' ' || unit == L'\t' || unit == L'\r' || unit == L'\n' ||
         unit == 0x3000;
}

// Maps the rows' glyphs, in layout order, onto `line`.  Every record must
// equal the next non-whitespace unit of the line, and every unit of the line
// must be either matched or whitespace (the engine does not lay out line
// breaks).  Surrogate units fail closed.
inline bool MapRowsToLine(const Row* rows, size_t row_count, int32_t origin_x,
                          int32_t origin_y, const std::wstring& line,
                          std::vector<LineGlyph>* out) {
  if (out == nullptr) return false;
  out->clear();
  size_t next = 0u;
  for (size_t r = 0; r < row_count; ++r) {
    for (const GlyphRecord& record : rows[r].records) {
      while (next < line.size() && IsLineWhitespace(line[next]) &&
             line[next] != static_cast<wchar_t>(record.unit)) {
        ++next;
      }
      if (next >= line.size() ||
          line[next] != static_cast<wchar_t>(record.unit) ||
          (record.unit >= 0xD800u && record.unit <= 0xDFFFu) ||
          record.w <= 0 || record.h <= 0) {
        out->clear();
        return false;
      }
      LineGlyph glyph;
      glyph.source_index = static_cast<uint32_t>(next);
      glyph.rect.x = origin_x + record.x;
      glyph.rect.y = origin_y + rows[r].offset_y;
      glyph.rect.w = record.w;
      glyph.rect.h = record.h;
      if (glyph.rect.x < -kMaxDesignSide || glyph.rect.x > kMaxDesignSide ||
          glyph.rect.y < -kMaxDesignSide || glyph.rect.y > kMaxDesignSide) {
        out->clear();
        return false;
      }
      out->push_back(glyph);
      ++next;
    }
  }
  while (next < line.size() && IsLineWhitespace(line[next])) ++next;
  if (next != line.size() || out->empty()) {
    out->clear();
    return false;
  }
  return true;
}

// ── projection ───────────────────────────────────────────────────────────

// The engine presents the design screen aspect-fit and centred in the client
// area (letterbox / pillarbox when the aspects differ).
struct Projection {
  double scale = 0.0;
  double offset_x = 0.0;
  double offset_y = 0.0;
};

inline bool MakeProjection(int32_t design_w, int32_t design_h,
                           int32_t client_w, int32_t client_h,
                           Projection* out) {
  if (out == nullptr || design_w <= 0 || design_h <= 0 || client_w <= 0 ||
      client_h <= 0 || design_w > kMaxDesignSide ||
      design_h > kMaxDesignSide) {
    return false;
  }
  const double scale =
      (std::min)(static_cast<double>(client_w) / design_w,
                 static_cast<double>(client_h) / design_h);
  out->scale = scale;
  out->offset_x = (client_w - design_w * scale) / 2.0;
  out->offset_y = (client_h - design_h * scale) / 2.0;
  return scale > 0.0;
}

inline DesignRect ProjectRect(const DesignRect& rect, const Projection& p) {
  const double left = p.offset_x + rect.x * p.scale;
  const double top = p.offset_y + rect.y * p.scale;
  const double right = p.offset_x + (rect.x + rect.w) * p.scale;
  const double bottom = p.offset_y + (rect.y + rect.h) * p.scale;
  DesignRect out;
  out.x = static_cast<int32_t>(std::lround(left));
  out.y = static_cast<int32_t>(std::lround(top));
  out.w = (std::max)(1, static_cast<int32_t>(std::lround(right)) - out.x);
  out.h = (std::max)(1, static_cast<int32_t>(std::lround(bottom)) - out.y);
  return out;
}

// Client point -> design point; false outside the presented design screen.
inline bool ClientToDesign(int32_t x, int32_t y, const Projection& p,
                           int32_t design_w, int32_t design_h, int32_t* dx,
                           int32_t* dy) {
  if (p.scale <= 0.0) return false;
  const double fx = (x - p.offset_x) / p.scale;
  const double fy = (y - p.offset_y) / p.scale;
  if (fx < 0.0 || fy < 0.0 || fx >= design_w || fy >= design_h) return false;
  *dx = static_cast<int32_t>(fx);
  *dy = static_cast<int32_t>(fy);
  return true;
}

// Exactly one glyph contains the point.
inline bool HitTestGlyphs(const LineGlyph* glyphs, size_t count, int32_t x,
                          int32_t y, size_t* hit) {
  size_t found = count;
  for (size_t i = 0; i < count; ++i) {
    const DesignRect& r = glyphs[i].rect;
    if (x < r.x || y < r.y || x >= r.x + r.w || y >= r.y + r.h) continue;
    if (found != count) return false;
    found = i;
  }
  if (found == count) return false;
  *hit = found;
  return true;
}

// ── left-button claim over GetAsyncKeyState samples ─────────────────────

inline constexpr uint16_t kAsyncDown = 0x8000u;
inline constexpr uint16_t kAsyncPressedSince = 0x0001u;

struct ClaimState {
  bool owned = false;     // the current press belongs to the lookup
  bool was_down = false;  // the previous sample was down
};

struct ClaimDecision {
  bool submit = false;  // publish this press as a lookup
  bool mask = false;    // hide the press from the engine
};

// One engine sample of VK_LBUTTON.  A fresh press (down after up) that is
// `eligible` is owned until the sample after its release; every sample of an
// owned press — and the release sample, whose pressed-since bit would still
// report it — is masked.
inline ClaimDecision DecideLeftButtonSample(uint16_t raw, bool eligible,
                                            ClaimState* claim) {
  ClaimDecision decision;
  const bool down = (raw & kAsyncDown) != 0u;
  if (down && !claim->was_down) {
    claim->owned = eligible;
    decision.submit = eligible;
  }
  if (claim->owned) decision.mask = true;
  if (!down) claim->owned = false;
  claim->was_down = down;
  return decision;
}

inline bool IsFreshPress(uint16_t raw, const ClaimState& claim) {
  return (raw & kAsyncDown) != 0u && !claim.was_down;
}

// ── Shift lookup over HookWorker GetAsyncKeyState(VK_SHIFT) samples ─────

struct ShiftState {
  bool synchronized = false;  // seeded since lookup was last (re)enabled
  bool was_down = false;
};

// One worker sample of VK_SHIFT.  True once per press: on the down edge, or
// for a tap shorter than the poll interval (up now, pressed-since bit set).
// The first sample after Reset only seeds the state, so a Shift already held
// (or tapped) while lookup was off never replays as a lookup.
inline bool ConsumeShiftSample(uint16_t raw, ShiftState* state) {
  const bool down = (raw & kAsyncDown) != 0u;
  if (!state->synchronized) {
    state->synchronized = true;
    state->was_down = down;
    return false;
  }
  const bool press = (down && !state->was_down) ||
                     (!down && (raw & kAsyncPressedSince) != 0u);
  state->was_down = down;
  return press;
}

inline void ResetShiftState(ShiftState* state) { *state = ShiftState{}; }

}  // namespace fushi_voice_hook::luca
