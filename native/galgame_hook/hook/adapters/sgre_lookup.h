#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace fushi_voice_hook {

// Exact RVA in the single executable admitted by sgre_profile.h. This is the
// TextRender draw boundary, not UserHook1's pre-layout routine at 0x328e0.
// At draw time the flattened glyph vector contains only the sentence that the
// player can currently see and its control codes have already gone through the
// game's own parser.
inline constexpr uintptr_t kSgreTextDrawRva = 0x35aa0u;
inline constexpr uintptr_t kSgreScenarioTextVtableRva = 0x5be330u;

inline constexpr int32_t kSgreDesignWidth = 1920;
inline constexpr int32_t kSgreDesignHeight = 1080;
inline constexpr float kSgreDialogueOriginX = 320.0f;
inline constexpr float kSgreDialogueOriginY = 830.0f;
inline constexpr float kSgreScenarioLineHeight = 80.0f;

struct SgreLookupGlyphGeometry {
  float x = 0.0f;
  float y = 0.0f;
  float width = 0.0f;
  float height = 0.0f;
  uint16_t line = 0;
};

struct SgreLookupRect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

// HookWorker samples input every 16 ms. A complete Shift press/release can
// happen between two samples, leaving the high bit clear even though Windows
// reports the transition in GetAsyncKeyState's low bit. Consume both signals:
// the high bit preserves the normal held-key edge, while the low bit recovers
// a tap that completed between polls. Never emit twice for one held press.
inline bool ConsumeSgreLookupShiftSample(uint16_t async_state,
                                         bool* last_down) {
  if (last_down == nullptr) return false;
  const bool down = (async_state & 0x8000u) != 0;
  const bool pressed_since_poll = (async_state & 0x0001u) != 0;
  const bool submit = (down && !*last_down) || (!down && pressed_since_poll);
  *last_down = down;
  return submit;
}

// The admitted renderer stores a flattened glyph list. A native line break
// resets the next glyph's x anchor instead of inserting a '\n' glyph. Derive
// the visual row from that reset so explicit and automatic game layout remain
// authoritative.
inline bool StartsNextSgreLookupLine(float previous_x, float current_x) {
  return std::isfinite(previous_x) && std::isfinite(current_x) &&
         current_x <= previous_x;
}

inline bool MatchesSgreScenarioDrawMetrics(float line_height,
                                           float glyph_height,
                                           bool has_horizontal_advance) {
  return std::isfinite(line_height) && std::isfinite(glyph_height) &&
         std::abs(line_height - kSgreScenarioLineHeight) <= 0.5f &&
         std::abs(glyph_height - kSgreScenarioLineHeight) <= 0.5f &&
         has_horizontal_advance;
}

inline bool IsSaneSgreLookupGlyph(const SgreLookupGlyphGeometry& glyph) {
  return std::isfinite(glyph.x) && std::isfinite(glyph.y) &&
         std::isfinite(glyph.width) && std::isfinite(glyph.height) &&
         glyph.x >= -64.0f && glyph.x <= 4096.0f && glyph.width > 0.0f &&
         glyph.width <= 256.0f && glyph.y >= -64.0f && glyph.y <= 2048.0f &&
         glyph.height > 0.0f && glyph.height <= 256.0f && glyph.line < 8;
}

inline bool SgreLookupRectForGlyph(const SgreLookupGlyphGeometry& glyph,
                                   int32_t client_width, int32_t client_height,
                                   SgreLookupRect* rect) {
  if (rect == nullptr || client_width <= 0 || client_height <= 0 ||
      !IsSaneSgreLookupGlyph(glyph)) {
    return false;
  }
  const float scale = std::min(
      static_cast<float>(client_width) / static_cast<float>(kSgreDesignWidth),
      static_cast<float>(client_height) /
          static_cast<float>(kSgreDesignHeight));
  const float offset_x =
      (static_cast<float>(client_width) - kSgreDesignWidth * scale) * 0.5f;
  const float offset_y =
      (static_cast<float>(client_height) - kSgreDesignHeight * scale) * 0.5f;
  // The admitted renderer mixes two domains exactly this way: the scenario
  // root is a 1920x1080 design anchor, while glyph+0x40/0x44 and the 80x80
  // texture cell are already physical draw units. The live 3840x2160 object
  // reports x=0,80,160 while its pre-draw layout field reports 0,25,50.
  rect->x = static_cast<int32_t>(
      std::lround(offset_x + kSgreDialogueOriginX * scale + glyph.x));
  rect->y = static_cast<int32_t>(
      std::lround(offset_y + kSgreDialogueOriginY * scale + glyph.y));
  rect->width =
      std::max<int32_t>(1, static_cast<int32_t>(std::lround(glyph.width)));
  rect->height =
      std::max<int32_t>(1, static_cast<int32_t>(std::lround(glyph.height)));
  return rect->x < client_width && rect->y < client_height &&
         rect->x + rect->width > 0 && rect->y + rect->height > 0;
}

// TextRender's glyph width is the font/texture box, not the horizontal
// advance. In the admitted SGRE build the real draw anchors normally advance
// 80 units, matching the 80-unit texture cell. Bound each hit cell by the next
// draw anchor anyway so punctuation and later font variants stay non-
// overlapping; for the row's last glyph reuse the previous advance. The raw
// box remains the fallback for a lone or malformed anchor sequence.
inline float SgreLookupHitWidth(const SgreLookupGlyphGeometry* glyphs,
                                size_t glyph_count, size_t glyph_index) {
  if (glyphs == nullptr || glyph_index >= glyph_count ||
      !IsSaneSgreLookupGlyph(glyphs[glyph_index])) {
    return 0.0f;
  }
  const auto& current = glyphs[glyph_index];
  if (glyph_index + 1 < glyph_count) {
    const auto& next = glyphs[glyph_index + 1];
    const float advance = next.x - current.x;
    if (next.line == current.line && std::isfinite(next.x) &&
        advance > 0.0f && advance <= 256.0f) {
      return std::min(current.width, advance);
    }
  }
  if (glyph_index != 0) {
    const auto& previous = glyphs[glyph_index - 1];
    const float advance = current.x - previous.x;
    if (previous.line == current.line && std::isfinite(previous.x) &&
        advance > 0.0f && advance <= 256.0f) {
      return std::min(current.width, advance);
    }
  }
  return current.width;
}

inline int FindSgreLookupGlyph(const SgreLookupGlyphGeometry* glyphs,
                               size_t glyph_count, int32_t client_width,
                               int32_t client_height, int32_t cursor_x,
                               int32_t cursor_y, SgreLookupRect* hit_rect) {
  if (glyphs == nullptr || glyph_count == 0) return -1;
  for (size_t i = 0; i < glyph_count; ++i) {
    SgreLookupGlyphGeometry hit_glyph = glyphs[i];
    hit_glyph.width = SgreLookupHitWidth(glyphs, glyph_count, i);
    SgreLookupRect rect;
    if (!SgreLookupRectForGlyph(hit_glyph, client_width, client_height,
                                &rect)) {
      continue;
    }
    if (cursor_x >= rect.x && cursor_y >= rect.y &&
        cursor_x < rect.x + rect.width && cursor_y < rect.y + rect.height) {
      if (hit_rect != nullptr) *hit_rect = rect;
      return static_cast<int>(i);
    }
  }
  return -1;
}

}  // namespace fushi_voice_hook
