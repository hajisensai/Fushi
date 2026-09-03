// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 本文件目前用 Expect() + 返回码而非 assert，但守卫是**无条件**的结构规则：
// 保留这行，日后有人往本文件加 assert 时不会静默失活。守卫：
// native/galgame_hook/tests/assert_liveness_guard_test.py
#undef NDEBUG

#include "../window_recorder_ring.h"

#include <iostream>

namespace {

using fushi::window_recorder_ring::DownscaleBgraToBgr24;
using fushi::window_recorder_ring::ExportRange;
using fushi::window_recorder_ring::FitWidth;
using fushi::window_recorder_ring::FrameEntry;
using fushi::window_recorder_ring::FrameRing;
using fushi::window_recorder_ring::MinIntervalMs;
using fushi::window_recorder_ring::ResolveExportRange;
using fushi::window_recorder_ring::RingPolicy;
using fushi::window_recorder_ring::ScaledSize;
using fushi::window_recorder_ring::ShouldKeepFrame;

bool Expect(bool condition, const char* message) {
  if (condition)
    return true;
  std::cerr << message << '\n';
  return false;
}

std::vector<uint8_t> Blob(size_t bytes, uint8_t fill = 1) {
  return std::vector<uint8_t>(bytes, fill);
}

bool TestKeepByFps() {
  bool ok = true;
  ok &= Expect(MinIntervalMs(5) == 200, "5 fps -> 200 ms interval");
  ok &= Expect(MinIntervalMs(0) == 1000, "fps<=0 clamps to 1 fps");
  ok &= Expect(MinIntervalMs(100000) == 1, "fps clamps to 1000");
  ok &= Expect(ShouldKeepFrame(1000, false, 0, 5),
               "the first frame is always kept");
  ok &= Expect(!ShouldKeepFrame(1199, true, 1000, 5),
               "a frame inside the interval is dropped");
  ok &= Expect(ShouldKeepFrame(1200, true, 1000, 5),
               "a frame exactly one interval later is kept");
  ok &= Expect(ShouldKeepFrame(900, true, 1000, 5),
               "a backwards clock does not stall recording");
  return ok;
}

bool TestEvictBySeconds() {
  bool ok = true;
  RingPolicy policy;
  policy.max_seconds = 2;
  policy.max_bytes = 1 << 20;
  FrameRing ring(policy);
  ring.Push(1000, Blob(10));
  ring.Push(2000, Blob(10));
  ring.Push(3000, Blob(10));  // 1000 + 2000 == 3000 -> still inside window
  ok &= Expect(ring.size() == 3, "frames at the window edge are kept");
  ring.Push(3001, Blob(10));
  ok &= Expect(ring.size() == 3 && ring.frames().front().tick_ms == 2000,
               "frames older than max_seconds relative to the newest frame "
               "are evicted");
  ok &= Expect(ring.total_bytes() == 30, "byte accounting follows eviction");
  ring.Push(90000, Blob(10));
  ok &= Expect(ring.size() == 1 && ring.frames().front().tick_ms == 90000,
               "a big tick jump keeps only the newest frame");
  return ok;
}

bool TestEvictByBytes() {
  bool ok = true;
  RingPolicy policy;
  policy.max_seconds = 1000;
  policy.max_bytes = 25;
  FrameRing ring(policy);
  ring.Push(1, Blob(10));
  ring.Push(2, Blob(10));
  ok &= Expect(ring.size() == 2 && ring.total_bytes() == 20,
               "two frames under the byte cap stay");
  ring.Push(3, Blob(10));
  ok &= Expect(ring.size() == 2 && ring.frames().front().tick_ms == 2,
               "exceeding the byte cap evicts the oldest frame");
  ring.Push(4, Blob(100));
  ok &= Expect(ring.size() == 1 && ring.frames().front().tick_ms == 4 &&
                   ring.total_bytes() == 100,
               "an oversized newest frame is still kept alone");
  ring.Push(5, std::vector<uint8_t>());
  ok &= Expect(ring.size() == 1, "an empty encode result is not enqueued");
  ring.Clear();
  ok &= Expect(ring.empty() && ring.total_bytes() == 0, "Clear resets bytes");
  return ok;
}

bool TestExportRangeAndSelect() {
  bool ok = true;
  ExportRange r = ResolveExportRange(500, 0, 9000);
  ok &= Expect(r.valid && r.from == 500 && r.to == 9000,
               "to<=0 resolves to now");
  r = ResolveExportRange(-5, 700, 9000);
  ok &= Expect(r.valid && r.from == 0 && r.to == 700,
               "negative from clamps to zero, explicit to is honoured");
  r = ResolveExportRange(800, 700, 9000);
  ok &= Expect(!r.valid, "from > to is invalid");

  FrameRing ring;
  ring.Push(100, Blob(1, 0xA));
  ring.Push(300, Blob(1, 0xB));
  ring.Push(500, Blob(1, 0xC));
  ring.Push(700, Blob(1, 0xD));
  std::vector<FrameEntry> sel = ring.Select(300, 500);
  ok &= Expect(sel.size() == 2 && sel[0].tick_ms == 300 &&
                   sel[1].tick_ms == 500 && sel[1].jpeg[0] == 0xC,
               "Select is inclusive on both ends and ascending");
  ok &= Expect(ring.Select(701, 9000).empty(),
               "a range after the newest frame selects nothing");
  ok &= Expect(ring.Select(600, 100).empty(), "an inverted range is empty");
  ok &= Expect(ring.Select(0, 9000).size() == 4,
               "a range covering everything returns every frame");
  return ok;
}

bool TestFitWidth() {
  bool ok = true;
  ScaledSize s = FitWidth(1280, 720, 640);
  ok &= Expect(s.width == 640 && s.height == 360, "1280x720 -> 640x360");
  s = FitWidth(640, 480, 640);
  ok &= Expect(s.width == 640 && s.height == 480, "already fits: unchanged");
  s = FitWidth(320, 240, 640);
  ok &= Expect(s.width == 320 && s.height == 240, "never upscale");
  s = FitWidth(1000, 1, 100);
  ok &= Expect(s.width == 100 && s.height == 1, "height never rounds to 0");
  s = FitWidth(1280, 720, 0);
  ok &= Expect(s.width == 1280 && s.height == 720, "max_width 0 = no limit");
  return ok;
}

bool TestDownscale() {
  bool ok = true;
  // 4x2 BGRA，行距带 4 字节 padding；左半 (0,0,0) 右半 (100,200,40)；alpha 各异。
  const size_t stride = 4 * 4 + 4;
  std::vector<uint8_t> src(stride * 2, 0);
  for (uint32_t y = 0; y < 2; ++y) {
    for (uint32_t x = 0; x < 4; ++x) {
      uint8_t* p = src.data() + y * stride + x * 4;
      if (x >= 2) {
        p[0] = 100;
        p[1] = 200;
        p[2] = 40;
      }
      p[3] = static_cast<uint8_t>(x * 50);
    }
  }
  std::vector<uint8_t> out =
      DownscaleBgraToBgr24(src.data(), stride, 0, 0, 4, 2, 2, 1);
  ok &= Expect(out.size() == 6, "2x1 BGR24 output is 6 bytes");
  ok &= Expect(out.size() == 6 && out[0] == 0 && out[1] == 0 && out[2] == 0,
               "left box averages to black");
  ok &= Expect(out.size() == 6 && out[3] == 100 && out[4] == 200 &&
                   out[5] == 40,
               "right box averages to the fill colour (alpha dropped)");
  // 子矩形：只取右半 2x2 -> 1x1。
  out = DownscaleBgraToBgr24(src.data(), stride, 2, 0, 2, 2, 1, 1);
  ok &= Expect(out.size() == 3 && out[0] == 100, "crop offset is honoured");
  // 混合 box：整幅 4x2 -> 1x1，左右各半 -> 均值 50/100/20。
  out = DownscaleBgraToBgr24(src.data(), stride, 0, 0, 4, 2, 1, 1);
  ok &= Expect(out.size() == 3 && out[0] == 50 && out[1] == 100 &&
                   out[2] == 20,
               "a box spanning both halves averages them");
  // 非整数比例：4 -> 3 列，每列覆盖 [0,1) [1,2) [2,4)。
  out = DownscaleBgraToBgr24(src.data(), stride, 0, 0, 4, 2, 3, 1);
  ok &= Expect(out.size() == 9 && out[0] == 0 && out[3] == 0 && out[6] == 100,
               "non-integer ratios cover every source column exactly once");
  ok &= Expect(DownscaleBgraToBgr24(src.data(), stride, 0, 0, 4, 2, 5, 1)
                   .empty(),
               "upscaling requests are rejected");
  ok &= Expect(DownscaleBgraToBgr24(nullptr, stride, 0, 0, 4, 2, 2, 1).empty(),
               "null source is rejected");
  return ok;
}

}  // namespace

int main() {
  bool ok = true;
  ok &= TestKeepByFps();
  ok &= TestEvictBySeconds();
  ok &= TestEvictByBytes();
  ok &= TestExportRangeAndSelect();
  ok &= TestFitWidth();
  ok &= TestDownscale();
  return ok ? 0 : 1;
}
