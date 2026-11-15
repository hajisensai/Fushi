#ifndef RUNNER_ATTACHED_MEASURED_LAYOUT_H_
#define RUNNER_ATTACHED_MEASURED_LAYOUT_H_

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "attached_magpie_surface_geometry.h"
#include "attached_text_layout.h"

// Measured-layout mode of the attached text surface.
//
// The calibrated route lays the hooked sentence out again with DirectWrite
// inside a user-calibrated body rectangle.  Engines that can report where they
// actually drew every glyph (TyranoScript through the Chromium DOM) skip that
// approximation: the caller sends one rectangle per glyph in the *source*
// window's client area, in physical pixels, and the surface only maps those
// rectangles onto the screen.  Nothing here stretches or re-flows measurements:
// a measurement taken for a different client size is rejected as stale.
//
// Coordinate contract: (0, 0) is the top-left pixel of the game's top-level
// source window client area (the HWND the surface is bound to, i.e. what
// ClientToScreen(hwnd, {0,0}) returns under per-monitor DPI awareness v2);
// x grows right, y grows down; right/bottom are exclusive; units are physical
// device pixels.  Under Magpie this is still the *source* client, not the
// scaled presentation window.
namespace fushi::attached_measured_layout {

using ClusterBox = fushi::attached_text_layout::ClusterBox;
using Mapping = fushi::attached_magpie_surface_geometry::Mapping;

// Wire layout of one glyph in the flat Int32List: [start, length, l, t, r, b].
inline constexpr size_t kWordsPerGlyph = 6;
// Matches the attached surface's own source-text bound; a glyph covers at
// least one UTF-16 unit, so more glyphs than units is always malformed.
inline constexpr size_t kMaximumGlyphs = 32768;
// Same wire identity as the Dart/native TyranoDom geometry provider
// (runtime_layout kind 1, id 6).  Only an allow-listed measured source may
// drive the surface; the string is diagnostic identity, not a registry owner.
inline constexpr char kSourceTyranoDom[] = "tyrano_dom";

struct MeasuredGlyph {
  uint32_t text_position = 0;
  uint32_t text_length = 0;
  // Source-client physical pixels, right/bottom exclusive.
  RECT client_rect{};
};

inline bool IsSupportedSource(const std::string &source) {
  return source == kSourceTyranoDom;
}

inline bool IsHighSurrogate(wchar_t value) {
  return value >= 0xD800 && value <= 0xDBFF;
}

inline bool IsLowSurrogate(wchar_t value) {
  return value >= 0xDC00 && value <= 0xDFFF;
}

// True when |index| does not split a surrogate pair of |text|.
inline bool IsCodePointBoundary(const std::wstring &text, size_t index) {
  if (index == 0 || index >= text.size())
    return index <= text.size();
  return !(IsLowSurrogate(text[index]) && IsHighSurrogate(text[index - 1]));
}

// Decodes and validates the compact glyph list.  Every rejection names its
// rule so a refused DOM snapshot can be diagnosed from the channel reply.
// Rectangles must be non-empty and lie inside [0, client_width] x
// [0, client_height]: the source measured them against exactly that client.
inline bool DecodeGlyphs(const int32_t *words, size_t word_count,
                         const std::wstring &source_text, int client_width,
                         int client_height, std::vector<MeasuredGlyph> *glyphs,
                         std::string *error) {
  const auto fail = [error](const char *reason) {
    if (error != nullptr)
      *error = reason;
    return false;
  };
  if (glyphs == nullptr)
    return fail("measured_glyphs_invalid");
  if (client_width <= 0 || client_height <= 0)
    return fail("measured_client_size_invalid");
  if (word_count % kWordsPerGlyph != 0)
    return fail("measured_glyphs_malformed");
  const size_t glyph_count = word_count / kWordsPerGlyph;
  if (source_text.empty()) {
    if (glyph_count != 0)
      return fail("measured_glyphs_without_text");
    glyphs->clear();
    return true;
  }
  if (glyph_count == 0 || words == nullptr)
    return fail("measured_glyphs_empty");
  if (glyph_count > kMaximumGlyphs || glyph_count > source_text.size())
    return fail("measured_glyphs_too_many");

  std::vector<MeasuredGlyph> decoded;
  decoded.reserve(glyph_count);
  for (size_t index = 0; index < glyph_count; ++index) {
    const int32_t *entry = words + index * kWordsPerGlyph;
    const int64_t start = entry[0];
    const int64_t length = entry[1];
    if (start < 0 || length <= 0 ||
        start + length > static_cast<int64_t>(source_text.size())) {
      return fail("measured_glyph_range_invalid");
    }
    if (!IsCodePointBoundary(source_text, static_cast<size_t>(start)) ||
        !IsCodePointBoundary(source_text, static_cast<size_t>(start + length))) {
      return fail("measured_glyph_splits_surrogate");
    }
    const RECT rect{entry[2], entry[3], entry[4], entry[5]};
    if (rect.right <= rect.left || rect.bottom <= rect.top)
      return fail("measured_glyph_rect_empty");
    if (rect.left < 0 || rect.top < 0 || rect.right > client_width ||
        rect.bottom > client_height) {
      return fail("measured_glyph_rect_outside_client");
    }
    MeasuredGlyph glyph;
    glyph.text_position = static_cast<uint32_t>(start);
    glyph.text_length = static_cast<uint32_t>(length);
    glyph.client_rect = rect;
    decoded.push_back(glyph);
  }
  *glyphs = std::move(decoded);
  return true;
}

// Upper bound for the caller-declared size quantization (physical px).  The
// DOM source derives its client size from an integer CSS viewport times a
// fractional devicePixelRatio, so the real client can differ by less than one
// CSS pixel (e.g. Electron fullscreen at 150%: client 3840x2159, viewport
// 2560x1440 CSS -> 3840x2160).  Anything larger is a real layout difference
// (menu bar, mid-resize) and must still be rejected.
inline constexpr int kMaxClientSizeTolerance = 4;

// A measurement is only valid for the source client size it was taken
// against, up to |tolerance| physical pixels of quantization declared by the
// producer (clamped to [0, kMaxClientSizeTolerance]).  Position changes are
// harmless (the rectangles are client-relative); a larger size change means
// the DOM reflowed or the window is mid-resize.
inline bool ClientSizeMatches(int measured_width, int measured_height,
                              int tolerance,
                              const RECT &source_client_screen) {
  if (measured_width <= 0 || measured_height <= 0)
    return false;
  const int slack = tolerance < 0                         ? 0
                    : tolerance > kMaxClientSizeTolerance ? kMaxClientSizeTolerance
                                                          : tolerance;
  const int dw =
      (source_client_screen.right - source_client_screen.left) - measured_width;
  const int dh =
      (source_client_screen.bottom - source_client_screen.top) - measured_height;
  return dw >= -slack && dw <= slack && dh >= -slack && dh <= slack;
}

// Source-client rectangle -> source screen (client origin) -> presentation
// screen (Magpie viewport, identity without Magpie) -> clipped to the surface
// -> surface-local.  Returns false when nothing of the glyph is visible.
inline bool MapClientRectToSurfaceLocal(const Mapping &mapping,
                                        const RECT &client_rect,
                                        const RECT &surface_screen,
                                        RECT *surface_local) {
  using fushi::attached_magpie_surface_geometry::ClipRectTo;
  using fushi::attached_magpie_surface_geometry::MapSourceRectToDestination;
  using fushi::attached_magpie_surface_geometry::RectHasArea;
  if (surface_local == nullptr || !RectHasArea(client_rect) ||
      !RectHasArea(surface_screen)) {
    return false;
  }
  RECT source_screen = client_rect;
  OffsetRect(&source_screen, mapping.source_client_screen.left,
             mapping.source_client_screen.top);
  RECT mapped{};
  if (!MapSourceRectToDestination(mapping, source_screen, &mapped))
    return false;
  RECT clipped{};
  if (!ClipRectTo(mapped, surface_screen, &clipped))
    return false;
  OffsetRect(&clipped, -surface_screen.left, -surface_screen.top);
  if (!RectHasArea(clipped))
    return false;
  *surface_local = clipped;
  return true;
}

// Builds the surface's catch boxes.  hit_rect and visual_rect are both the
// measured glyph box: measured input is exact, so no padding is invented.
// Glyphs that a Magpie crop leaves invisible are dropped; if none remain the
// build fails with a named reason.
inline bool BuildClusters(const Mapping &mapping, const RECT &surface_screen,
                          const std::vector<MeasuredGlyph> &glyphs,
                          std::vector<ClusterBox> *clusters,
                          std::string *reason) {
  const auto fail = [reason](const char *value) {
    if (reason != nullptr)
      *reason = value;
    return false;
  };
  if (clusters == nullptr)
    return fail("measured_clusters_invalid");
  if (!fushi::attached_magpie_surface_geometry::IsMappingValid(mapping))
    return fail("measured_mapping_invalid");
  if (glyphs.empty())
    return fail("measured_glyphs_empty");
  std::vector<ClusterBox> built;
  built.reserve(glyphs.size());
  for (const MeasuredGlyph &glyph : glyphs) {
    RECT local{};
    if (!MapClientRectToSurfaceLocal(mapping, glyph.client_rect,
                                     surface_screen, &local)) {
      continue;
    }
    ClusterBox box;
    box.text_position = glyph.text_position;
    box.text_length = glyph.text_length;
    box.hit_rect = local;
    box.visual_rect = local;
    built.push_back(box);
  }
  if (built.empty())
    return fail("measured_clusters_not_visible");
  *clusters = std::move(built);
  if (reason != nullptr)
    reason->clear();
  return true;
}

} // namespace fushi::attached_measured_layout

#endif // RUNNER_ATTACHED_MEASURED_LAYOUT_H_
