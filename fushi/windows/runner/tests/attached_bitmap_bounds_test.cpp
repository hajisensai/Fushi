// Release builds keep these assertions live: this executable is a build gate.
#undef NDEBUG

#include "../attached_bitmap_bounds.h"

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <vector>

namespace {

constexpr std::uint32_t kGuard = 0x5a5aa5a5u;
constexpr std::uint32_t kMask = 0x01000000u;

bool SameRect(const RECT &left, const RECT &right) {
  return left.left == right.left && left.top == right.top &&
         left.right == right.right && left.bottom == right.bottom;
}

class GuardedPixels {
public:
  GuardedPixels(int width, int height)
      : width_(width),
        height_(height),
        pixels_(kGuardWords + static_cast<std::size_t>(width) *
                              static_cast<std::size_t>(height) +
                kGuardWords),
        pixels_begin_(pixels_.data() + kGuardWords) {
    std::fill(pixels_.begin(), pixels_.end(), kGuard);
    std::fill(pixels_begin_, pixels_begin_ + PixelCount(), 0u);
  }

  std::uint32_t *data() { return pixels_begin_; }

  std::size_t PixelCount() const {
    return static_cast<std::size_t>(width_) *
           static_cast<std::size_t>(height_);
  }

  std::uint32_t at(int x, int y) const {
    return pixels_begin_[static_cast<std::size_t>(y) *
                             static_cast<std::size_t>(width_) +
                         static_cast<std::size_t>(x)];
  }

  bool GuardsIntact() const {
    for (std::size_t index = 0; index < kGuardWords; ++index) {
      if (pixels_[index] != kGuard ||
          pixels_[pixels_.size() - kGuardWords + index] != kGuard) {
        return false;
      }
    }
    return true;
  }

private:
  static constexpr std::size_t kGuardWords = 8;

  int width_;
  int height_;
  std::vector<std::uint32_t> pixels_;
  std::uint32_t *pixels_begin_;
};

void ExpectFillCase(const char *name, const RECT &source,
                    const RECT &expected) {
  constexpr int kWidth = 6;
  constexpr int kHeight = 4;
  GuardedPixels bitmap(kWidth, kHeight);

  RECT clipped{99, 99, 99, 99};
  const bool intersects =
      fushi::attached_bitmap_bounds::ClipRectToSurface(
          source, kWidth, kHeight, &clipped);
  const bool expected_intersection = expected.right > expected.left &&
                                     expected.bottom > expected.top;
  assert(intersects == expected_intersection);
  if (expected_intersection)
    assert(SameRect(clipped, expected));

  fushi::attached_bitmap_bounds::FillRectClippedToSurface(
      bitmap.data(), kWidth, kHeight, source, kMask);
  assert(bitmap.GuardsIntact());

  for (int y = 0; y < kHeight; ++y) {
    for (int x = 0; x < kWidth; ++x) {
      const bool should_be_filled =
          expected_intersection && x >= expected.left && x < expected.right &&
          y >= expected.top && y < expected.bottom;
      assert(bitmap.at(x, y) == (should_be_filled ? kMask : 0u));
    }
  }
  (void)name;
}

} // namespace

int main() {
  // A stale calibration layout can cover the old full client while the DIB
  // already represents the much smaller configured body surface.
  ExpectFillCase("stale full client", RECT{0, 0, 1920, 1080},
                 RECT{0, 0, 6, 4});
  ExpectFillCase("negative origin", RECT{-3, -2, 2, 2}, RECT{0, 0, 2, 2});
  ExpectFillCase("outside right", RECT{7, 1, 12, 3}, RECT{});
  ExpectFillCase("outside left", RECT{-12, 1, -3, 3}, RECT{});
  ExpectFillCase("crosses right and bottom", RECT{4, 2, 12, 9},
                 RECT{4, 2, 6, 4});
  ExpectFillCase("crosses left and top", RECT{-2, -1, 3, 3},
                 RECT{0, 0, 3, 3});

  fushi::attached_bitmap_bounds::FillRectClippedToSurface(
      nullptr, 6, 4, RECT{0, 0, 6, 4}, kMask);
  fushi::attached_bitmap_bounds::FillRectClippedToSurface(
      nullptr, 0, 4, RECT{0, 0, 6, 4}, kMask);

  std::cout << "attached bitmap bounds and guarded writes passed\n";
  return 0;
}
