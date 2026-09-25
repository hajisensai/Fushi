#ifndef RUNNER_ATTACHED_BITMAP_BOUNDS_H_
#define RUNNER_ATTACHED_BITMAP_BOUNDS_H_

#include <windows.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace fushi::attached_bitmap_bounds {

// Cluster rectangles are relative to the current surface.  A calibration
// surface can be replaced by a smaller configured surface before the next
// layout rebuild, so every DIB write must pass through this boundary.
inline bool ClipRectToSurface(const RECT &rect, int width, int height,
                              RECT *clipped) {
  if (clipped == nullptr || width <= 0 || height <= 0)
    return false;

  const LONG left = std::max(rect.left, 0L);
  const LONG top = std::max(rect.top, 0L);
  const LONG right = std::min(rect.right, static_cast<LONG>(width));
  const LONG bottom = std::min(rect.bottom, static_cast<LONG>(height));
  if (left >= right || top >= bottom)
    return false;

  *clipped = RECT{left, top, right, bottom};
  return true;
}

inline void FillRectClippedToSurface(uint32_t *pixels, int width, int height,
                                     const RECT &rect, uint32_t value) {
  if (pixels == nullptr)
    return;
  RECT clipped{};
  if (!ClipRectToSurface(rect, width, height, &clipped))
    return;

  for (LONG y = clipped.top; y < clipped.bottom; ++y) {
    for (LONG x = clipped.left; x < clipped.right; ++x) {
      pixels[static_cast<std::size_t>(y) * static_cast<std::size_t>(width) +
             static_cast<std::size_t>(x)] = value;
    }
  }
}

} // namespace fushi::attached_bitmap_bounds

#endif // RUNNER_ATTACHED_BITMAP_BOUNDS_H_
