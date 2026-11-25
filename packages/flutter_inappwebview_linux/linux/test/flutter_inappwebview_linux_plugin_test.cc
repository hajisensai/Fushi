#include <gtest/gtest.h>

#include <array>
#include <cstdint>

#include "../in_app_webview/simd_convert.h"

// Placeholder test for the flutter_inappwebview_linux plugin.
// More comprehensive tests can be added as features are implemented.

namespace flutter_inappwebview_plugin {
namespace test {

TEST(FlutterInappwebviewLinuxPlugin, Placeholder) {
  // This is a placeholder test to satisfy the CMake build.
  // Real tests should be added for the WebView functionality.
  EXPECT_TRUE(true);
}

TEST(FlutterInappwebviewLinuxPlugin, ConvertArgbPixelsWithPaddedSourceStride) {
  constexpr int width = 2;
  constexpr int height = 2;
  constexpr int source_stride = 12;
  const std::array<uint8_t, source_stride * height> source = {
      10, 20, 30, 255, 40, 50, 60, 255, 0, 0, 0, 0,
      70, 80, 90, 255, 100, 110, 120, 255, 0, 0, 0, 0,
  };
  std::array<uint8_t, width * height * 4> rgba{};

  flutter_inappwebview_plugin::ConvertARGB32ToRGBA(
      source.data(), rgba.data(), width, height, source_stride);

  const std::array<uint8_t, width * height * 4> expected = {
      30, 20, 10, 255, 60, 50, 40, 255,
      90, 80, 70, 255, 120, 110, 100, 255,
  };
  EXPECT_EQ(rgba, expected);
}

}  // namespace test
}  // namespace flutter_inappwebview_plugin
