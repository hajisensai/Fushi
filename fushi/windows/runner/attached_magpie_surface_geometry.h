#ifndef RUNNER_ATTACHED_MAGPIE_SURFACE_GEOMETRY_H_
#define RUNNER_ATTACHED_MAGPIE_SURFACE_GEOMETRY_H_

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <limits>

#include "attached_text_layout.h"

// Magpie publishes a source viewport and its presentation viewport in screen
// pixels.  Attached profiles remain normalized to the complete source client;
// this helper maps one such normalized body into the visible presentation and
// clips it to the destination viewport.
namespace fushi::attached_magpie_surface_geometry {

struct Mapping {
  RECT source_client_screen{};
  RECT source_viewport_screen{};
  RECT presentation_client_screen{};
  RECT destination_viewport_screen{};
};

inline bool RectHasArea(const RECT &rect) {
  return rect.right > rect.left && rect.bottom > rect.top;
}

inline bool RectContainedIn(const RECT &inner, const RECT &outer) {
  return inner.left >= outer.left && inner.top >= outer.top &&
         inner.right <= outer.right && inner.bottom <= outer.bottom;
}

inline bool IsMappingValid(const Mapping &mapping) {
  return RectHasArea(mapping.source_client_screen) &&
         RectHasArea(mapping.source_viewport_screen) &&
         RectHasArea(mapping.presentation_client_screen) &&
         RectHasArea(mapping.destination_viewport_screen) &&
         RectContainedIn(mapping.source_viewport_screen,
                         mapping.source_client_screen) &&
         RectContainedIn(mapping.destination_viewport_screen,
                         mapping.presentation_client_screen);
}

inline bool RoundToLong(double value, LONG *rounded) {
  if (rounded == nullptr || !std::isfinite(value) ||
      value < static_cast<double>(std::numeric_limits<LONG>::min()) ||
      value > static_cast<double>(std::numeric_limits<LONG>::max())) {
    return false;
  }
  *rounded = static_cast<LONG>(std::llround(value));
  return true;
}

inline bool ResolveSourceBodyRect(
    const RECT &source_client,
    const fushi::attached_text_layout::NormalizedRect &normalized_body,
    RECT *source_body_screen) {
  if (source_body_screen == nullptr || !RectHasArea(source_client) ||
      !fushi::attached_text_layout::IsNormalizedRectValid(normalized_body)) {
    return false;
  }
  const RECT body =
      fushi::attached_text_layout::ResolveBodyRect(source_client,
                                                   normalized_body);
  if (!RectHasArea(body) || !RectContainedIn(body, source_client))
    return false;
  *source_body_screen = body;
  return true;
}

inline bool MapSourceRectToDestination(const Mapping &mapping,
                                       const RECT &source_rect,
                                       RECT *destination_rect) {
  if (destination_rect == nullptr || !IsMappingValid(mapping) ||
      !RectHasArea(source_rect) ||
      !RectContainedIn(source_rect, mapping.source_client_screen)) {
    return false;
  }

  const double viewport_width = static_cast<double>(
      mapping.source_viewport_screen.right -
      mapping.source_viewport_screen.left);
  const double viewport_height = static_cast<double>(
      mapping.source_viewport_screen.bottom -
      mapping.source_viewport_screen.top);
  const double destination_width = static_cast<double>(
      mapping.destination_viewport_screen.right -
      mapping.destination_viewport_screen.left);
  const double destination_height = static_cast<double>(
      mapping.destination_viewport_screen.bottom -
      mapping.destination_viewport_screen.top);
  const auto map_x = [&](double value) {
    return static_cast<double>(mapping.destination_viewport_screen.left) +
           (value - static_cast<double>(mapping.source_viewport_screen.left)) *
               destination_width / viewport_width;
  };
  const auto map_y = [&](double value) {
    return static_cast<double>(mapping.destination_viewport_screen.top) +
           (value - static_cast<double>(mapping.source_viewport_screen.top)) *
               destination_height / viewport_height;
  };

  RECT mapped{};
  if (!RoundToLong(map_x(static_cast<double>(source_rect.left)),
                   &mapped.left) ||
      !RoundToLong(map_y(static_cast<double>(source_rect.top)),
                   &mapped.top) ||
      !RoundToLong(map_x(static_cast<double>(source_rect.right)),
                   &mapped.right) ||
      !RoundToLong(map_y(static_cast<double>(source_rect.bottom)),
                   &mapped.bottom) ||
      !RectHasArea(mapped)) {
    return false;
  }
  *destination_rect = mapped;
  return true;
}

// Magpie does not use the rectangle scale for the cursor.  Its cursor path
// keeps the first and last pixel aligned, so the denominator/numerator are
// (size - 1), and points outside the viewport continue with a 1:1 offset.
// Keep this separate from MapSourceRectToDestination: text boxes use an
// affine rectangle transform, while a cursor is a single pixel coordinate.
inline bool MapSourcePointToDestination(const Mapping &mapping,
                                        POINT source_point,
                                        POINT *destination_point) {
  if (destination_point == nullptr || !IsMappingValid(mapping))
    return false;

  const LONG source_width =
      mapping.source_viewport_screen.right -
      mapping.source_viewport_screen.left;
  const LONG source_height =
      mapping.source_viewport_screen.bottom -
      mapping.source_viewport_screen.top;
  const LONG destination_width =
      mapping.destination_viewport_screen.right -
      mapping.destination_viewport_screen.left;
  const LONG destination_height =
      mapping.destination_viewport_screen.bottom -
      mapping.destination_viewport_screen.top;
  if (source_width <= 1 || source_height <= 1 || destination_width <= 0 ||
      destination_height <= 0)
    return false;

  const auto map_axis = [](LONG value, LONG source_left, LONG source_right,
                           LONG destination_left, LONG destination_right,
                           LONG *mapped) {
    if (mapped == nullptr)
      return false;
    if (value < source_left) {
      const long long result = static_cast<long long>(destination_left) +
                               static_cast<long long>(value) - source_left;
      if (result < std::numeric_limits<LONG>::min() ||
          result > std::numeric_limits<LONG>::max())
        return false;
      *mapped = static_cast<LONG>(result);
      return true;
    }
    if (value >= source_right) {
      const long long result = static_cast<long long>(destination_right) +
                               static_cast<long long>(value) - source_right;
      if (result < std::numeric_limits<LONG>::min() ||
          result > std::numeric_limits<LONG>::max())
        return false;
      *mapped = static_cast<LONG>(result);
      return true;
    }

    const double position =
        static_cast<double>(value - source_left) /
        static_cast<double>(source_right - source_left - 1);
    // Magpie rounds the non-negative scaled delta first, then adds the
    // destination origin.  Rounding the absolute coordinate would differ by
    // one pixel for negative origins at half-pixel boundaries.
    const double delta =
        position * static_cast<double>(destination_right - destination_left - 1);
    LONG rounded_delta = 0;
    if (!RoundToLong(delta, &rounded_delta))
      return false;
    const long long result = static_cast<long long>(destination_left) +
                             static_cast<long long>(rounded_delta);
    if (result < std::numeric_limits<LONG>::min() ||
        result > std::numeric_limits<LONG>::max()) {
      return false;
    }
    *mapped = static_cast<LONG>(result);
    return true;
  };

  POINT mapped{};
  if (!map_axis(source_point.x, mapping.source_viewport_screen.left,
                mapping.source_viewport_screen.right,
                mapping.destination_viewport_screen.left,
                mapping.destination_viewport_screen.right, &mapped.x) ||
      !map_axis(source_point.y, mapping.source_viewport_screen.top,
                mapping.source_viewport_screen.bottom,
                mapping.destination_viewport_screen.top,
                mapping.destination_viewport_screen.bottom, &mapped.y)) {
    return false;
  }
  *destination_point = mapped;
  return true;
}

// A hit snapshot owns exactly one coordinate space.  An ordinary snapshot has
// no mapping and already uses destination pixels; a Magpie snapshot is valid
// only while its presentation window is capturing the cursor.
inline bool ResolveCursorPoint(const Mapping *mapping, bool cursor_captured,
                               POINT physical_point,
                               POINT *destination_point) {
  if (destination_point == nullptr) return false;
  if (mapping == nullptr) {
    *destination_point = physical_point;
    return true;
  }
  if (!cursor_captured) return false;
  return MapSourcePointToDestination(*mapping, physical_point,
                                     destination_point);
}

// A down/up pair must stay in the coordinate space selected at down time.  If
// Magpie stops capturing between them, reject the up so the caller cancels the
// lookup submission while still draining the physical button transaction.
inline bool ResolveCursorTransactionPoint(
    const Mapping *mapping, bool down_point_was_source_mapped,
    bool cursor_captured, POINT physical_point, POINT *destination_point) {
  if ((mapping != nullptr) != down_point_was_source_mapped) return false;
  return ResolveCursorPoint(mapping, cursor_captured, physical_point,
                            destination_point);
}

inline bool ClipRectTo(const RECT &rect, const RECT &clip, RECT *clipped) {
  if (clipped == nullptr || !RectHasArea(rect) || !RectHasArea(clip))
    return false;
  const RECT result{std::max(rect.left, clip.left),
                    std::max(rect.top, clip.top),
                    std::min(rect.right, clip.right),
                    std::min(rect.bottom, clip.bottom)};
  if (!RectHasArea(result))
    return false;
  *clipped = result;
  return true;
}

inline bool ResolveVisibleBody(
    const Mapping &mapping,
    const fushi::attached_text_layout::NormalizedRect &normalized_body,
    RECT *visible_body_screen) {
  if (visible_body_screen == nullptr ||
      !IsMappingValid(mapping) ||
      !fushi::attached_text_layout::IsNormalizedRectValid(normalized_body)) {
    return false;
  }

  RECT source_body{};
  if (!ResolveSourceBodyRect(mapping.source_client_screen, normalized_body,
                             &source_body)) {
    return false;
  }
  RECT mapped{};
  if (!MapSourceRectToDestination(mapping, source_body, &mapped) ||
      !ClipRectTo(mapped, mapping.destination_viewport_screen, &mapped)) {
    return false;
  }
  *visible_body_screen = mapped;
  return true;
}

}  // namespace fushi::attached_magpie_surface_geometry

#endif  // RUNNER_ATTACHED_MAGPIE_SURFACE_GEOMETRY_H_
