#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

#include "luna_text_selector.h"

namespace fushi_voice_hook {

// Exact RVA in the single executable admitted by sgre_profile.h. This is the
// MAGES TextRender UTF-16 layout routine used by the existing Luna profile.
inline constexpr uintptr_t kSgreTextLayoutRva = 0x328e0u;

inline constexpr int32_t kSgreDesignWidth = 1920;
inline constexpr int32_t kSgreDesignHeight = 1080;
inline constexpr float kSgreDialogueOriginX = 320.0f;
inline constexpr float kSgreDialogueOriginY = 830.0f;
inline constexpr float kSgreFallbackLineHeight = 56.0f;

struct SgreLookupGlyphGeometry {
  float x = 0.0f;
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

enum class SgreLookupActiveUpdate : uint8_t {
  kIgnore,
  kReplace,
};

// TextRender also runs for transient/system surfaces whose layout has no
// usable glyphs or exposes a text/glyph count from a different render surface.
// Those calls must not erase the last valid scenario line: in the admitted
// SGRE build they continuously follow each dialogue layout and would otherwise
// make Shift lookup miss every visible line. TextRender exposes one visual row
// at a time, so a wrapped line can have more normalized units than this capture
// has glyphs; the caller maps only the captured prefix. A capture may replace
// the active row only when every glyph in that row has a character index and
// the full line reaches the same minimum length used by the mining resolver.
inline SgreLookupActiveUpdate ResolveSgreLookupActiveUpdate(
    bool capture_valid, size_t normalized_units, size_t mapped_glyphs,
    size_t captured_glyphs) {
  if (!capture_valid) return SgreLookupActiveUpdate::kIgnore;
  if (normalized_units >= 8 && captured_glyphs != 0 &&
      mapped_glyphs == captured_glyphs) {
    return SgreLookupActiveUpdate::kReplace;
  }
  return SgreLookupActiveUpdate::kIgnore;
}

inline bool IsSaneSgreLookupGlyph(const SgreLookupGlyphGeometry& glyph) {
  return std::isfinite(glyph.x) && std::isfinite(glyph.width) &&
         std::isfinite(glyph.height) && glyph.x >= -64.0f &&
         glyph.x <= 2048.0f && glyph.width > 0.0f && glyph.width <= 256.0f &&
         glyph.height > 0.0f && glyph.height <= 256.0f && glyph.line < 8;
}

inline bool SgreLookupRectForGlyph(const SgreLookupGlyphGeometry& glyph,
                                   float line_height, int32_t client_width,
                                   int32_t client_height,
                                   SgreLookupRect* rect) {
  if (rect == nullptr || client_width <= 0 || client_height <= 0 ||
      !IsSaneSgreLookupGlyph(glyph)) {
    return false;
  }
  if (!std::isfinite(line_height) || line_height < 16.0f ||
      line_height > 160.0f) {
    line_height = kSgreFallbackLineHeight;
  }
  const float scale = std::min(
      static_cast<float>(client_width) / static_cast<float>(kSgreDesignWidth),
      static_cast<float>(client_height) /
          static_cast<float>(kSgreDesignHeight));
  const float offset_x =
      (static_cast<float>(client_width) - kSgreDesignWidth * scale) * 0.5f;
  const float offset_y =
      (static_cast<float>(client_height) - kSgreDesignHeight * scale) * 0.5f;
  const float glyph_height = std::max(glyph.height, line_height * 0.75f);
  rect->x = static_cast<int32_t>(
      std::lround(offset_x + (kSgreDialogueOriginX + glyph.x) * scale));
  rect->y = static_cast<int32_t>(
      std::lround(offset_y + (kSgreDialogueOriginY +
                              static_cast<float>(glyph.line) * line_height) *
                                 scale));
  rect->width = std::max<int32_t>(
      1, static_cast<int32_t>(std::lround(glyph.width * scale)));
  rect->height = std::max<int32_t>(
      1, static_cast<int32_t>(std::lround(glyph_height * scale)));
  return rect->x < client_width && rect->y < client_height &&
         rect->x + rect->width > 0 && rect->y + rect->height > 0;
}

inline int FindSgreLookupGlyph(const SgreLookupGlyphGeometry* glyphs,
                               size_t glyph_count, float line_height,
                               int32_t client_width, int32_t client_height,
                               int32_t cursor_x, int32_t cursor_y,
                               SgreLookupRect* hit_rect) {
  if (glyphs == nullptr || glyph_count == 0) return -1;
  for (size_t i = 0; i < glyph_count; ++i) {
    SgreLookupRect rect;
    if (!SgreLookupRectForGlyph(glyphs[i], line_height, client_width,
                                client_height, &rect)) {
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
