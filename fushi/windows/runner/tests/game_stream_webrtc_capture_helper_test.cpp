#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

#include "../game_stream_webrtc_capture_helpers.h"

namespace {

int g_assertions = 0;

bool Expect(bool condition, const char* message) {
  ++g_assertions;
  if (!condition) {
    std::cerr << "FAIL: " << message << "\n";
    return false;
  }
  return true;
}

bool TestKnownColorsPaddedCrop() {
  bool ok = true;
  const size_t stride = 4 * 4 + 4;
  std::vector<uint8_t> src(stride * 4, 0xEE);
  auto set = [&](uint32_t x, uint32_t y, uint8_t b, uint8_t g, uint8_t r) {
    uint8_t* p = src.data() + y * stride + x * 4;
    p[0] = b;
    p[1] = g;
    p[2] = r;
    p[3] = 255;
  };
  set(1, 1, 0, 0, 0);        // black: Y=16
  set(2, 1, 255, 255, 255);  // white: Y=235
  set(1, 2, 0, 0, 255);      // red: Y=82
  set(2, 2, 255, 0, 0);      // blue: Y=41

  std::vector<uint8_t> y, u, v;
  ok &= Expect(flutter_webrtc_plugin::ConvertBgraToI420(
                   src.data(), stride, 1, 1, 2, 2, 2, 2, &y, &u, &v),
               "2x2 padded crop converts");
  ok &= Expect(y.size() == 4, "Y plane size");
  ok &= Expect(u.size() == 1, "U plane size");
  ok &= Expect(v.size() == 1, "V plane size");
  if (!ok) return false;

  ok &= Expect(y[0] == 16, "black Y is BT.601 limited-range 16");
  ok &= Expect(y[1] == 235, "white Y is BT.601 limited-range 235");
  ok &= Expect(y[2] == 82, "red Y is BT.601 limited-range 82");
  ok &= Expect(y[3] == 41, "blue Y is BT.601 limited-range 41");
  // Average over black, white, red, blue gives B=127 G=63 R=127.
  ok &= Expect(u[0] == 147, "averaged chroma U for B127 G63 R127");
  ok &= Expect(v[0] == 152, "averaged chroma V for B127 G63 R127");
  return ok;
}

bool TestOddScalingAndBounds() {
  bool ok = true;
  flutter_webrtc_plugin::OutputSize s =
      flutter_webrtc_plugin::FitInsideEven(1919, 1079);
  ok &= Expect(s.width == 1918 && s.height == 1078,
               "odd dimensions become even");
  s = flutter_webrtc_plugin::FitInsideEven(3840, 2160);
  ok &= Expect(s.width == 1920 && s.height == 1080,
               "4k clamps to 1080p");
  s = flutter_webrtc_plugin::FitInsideEven(4000, 1000);
  ok &= Expect(s.width == 1920 && s.height == 480,
               "wide frame clamps by width");
  s = flutter_webrtc_plugin::FitInsideEven(1000, 4000);
  ok &= Expect(s.width == 270 && s.height == 1080,
               "tall frame clamps by height and even width");

  const size_t stride = 5 * 4 + 8;
  std::vector<uint8_t> src(stride * 5, 0);
  for (uint32_t yy = 0; yy < 5; ++yy) {
    for (uint32_t xx = 0; xx < 5; ++xx) {
      uint8_t* p = src.data() + yy * stride + xx * 4;
      p[0] = static_cast<uint8_t>(xx * 20);
      p[1] = static_cast<uint8_t>(yy * 30);
      p[2] = static_cast<uint8_t>((xx + yy) * 10);
      p[3] = 255;
    }
  }
  std::vector<uint8_t> y, u, v;
  ok &= Expect(flutter_webrtc_plugin::ConvertBgraToI420(
                   src.data(), stride, 1, 1, 3, 3, 2, 2, &y, &u, &v),
               "odd crop can scale to even output");
  ok &= Expect(y.size() == 4 && u.size() == 1 && v.size() == 1,
               "odd crop output plane sizes");
  ok &= Expect(!flutter_webrtc_plugin::ConvertBgraToI420(
                   src.data(), stride, 0, 0, 1, 1, 1, 1, &y, &u, &v),
               "reject dimensions too small/odd output");
  ok &= Expect(!flutter_webrtc_plugin::ConvertBgraToI420(
                   src.data(), 8, 1, 0, 2, 2, 2, 2, &y, &u, &v),
               "reject stride narrower than cropped source row");
  return ok;
}

}  // namespace

int main() {
  bool ok = true;
  ok &= TestKnownColorsPaddedCrop();
  ok &= TestOddScalingAndBounds();
  if (!ok) return 1;
  std::cout << "game_stream_webrtc_capture_helper_test passed assertions="
            << g_assertions << "\n";
  return 0;
}
