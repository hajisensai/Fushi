#pragma once

// Win32-free decision logic for the smash/fzmedia lookup runtime
// (smash_fzmedia_lookup.inc).  Everything here is pure data in / data out so
// the click shield, the Shift-hover sensing, the host-solved layer origin
// gating and the hit-to-publication mapping can be unit-tested without a
// window, a shared mapping or a game.
//
// Threading contract of the callers (documented here because the state
// structs below are single-writer by design):
//   * MouseGestureState is owned by the game's window thread (the subclass
//     window procedure).  HookWorker never touches it.
//   * ProjectionEpoch / OriginCache are owned by HookWorker.

#include <cmath>
#include <cstdint>

#include "smash_fzmedia_shared.h"

namespace fushi_voice_hook {
namespace smash_fzmedia {
namespace lookup_core {

// Mirrors of the v19 shield surface bits owned by this runtime.  The runtime
// static_asserts them against voice_hook_ipc.h; they are duplicated so this
// header stays free of <windows.h>.
constexpr uint32_t kShieldSurfaceWin32Messages = 0x00000001u;
constexpr uint32_t kShieldSurfaceEnginePrivate = 0x00000080u;
constexpr uint32_t kOwnedShieldSurfaces =
    kShieldSurfaceWin32Messages | kShieldSurfaceEnginePrivate;

// A projected cell may hang over the client edge by at most this many pixels
// before the whole geometry is rejected (fail closed).
constexpr float kClientTolerancePx = 8.0f;
// PublishLookupLayerLine needs a line with at least this many inked glyphs;
// a shorter line has no resolving power for the host's frame solver.
constexpr uint32_t kLayerLineMinInked = 4u;
constexpr uint32_t kOriginCacheEntries = 4u;

// ── Layer line request (hook → host) ────────────────────────────────────────
struct LayerLineRequest {
  uint32_t design_w = 0;
  uint32_t design_h = 0;
  uint32_t glyph_count = 0;
  int32_t left = 0;
  int32_t top = 0;
  int32_t right = 0;
  int32_t bottom = 0;
  bool valid = false;
};

inline uint32_t RoundToDesignUnit(float value) {
  if (!(value > 0.0f)) return 0u;
  const float rounded = std::floor(value + 0.5f);
  if (rounded >= 4294967040.0f) return 0u;
  return static_cast<uint32_t>(rounded);
}

// Synthetic design size = client / scale, so the host's per-axis formula
// (client = (layer + origin) * client / design) collapses to the uniform
// stage projection.  The published box is the most inked single line in
// layer units (integer-expanded so the box never cuts ink).
inline LayerLineRequest BuildLayerLineRequest(const LineSnapshot& line,
                                              const StageProjection& projection) {
  LayerLineRequest request;
  if (!projection.valid || line.unit_count == 0u ||
      line.unit_count > kMaxLineUnits) {
    return request;
  }
  request.design_w = RoundToDesignUnit(projection.synthetic_design_w);
  request.design_h = RoundToDesignUnit(projection.synthetic_design_h);
  if (request.design_w == 0u || request.design_h == 0u) return request;
  float l = 0, t = 0, r = 0, b = 0;
  uint32_t inked = 0;
  if (!PickMostInkedLine(line, kLayerLineMinInked, &l, &t, &r, &b, &inked)) {
    return LayerLineRequest{};
  }
  request.left = static_cast<int32_t>(std::floor(l));
  request.top = static_cast<int32_t>(std::floor(t));
  request.right = static_cast<int32_t>(std::ceil(r));
  request.bottom = static_cast<int32_t>(std::ceil(b));
  request.glyph_count = inked;
  request.valid = request.right > request.left &&
                  request.bottom > request.top && inked >= kLayerLineMinInked;
  if (!request.valid) return LayerLineRequest{};
  return request;
}

// ── Host-solved origin gating ───────────────────────────────────────────────
// The host solves the layer origin once per client size and caches the
// result on its side.  When the synthetic design size changes (client
// resize) a previously read origin belongs to the old projection and must
// not be reused; the runtime therefore records the origin seq observed at the
// moment the new design size was first published and only trusts an origin
// whose seq advanced past it.  Sizes seen before are remembered locally,
// because the host will not re-solve a size it already solved.
struct ProjectionEpoch {
  uint32_t design_w = 0;
  uint32_t design_h = 0;
  uint32_t origin_seq_floor = 0;
};

// Returns true when the design size changed (a new epoch started).  The
// caller passes the origin seq currently visible in the header so an origin
// that was solved for the previous size can never satisfy the new one.
inline bool AdvanceProjectionEpoch(ProjectionEpoch* epoch, uint32_t design_w,
                                   uint32_t design_h,
                                   uint32_t current_origin_seq) {
  if (epoch == nullptr || design_w == 0u || design_h == 0u) return false;
  if (epoch->design_w == design_w && epoch->design_h == design_h) return false;
  epoch->design_w = design_w;
  epoch->design_h = design_h;
  epoch->origin_seq_floor = current_origin_seq;
  return true;
}

inline bool OriginSeqUsable(const ProjectionEpoch& epoch, uint32_t origin_seq) {
  return epoch.design_w != 0u && epoch.design_h != 0u && origin_seq != 0u &&
         origin_seq > epoch.origin_seq_floor;
}

struct OriginCacheEntry {
  uint32_t design_w = 0;
  uint32_t design_h = 0;
  float origin_x = 0.0f;
  float origin_y = 0.0f;
};

struct OriginCache {
  OriginCacheEntry entries[kOriginCacheEntries] = {};
  uint32_t next = 0;
};

inline void RememberOrigin(OriginCache* cache, uint32_t design_w,
                           uint32_t design_h, float origin_x, float origin_y) {
  if (cache == nullptr || design_w == 0u || design_h == 0u) return;
  for (OriginCacheEntry& entry : cache->entries) {
    if (entry.design_w == design_w && entry.design_h == design_h) {
      entry.origin_x = origin_x;
      entry.origin_y = origin_y;
      return;
    }
  }
  OriginCacheEntry& slot = cache->entries[cache->next % kOriginCacheEntries];
  cache->next = (cache->next + 1u) % kOriginCacheEntries;
  slot.design_w = design_w;
  slot.design_h = design_h;
  slot.origin_x = origin_x;
  slot.origin_y = origin_y;
}

inline bool LookupOrigin(const OriginCache& cache, uint32_t design_w,
                         uint32_t design_h, float* origin_x, float* origin_y) {
  if (design_w == 0u || design_h == 0u) return false;
  for (const OriginCacheEntry& entry : cache.entries) {
    if (entry.design_w == design_w && entry.design_h == design_h) {
      *origin_x = entry.origin_x;
      *origin_y = entry.origin_y;
      return true;
    }
  }
  return false;
}

// ── Geometry readiness gate ─────────────────────────────────────────────────
// Every inked cell must project inside the client rect (± tolerance); one
// stray cell means the origin or the projection is wrong for this frame and
// the whole line is rejected rather than publishing a partially right hit.
inline bool AllInkedCellsInsideClient(const LineSnapshot& line,
                                      const StageProjection& projection,
                                      float origin_x, float origin_y,
                                      int32_t client_w, int32_t client_h,
                                      float tolerance) {
  if (!projection.valid || client_w <= 0 || client_h <= 0 ||
      line.unit_count == 0u || line.unit_count > kMaxLineUnits) {
    return false;
  }
  uint32_t inked = 0;
  for (uint32_t i = 0; i < line.unit_count; ++i) {
    const GlyphCell& cell = line.cells[i];
    if (!cell.inked) continue;
    float x, y, w, h;
    if (!ProjectCellToClient(projection, origin_x, origin_y, cell, &x, &y, &w,
                             &h)) {
      return false;
    }
    if (x < -tolerance || y < -tolerance ||
        x + w > static_cast<float>(client_w) + tolerance ||
        y + h > static_cast<float>(client_h) + tolerance) {
      return false;
    }
    ++inked;
  }
  return inked != 0u;
}

inline bool GeometryReady(const LineSnapshot& line,
                          const StageProjection& projection, bool origin_known,
                          float origin_x, float origin_y, int32_t client_w,
                          int32_t client_h) {
  return origin_known && line.generation != 0u &&
         AllInkedCellsInsideClient(line, projection, origin_x, origin_y,
                                   client_w, client_h, kClientTolerancePx);
}

// ── Hit resolution ──────────────────────────────────────────────────────────
struct HitGeometry {
  bool valid = false;
  uint32_t char_index = 0;
  int32_t x = 0;
  int32_t y = 0;
  int32_t w = 0;
  int32_t h = 0;
};

inline HitGeometry ResolveHit(const LineSnapshot& line,
                              const StageProjection& projection,
                              float origin_x, float origin_y, float client_x,
                              float client_y) {
  HitGeometry hit;
  const int32_t index = HitTestClient(line, projection, origin_x, origin_y,
                                      client_x, client_y);
  if (index < 0 || static_cast<uint32_t>(index) >= line.unit_count) return hit;
  float x, y, w, h;
  if (!ProjectCellToClient(projection, origin_x, origin_y,
                           line.cells[static_cast<uint32_t>(index)], &x, &y,
                           &w, &h)) {
    return hit;
  }
  const int32_t left = static_cast<int32_t>(std::floor(x));
  const int32_t top = static_cast<int32_t>(std::floor(y));
  const int32_t right = static_cast<int32_t>(std::ceil(x + w));
  const int32_t bottom = static_cast<int32_t>(std::ceil(y + h));
  hit.valid = true;
  hit.char_index = static_cast<uint32_t>(index);
  hit.x = left;
  hit.y = top;
  hit.w = right > left ? right - left : 1;
  hit.h = bottom > top ? bottom - top : 1;
  return hit;
}

// ── Subclass message decision table ─────────────────────────────────────────
enum class MouseMessageKind : uint8_t {
  kLeftDown = 0,
  kLeftUp = 1,
  kMove = 2,
  kOther = 3,
};

struct MouseMessageInput {
  MouseMessageKind kind = MouseMessageKind::kOther;
  bool shift = false;
  bool ctrl = false;
  bool alt = false;
  // A lookup popup (bitmap or host direct card) is visible above this window
  // or a v19 shield transaction targets it: the game must not see the click.
  bool shield_active = false;
  // Registry NativeInputAllowed for the smash exact provider.
  bool native_input_allowed = false;
  // Result of the hit test at the pointer (only consulted when
  // HitTestRequired() said the test is needed).
  bool hit = false;
  uint64_t hit_generation = 0;
  uint32_t hit_index = 0;
};

struct MouseGestureState {
  bool swallow_next_left_up = false;
  uint64_t hover_generation = 0;
  uint32_t hover_index = 0;
  bool hover_valid = false;
};

struct MouseMessageDecision {
  bool swallow = false;          // do not forward to the original proc
  bool submit = false;           // queue a Submit hit for (generation,index)
  bool request_dismiss = false;  // outside click while the card is open
};

// A bare left down (no Shift/Ctrl/Alt) can only become a lookup click; a
// Shift-move can only become a hover lookup.  Neither is hit-tested while a
// popup shields the window or the host has not admitted native input.
inline bool HitTestRequired(const MouseMessageInput& input) {
  if (input.shield_active || !input.native_input_allowed) return false;
  if (input.kind == MouseMessageKind::kLeftDown) {
    return !input.shift && !input.ctrl && !input.alt;
  }
  if (input.kind == MouseMessageKind::kMove) return input.shift;
  return false;
}

inline MouseMessageDecision DecideMouseMessage(const MouseMessageInput& input,
                                               MouseGestureState* state) {
  MouseMessageDecision decision;
  if (state == nullptr) return decision;
  switch (input.kind) {
    case MouseMessageKind::kLeftDown:
      if (input.shield_active) {
        // Closing the card must never advance the game: eat the down and
        // its paired up, and tell the overlay writer to dismiss.
        decision.swallow = true;
        decision.request_dismiss = true;
        state->swallow_next_left_up = true;
        return decision;
      }
      if (HitTestRequired(input) && input.hit) {
        decision.swallow = true;
        decision.submit = true;
        state->swallow_next_left_up = true;
        return decision;
      }
      state->swallow_next_left_up = false;
      return decision;
    case MouseMessageKind::kLeftUp:
      if (input.shield_active || state->swallow_next_left_up) {
        decision.swallow = true;
      }
      state->swallow_next_left_up = false;
      return decision;
    case MouseMessageKind::kMove:
      // Moves are never swallowed: the engine keeps its own hover state.
      if (!input.shift) {
        state->hover_valid = false;
        return decision;
      }
      if (!HitTestRequired(input) || !input.hit) return decision;
      if (state->hover_valid &&
          state->hover_generation == input.hit_generation &&
          state->hover_index == input.hit_index) {
        return decision;  // same glyph, same line: publish once
      }
      state->hover_valid = true;
      state->hover_generation = input.hit_generation;
      state->hover_index = input.hit_index;
      decision.submit = true;
      return decision;
    case MouseMessageKind::kOther:
    default:
      return decision;
  }
}

// ── Shield mask reducer ─────────────────────────────────────────────────────
// The generic shield (generic_input_shield.inc) owns KeyState / RawInput and
// merges the exact contract declared through the window properties; this is
// the runtime's own contribution for the surfaces it physically owns.
struct ShieldMasks {
  uint32_t required = 0;
  uint32_t ready = 0;
  uint32_t observed = 0;
};

inline ShieldMasks ReduceShieldMasks(bool runtime_installed,
                                     bool subclass_live,
                                     bool observed_win32_transaction) {
  ShieldMasks masks;
  if (!runtime_installed) return masks;
  masks.required = kOwnedShieldSurfaces;
  masks.ready = subclass_live ? kOwnedShieldSurfaces : 0u;
  masks.observed =
      (subclass_live && observed_win32_transaction) ? kOwnedShieldSurfaces : 0u;
  return masks;
}

}  // namespace lookup_core
}  // namespace smash_fzmedia
}  // namespace fushi_voice_hook
