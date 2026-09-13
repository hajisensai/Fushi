#pragma once

// Shared, header-only contract between the smash/fzmedia adapter core
// (smash_fzmedia_adapter.inc: admission, fzmedia audio, KAG text-layer layout
// hook, paragraph assembly, worker publication) and the lookup runtime
// (smash_fzmedia_lookup.inc: exact geometry provider, click/hover sensing,
// shield participation).  Both sides may only communicate through the types
// declared here.  Pure data + inline helpers; no Win32 calls, no IPC calls, so
// every function stays unit-testable off-line.
//
// Engine facts this contract encodes (measured on Fate/stay night REMASTERED
// v1.1.127 x64, 2026-09-04; the same code path is expected for every
// TYPE-MOON "smash" framework title that ships fzmedia-*.dll):
//   * The KAG text layer lays out one UTF-16 code unit per call of
//     TextLayerBase::layoutChar(layer, run, index, &next).  `run+text_begin`
//     / `run+text_end` bound the whole run's UTF-16 buffer; `layer+cursor_x`
//     / `layer+cursor_y` are the pen position in layer units before/after the
//     call; `layer+font_px` is the glyph size, `layer+line_pitch` the
//     line advance (int), `layer+scale` the layer scale (float, 1.0 observed).
//   * Layer units are design pixels of a 1920x1080 stage.  The stage is
//     aspect-fit into the client area with a uniform scale
//     s = min(client_w / 1920, client_h / 1080) and centred; the text layer
//     origin inside the stage is a per-title constant that is NOT readable
//     from the layer object, so it is solved by the host from a frame
//     (PublishLookupLayerLine / ReadLookupLayerOrigin, BUG-2093 channel).
//     To make the host's per-axis formula
//         client = (layer + origin) * client / design
//     equal the uniform projection, the adapter publishes the *synthetic*
//     design size (client_w / s, client_h / s) instead of 1920x1080.
//   * A KAG paragraph may span several runs ([r] breaks).  Runs are merged
//     into one published line while the CJK quote balance is open.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fushi_voice_hook {
namespace smash_fzmedia {

constexpr uint32_t kMaxLineUnits = 512;   // UTF-16 code units per published line
constexpr uint32_t kMaxRunUnits = 512;    // UTF-16 code units per engine run
constexpr float kStageDesignWidth = 1920.0f;
constexpr float kStageDesignHeight = 1080.0f;
// fzmedia SoundCategory value observed for character voice (create() r9d).
constexpr int32_t kVoiceSoundCategory = 5;

// One laid-out glyph cell in layer units (design pixels, y grows down).
struct GlyphCell {
  float x = 0.0f;
  float y = 0.0f;
  float w = 0.0f;
  float h = 0.0f;
  // Non-zero when the cell paints ink (not a space / ideographic space / tab).
  uint8_t inked = 0;
};

// Snapshot of the currently published line: text + one cell per UTF-16 unit.
// `generation` increases every time the snapshot is republished (text change
// or continuation merge); it is what the geometry provider must use for both
// LookupGeometryHitPublication::text_generation and geometry_generation so a
// hit can never mix an old cell array with a newer line.
struct LineSnapshot {
  uint64_t generation = 0;
  uint64_t first_tick_ms = 0;          // GetTickCount64 of the first run's first glyph
  uint64_t text_event_id = 0;          // TextLaneWrite publication seq (0 = unpublished)
  uint32_t unit_count = 0;             // valid units in `text` and `cells`
  wchar_t text[kMaxLineUnits] = {};
  GlyphCell cells[kMaxLineUnits] = {};
  float font_px = 0.0f;                // layer+font_px at layout time
  float line_pitch = 0.0f;             // layer+line_pitch at layout time
  bool complete = false;               // quote balance closed (or fallback timeout)
};

// Uniform aspect-fit projection of the 1920x1080 stage into a client area.
struct StageProjection {
  float scale = 0.0f;      // s = min(cw/1920, ch/1080)
  float offset_x = 0.0f;   // (cw - 1920*s) / 2
  float offset_y = 0.0f;   // (ch - 1080*s) / 2
  float synthetic_design_w = 0.0f;  // cw / s
  float synthetic_design_h = 0.0f;  // ch / s
  bool valid = false;
};

inline StageProjection ComputeStageProjection(int client_w, int client_h) {
  StageProjection p;
  if (client_w <= 0 || client_h <= 0) return p;
  const float sx = static_cast<float>(client_w) / kStageDesignWidth;
  const float sy = static_cast<float>(client_h) / kStageDesignHeight;
  p.scale = sx < sy ? sx : sy;
  if (!(p.scale > 0.0f)) return p;
  p.offset_x = (static_cast<float>(client_w) - kStageDesignWidth * p.scale) * 0.5f;
  p.offset_y = (static_cast<float>(client_h) - kStageDesignHeight * p.scale) * 0.5f;
  p.synthetic_design_w = static_cast<float>(client_w) / p.scale;
  p.synthetic_design_h = static_cast<float>(client_h) / p.scale;
  p.valid = true;
  return p;
}

// Project a layer-space cell to client pixels given the host-solved layer
// origin expressed in synthetic design units (see PublishLookupLayerLine):
//   client = (layer + origin) * scale.
inline bool ProjectCellToClient(const StageProjection& projection,
                                float origin_x, float origin_y,
                                const GlyphCell& cell,
                                float* out_x, float* out_y,
                                float* out_w, float* out_h) {
  if (!projection.valid || cell.w <= 0.0f || cell.h <= 0.0f) return false;
  *out_x = (cell.x + origin_x) * projection.scale;
  *out_y = (cell.y + origin_y) * projection.scale;
  *out_w = cell.w * projection.scale;
  *out_h = cell.h * projection.scale;
  return true;
}

// Characters that occupy a layout cell but paint no ink.
inline bool IsNonInkUnit(wchar_t unit) {
  return unit == L' ' || unit == L'\t' || unit == 0x3000 || unit == L'\r' ||
         unit == L'\n' || unit == 0;
}

// CJK quote balance used to decide whether a run finishes a paragraph.
// Returns the balance after scanning `units` starting from `initial`.
inline int32_t QuoteBalanceAfter(const wchar_t* units, uint32_t count,
                                 int32_t initial) {
  int32_t balance = initial;
  for (uint32_t i = 0; i < count; ++i) {
    switch (units[i]) {
      case 0x300C:  // 「
      case 0x300E:  // 『
      case 0xFF08:  // （
        ++balance;
        break;
      case 0x300D:  // 」
      case 0x300F:  // 』
      case 0xFF09:  // ）
        if (balance > 0) --balance;
        break;
      default:
        break;
    }
  }
  return balance;
}

// Pick the single line (cells sharing a y band) with the most inked cells and
// return its layer-space bounding box.  This is what PublishLookupLayerLine
// wants (single line, inked glyphs only, >= min_inked cells).  Returns false
// when no line qualifies.
inline bool PickMostInkedLine(const LineSnapshot& line, uint32_t min_inked,
                              float* left, float* top, float* right,
                              float* bottom, uint32_t* inked_count) {
  bool found = false;
  uint32_t best_inked = 0;
  float best_l = 0, best_t = 0, best_r = 0, best_b = 0;
  const uint32_t n = line.unit_count;
  for (uint32_t i = 0; i < n; ++i) {
    const GlyphCell& seed = line.cells[i];
    if (!seed.inked || seed.h <= 0.0f) continue;
    // Skip seeds that belong to an already-evaluated band.
    bool seen = false;
    for (uint32_t k = 0; k < i; ++k) {
      const GlyphCell& prev = line.cells[k];
      if (prev.inked && prev.h > 0.0f &&
          prev.y < seed.y + seed.h * 0.5f && prev.y + prev.h > seed.y + seed.h * 0.5f) {
        seen = true;
        break;
      }
    }
    if (seen) continue;
    uint32_t inked = 0;
    float l = seed.x, t = seed.y, r = seed.x + seed.w, b = seed.y + seed.h;
    for (uint32_t k = 0; k < n; ++k) {
      const GlyphCell& c = line.cells[k];
      if (!c.inked || c.h <= 0.0f) continue;
      const float mid = c.y + c.h * 0.5f;
      if (mid < seed.y || mid >= seed.y + seed.h) continue;
      ++inked;
      if (c.x < l) l = c.x;
      if (c.y < t) t = c.y;
      if (c.x + c.w > r) r = c.x + c.w;
      if (c.y + c.h > b) b = c.y + c.h;
    }
    if (inked > best_inked) {
      best_inked = inked;
      best_l = l; best_t = t; best_r = r; best_b = b;
      found = true;
    }
  }
  if (!found || best_inked < min_inked) return false;
  *left = best_l; *top = best_t; *right = best_r; *bottom = best_b;
  *inked_count = best_inked;
  return true;
}

// Hit-test a client-space point against the projected cells.  Returns the
// UTF-16 index of the hit cell or -1.  Cells are cell boxes (not ink), so a
// point between two glyph boxes on the same line resolves to none.
inline int32_t HitTestClient(const LineSnapshot& line,
                             const StageProjection& projection,
                             float origin_x, float origin_y,
                             float client_x, float client_y) {
  for (uint32_t i = 0; i < line.unit_count; ++i) {
    const GlyphCell& cell = line.cells[i];
    if (!cell.inked) continue;
    float x, y, w, h;
    if (!ProjectCellToClient(projection, origin_x, origin_y, cell, &x, &y, &w, &h)) continue;
    if (client_x >= x && client_x < x + w && client_y >= y && client_y < y + h) {
      return static_cast<int32_t>(i);
    }
  }
  return -1;
}

}  // namespace smash_fzmedia
}  // namespace fushi_voice_hook
