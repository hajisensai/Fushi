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

bool TestConfigurableCapsAndFps() {
  namespace p = flutter_webrtc_plugin;
  bool ok = true;
  p::OutputSize s = p::FitInsideEven(3840, 2160, 1280, 720);
  ok &= Expect(s.width == 1280 && s.height == 720, "4k fits 720p cap");
  s = p::FitInsideEven(3840, 2160, 3840, 2160);
  ok &= Expect(s.width == 3840 && s.height == 2160, "4k cap keeps 4k");
  s = p::FitInsideEven(800, 600, 1920, 1080);
  ok &= Expect(s.width == 800 && s.height == 600, "caps never upscale");
  s = p::FitInsideEven(1600, 1200, 1280, 720);
  ok &= Expect(s.width == 960 && s.height == 720,
               "4:3 frame bounded by height cap");
  s = p::FitInsideEven(2560, 1080, 854, 480);
  ok &= Expect(s.width == 854 && s.height == 360,
               "ultrawide bounded by width cap with even height");
  s = p::FitInsideEven(1920, 1080);
  ok &= Expect(s.width == 1920 && s.height == 1080, "default caps are 1080p");

  ok &= Expect(p::ClampCaptureMaxWidth(0) == 1920 &&
                   p::ClampCaptureMaxHeight(0) == 1080,
               "absent caps select 1920x1080");
  ok &= Expect(p::ClampCaptureMaxWidth(-5) == 1920 &&
                   p::ClampCaptureMaxHeight(-5) == 1080,
               "negative caps select defaults");
  ok &= Expect(p::ClampCaptureMaxWidth(100) == 320 &&
                   p::ClampCaptureMaxHeight(100) == 180,
               "tiny caps clamp to 320x180");
  ok &= Expect(p::ClampCaptureMaxWidth(10000) == 3840 &&
                   p::ClampCaptureMaxHeight(10000) == 2160,
               "huge caps clamp to 3840x2160");
  ok &= Expect(p::ClampCaptureMaxWidth(1280) == 1280 &&
                   p::ClampCaptureMaxHeight(720) == 720,
               "in-range caps pass through");

  ok &= Expect(p::ClampCaptureFps(120) == 120, "120 fps allowed");
  ok &= Expect(p::ClampCaptureFps(144) == 120, "fps clamps to 120");
  ok &= Expect(p::ClampCaptureFps(60) == 60, "60 fps passes through");
  ok &= Expect(p::ClampCaptureFps(0) == 1 && p::ClampCaptureFps(-3) == 1,
               "fps clamps to at least 1");
  return ok;
}

// Counts frames kept by the pacer over one second of [source_hz] arrivals
// with +/- [jitter_us] alternating jitter.
int KeptPerSecond(int fps, double source_hz, int64_t jitter_us) {
  flutter_webrtc_plugin::FramePacer pacer(fps);
  const double period_us = 1000000.0 / source_hz;
  int kept = 0;
  for (int i = 0; i < static_cast<int>(source_hz * 10); ++i) {
    const int64_t jitter = (i % 2 == 0) ? jitter_us : -jitter_us;
    const int64_t now = static_cast<int64_t>(i * period_us) + jitter;
    if (pacer.ShouldKeep(now)) ++kept;
  }
  return kept / 10;
}

bool TestFramePacer() {
  bool ok = true;
  // The old "now - last >= interval" rule kept ~30 of 60 jittered frames.
  const int at60 = KeptPerSecond(60, 60, 500);
  ok &= Expect(at60 >= 59 && at60 <= 60, "60 Hz source keeps 60 fps");
  const int from144 = KeptPerSecond(60, 144, 300);
  ok &= Expect(from144 >= 58 && from144 <= 61, "144 Hz source paces to 60");
  const int half = KeptPerSecond(30, 60, 500);
  ok &= Expect(half >= 29 && half <= 31, "60 Hz source paces to 30");
  const int slow = KeptPerSecond(120, 60, 0);
  ok &= Expect(slow == 60, "source slower than target keeps every frame");

  flutter_webrtc_plugin::FramePacer pacer(60);
  ok &= Expect(pacer.ShouldKeep(0), "first frame kept");
  ok &= Expect(!pacer.ShouldKeep(5000), "early frame dropped");
  // After a long idle gap the deadline restarts instead of bursting.
  ok &= Expect(pacer.ShouldKeep(5000000), "frame after idle gap kept");
  ok &= Expect(!pacer.ShouldKeep(5001000), "no burst after idle gap");
  return ok;
}

bool TestBilinearDownscale() {
  bool ok = true;
  // 4x2 source of alternating black/white columns; 2:1 must box-average to
  // mid grey instead of picking one column (nearest neighbour).
  const size_t stride = 4 * 4;
  std::vector<uint8_t> src(stride * 4, 0);
  for (uint32_t yy = 0; yy < 4; ++yy) {
    for (uint32_t xx = 0; xx < 4; ++xx) {
      uint8_t* p = src.data() + yy * stride + xx * 4;
      const uint8_t c = (xx % 2 == 0) ? 0 : 255;
      p[0] = p[1] = p[2] = c;
      p[3] = 255;
    }
  }
  std::vector<uint8_t> y, u, v;
  ok &= Expect(flutter_webrtc_plugin::ConvertBgraToI420(
                   src.data(), stride, 0, 0, 4, 4, 2, 2, &y, &u, &v),
               "2:1 downscale converts");
  if (!ok) return false;
  // Grey 128 → Y = ((66+129+25)*128 + 128 >> 8) + 16 = 126.
  for (size_t i = 0; i < y.size(); ++i) {
    ok &= Expect(y[i] >= 125 && y[i] <= 127, "2:1 is a box average");
  }
  ok &= Expect(u[0] == 128 && v[0] == 128, "grey has neutral chroma");

  // A reused converter gives identical output and survives a size change.
  flutter_webrtc_plugin::BgraToI420Converter converter;
  std::vector<uint8_t> y2, u2, v2;
  ok &= Expect(converter.Convert(src.data(), stride, 0, 0, 4, 4, 4, 4, &y2,
                                 &u2, &v2) &&
                   y2[0] == 16 && y2[1] == 235,
               "converter keeps 1:1 exact");
  ok &= Expect(converter.Convert(src.data(), stride, 0, 0, 4, 4, 2, 2, &y2,
                                 &u2, &v2) &&
                   y2 == y && u2 == u && v2 == v,
               "converter reuse matches one-shot conversion");

  std::vector<flutter_webrtc_plugin::ScaleTap> taps;
  flutter_webrtc_plugin::BuildScaleTaps(1920, 1280, &taps);
  bool in_range = taps.size() == 1280;
  for (const auto& tap : taps) {
    in_range &= tap.i0 < 1920 && tap.i1 < 1920 && tap.w1 < 256 &&
                tap.i1 >= tap.i0;
  }
  ok &= Expect(in_range, "1.5:1 taps stay inside the source");
  return ok;
}

bool TestIdleRepeat() {
  namespace p = flutter_webrtc_plugin;
  bool ok = true;
  ok &= Expect(!p::ShouldRepeatIdleFrame(false, 1000000, 0),
               "nothing to repeat before the first frame");
  ok &= Expect(!p::ShouldRepeatIdleFrame(true, 50000, 0),
               "a live stream is not duplicated");
  ok &= Expect(p::ShouldRepeatIdleFrame(true, p::kCaptureIdleRepeatUs, 0),
               "a still window repeats its last frame");
  return ok;
}

}  // namespace

int main() {
  bool ok = true;
  ok &= TestKnownColorsPaddedCrop();
  ok &= TestOddScalingAndBounds();
  ok &= TestConfigurableCapsAndFps();
  ok &= TestFramePacer();
  ok &= TestBilinearDownscale();
  ok &= TestIdleRepeat();
  if (!ok) return 1;
  std::cout << "game_stream_webrtc_capture_helper_test passed assertions="
            << g_assertions << "\n";
  return 0;
}
