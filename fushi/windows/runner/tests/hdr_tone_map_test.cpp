// release 也要真断言：NDEBUG 会把 assert 编成空语句，测试就会空跑照样"通过"。
#undef NDEBUG

#include "../hdr_capture_policy.h"
#include "../hdr_tone_map.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

using namespace fushi::hdr_tone_map;

// float → binary16（就近舍入，测试里只用于正常范围的正数与 0 / 负数）。
uint16_t FloatToHalf(float f) {
  uint32_t bits;
  std::memcpy(&bits, &f, sizeof(bits));
  const uint32_t sign = (bits >> 16) & 0x8000u;
  int32_t exponent = static_cast<int32_t>((bits >> 23) & 0xFFu) - 127 + 15;
  uint32_t mantissa = bits & 0x7FFFFFu;
  if (((bits >> 23) & 0xFFu) == 0xFFu) {
    return static_cast<uint16_t>(sign | (mantissa != 0 ? 0x7E00u : 0x7C00u));
  }
  if (exponent <= 0) {
    if (exponent < -10) return static_cast<uint16_t>(sign);
    mantissa |= 0x800000u;
    const uint32_t shift = static_cast<uint32_t>(14 - exponent);
    uint32_t half = mantissa >> shift;
    if ((mantissa >> (shift - 1)) & 1u) ++half;
    return static_cast<uint16_t>(sign | half);
  }
  if (exponent >= 31) return static_cast<uint16_t>(sign | 0x7C00u);
  uint32_t half = (static_cast<uint32_t>(exponent) << 10) | (mantissa >> 13);
  if (mantissa & 0x1000u) ++half;  // 进位可自然溢到指数
  return static_cast<uint16_t>(sign | half);
}

struct Pixel {
  float r, g, b;
};

// 把一组 scRGB 像素编成 RGBA16F，过一遍色调映射，返回 BGRA。
std::vector<uint8_t> Run(const std::vector<Pixel>& pixels, float white_nits,
                         ToneMapStats* stats = nullptr, size_t pad_bytes = 0) {
  const int width = static_cast<int>(pixels.size());
  const size_t pitch = static_cast<size_t>(width) * 8 + pad_bytes;
  std::vector<uint8_t> src(pitch, 0xCD);
  for (int x = 0; x < width; ++x) {
    const uint16_t h[4] = {FloatToHalf(pixels[x].r), FloatToHalf(pixels[x].g),
                           FloatToHalf(pixels[x].b), FloatToHalf(1.0f)};
    std::memcpy(src.data() + x * 8, h, sizeof(h));
  }
  std::vector<uint8_t> out(static_cast<size_t>(width) * 4);
  const ToneMapStats s =
      ToneMapScRgbToBgra8(src.data(), pitch, width, 1, white_nits, out.data());
  if (stats != nullptr) *stats = s;
  return out;
}

// DWM 在 HDR 模式下把 SDR 窗口像素 code（sRGB 8bit）合成成的 scRGB 值。
float SdrCodeToScRgb(int code, float white_nits) {
  return static_cast<float>(SrgbToLinear(code / 255.0)) *
         (white_nits / 80.0f);
}

}  // namespace

int main() {
  // ── half 解码 ──────────────────────────────────────────────────────────
  {
    assert(HalfToFloat(0x0000) == 0.0f);
    assert(HalfToFloat(0x3C00) == 1.0f);
    assert(HalfToFloat(0xC000) == -2.0f);
    assert(HalfToFloat(0x3800) == 0.5f);
    assert(HalfToFloat(0x7BFF) == 65504.0f);
    assert(HalfToFloat(0x0001) == std::ldexp(1.0f, -24));  // 最小次正规数
    assert(HalfToFloat(0x03FF) == std::ldexp(1023.0f, -24));
    assert(std::isinf(HalfToFloat(0x7C00)));
    assert(std::isnan(HalfToFloat(0x7E00)));
    // 往返：测试用编码器与解码器一致。
    for (float f : {0.0f, 0.25f, 1.0f, 3.0f, 12.5f, 0.001f}) {
      assert(std::fabs(HalfToFloat(FloatToHalf(f)) - f) <= f * 1e-3f + 1e-7f);
    }
  }

  // ── 参考白 ────────────────────────────────────────────────────────────
  {
    assert(ReferenceWhiteScRgb(240.0f) == 3.0f);
    assert(ReferenceWhiteScRgb(80.0f) == 1.0f);
    // 查不到（0）/ 非法：按 80 nit（scRGB 1.0）兜底。
    assert(ReferenceWhiteScRgb(0.0f) == 1.0f);
    assert(ReferenceWhiteScRgb(-5.0f) == 1.0f);
    assert(ReferenceWhiteScRgb(NAN) == 1.0f);
  }

  // ── sRGB 编码器 = round(OETF * 255) ───────────────────────────────────
  {
    const SrgbEncoder enc;
    for (int code = 0; code <= 255; ++code) {
      assert(enc.Encode(static_cast<float>(SrgbToLinear(code / 255.0))) ==
             code);
    }
    assert(enc.Encode(-1.0f) == 0);
    assert(enc.Encode(NAN) == 0);
    assert(enc.Encode(2.0f) == 255);
  }

  // ── 核心：整屏 SDR 内容在各种「SDR 内容亮度」下逐级还原 ──────────────
  // 这就是 BUG 本身：BitBlt 在 HDR 下拿到的是被抬亮的帧（整屏发白）。
  for (float white : {80.0f, 120.0f, 200.0f, 240.0f, 480.0f}) {
    std::vector<Pixel> pixels;
    for (int code = 0; code <= 255; ++code) {
      const float v = SdrCodeToScRgb(code, white);
      pixels.push_back({v, v, v});
    }
    // 彩色 SDR 像素也要原样回来（各通道独立）。
    pixels.push_back({SdrCodeToScRgb(0x67, white), SdrCodeToScRgb(0x50, white),
                      SdrCodeToScRgb(0xA4, white)});
    ToneMapStats stats;
    const std::vector<uint8_t> out = Run(pixels, white, &stats);
    assert(std::fabs(stats.reference_white_scrgb - white / 80.0f) < 1e-6f);
    // 纯 SDR 帧峰值 ≈ 1（half 量化），走恒等支路。
    assert(stats.peak <= 1.0f + 1e-3f);
    int max_error = 0;
    for (int code = 0; code <= 255; ++code) {
      const uint8_t* px = out.data() + code * 4;
      assert(px[0] == px[1] && px[1] == px[2]);
      assert(px[3] == 0xFF);
      max_error = std::max(max_error, std::abs(px[0] - code));
    }
    // half 只有 11 位尾数：允许 1 级量化误差，但黑与白必须精确。
    assert(max_error <= 1);
    assert(out[0] == 0 && out[255 * 4] == 255);
    const uint8_t* color = out.data() + 256 * 4;
    assert(std::abs(color[2] - 0x67) <= 1);
    assert(std::abs(color[1] - 0x50) <= 1);
    assert(std::abs(color[0] - 0xA4) <= 1);
  }

  // ── 不做参考白归一（旧行为 = 按 80 nit 理解）会发白：反证测试有效 ─────
  {
    const float white = 240.0f;
    const float mid_gray = SdrCodeToScRgb(128, white);
    const std::vector<uint8_t> wrong = Run({{mid_gray, mid_gray, mid_gray}}, 80.0f);
    assert(wrong[0] > 200);  // 中灰被抬成接近白
    const std::vector<uint8_t> right =
        Run({{mid_gray, mid_gray, mid_gray}}, white);
    assert(std::abs(right[0] - 128) <= 1);
  }

  // ── 白电平查不到：按 80 nit 兜底 ──────────────────────────────────────
  {
    const float v = SdrCodeToScRgb(100, 80.0f);
    const std::vector<uint8_t> out = Run({{v, v, v}}, 0.0f);
    assert(std::abs(out[0] - 100) <= 1);
  }

  // ── 压缩曲线：连续、单调、端点 ───────────────────────────────────────
  {
    // 峰值 ≤ 1：恒等并钳 [0,1]。
    assert(CompressHighlight(0.5f, 1.0f) == 0.5f);
    assert(CompressHighlight(1.2f, 0.9f) == 1.0f);
    assert(CompressHighlight(-1.0f, 4.0f) == 0.0f);
    for (float peak : {1.01f, 1.5f, 4.0f, 12.5f, 125.0f}) {
      // knee 以下恒等。
      assert(CompressHighlight(0.5f, peak) == 0.5f);
      assert(CompressHighlight(kKnee, peak) == kKnee);
      // 峰值落到白，超过峰值也是白。
      assert(std::fabs(CompressHighlight(peak, peak) - 1.0f) < 1e-5f);
      assert(CompressHighlight(peak * 2.0f, peak) == 1.0f);
      // knee 处一阶导连续（≈1）。
      const float eps = 1e-3f;
      const float slope =
          (CompressHighlight(kKnee + eps, peak) - CompressHighlight(kKnee, peak)) /
          eps;
      assert(std::fabs(slope - 1.0f) < 0.02f);
      // 单调不减、不超过 1。
      float prev = 0.0f;
      for (int i = 0; i <= 2000; ++i) {
        const float x = peak * static_cast<float>(i) / 2000.0f;
        const float y = CompressHighlight(x, peak);
        assert(y + 1e-6f >= prev);
        assert(y <= 1.0f + 1e-6f);
        prev = y;
      }
    }
  }

  // ── 有 HDR 高光的帧：高光不再一刀切成同一个白、保持层次与色相 ─────────
  {
    const float white = 200.0f;  // 参考白 2.5（scRGB）
    const float w = white / 80.0f;
    std::vector<Pixel> pixels = {
        {0.0f, 0.0f, 0.0f},                // 黑
        {0.3f * w, 0.3f * w, 0.3f * w},    // 暗部（knee 以下，恒等）
        {1.5f * w, 1.5f * w, 1.5f * w},    // 高光 1.5×白
        {3.0f * w, 3.0f * w, 3.0f * w},    // 高光 3×白
        {6.0f * w, 6.0f * w, 6.0f * w},    // 峰值 6×白
        {4.0f * w, 2.0f * w, 0.0f},        // 橙色高光
        {-0.2f, 0.5f * w, 0.1f * w},       // 广色域负值
    };
    ToneMapStats stats;
    const std::vector<uint8_t> out = Run(pixels, white, &stats);
    assert(std::fabs(stats.peak - 6.0f) < 0.01f);
    const SrgbEncoder enc;
    assert(out[0 * 4] == 0);
    assert(out[1 * 4] == enc.Encode(0.3f) ||
           std::abs(out[1 * 4] - enc.Encode(0.3f)) <= 1);
    const int h15 = out[2 * 4], h3 = out[3 * 4], h6 = out[4 * 4];
    assert(h15 < h3 && h3 < h6);  // 层次保留（旧行为三者都是 255）
    assert(h6 == 255);
    assert(h15 > enc.Encode(kKnee));
    // 橙色：R > G > B=0，色相不被冲成白。
    const uint8_t* orange = out.data() + 5 * 4;
    assert(orange[2] > orange[1] && orange[1] > orange[0] && orange[0] == 0);
    // 负值钳 0。
    assert(out[6 * 4 + 2] == 0);
  }

  // ── 行跨度（RowPitch）大于 width*8：只读每行前 width 个像素 ───────────
  {
    const float v = SdrCodeToScRgb(200, 240.0f);
    const std::vector<uint8_t> out = Run({{v, v, v}, {0, 0, 0}}, 240.0f, nullptr,
                                         /*pad_bytes=*/24);
    assert(std::abs(out[0] - 200) <= 1);
    assert(out[4] == 0);
  }

  // ── NaN / Inf 不污染：NaN 当黑，Inf 当白，峰值只看有限值 ─────────────
  {
    std::vector<Pixel> pixels = {{NAN, NAN, NAN}, {INFINITY, 0.0f, 0.0f},
                                 {0.5f, 0.5f, 0.5f}};
    ToneMapStats stats;
    const std::vector<uint8_t> out = Run(pixels, 80.0f, &stats);
    assert(std::isfinite(stats.peak));
    assert(out[0] == 0 && out[1] == 0 && out[2] == 0);
    assert(out[4 + 2] == 255);
  }

  // ── 取帧路径判据：只有 Windows 10 上的 HDR 显示器走 DXGI ──────────────
  {
    namespace pol = fushi::hdr_capture_policy;
    // SDR 显示器：任何版本都走 GDI。
    assert(!pol::Decide(false, 19045).use_dxgi);
    assert(!pol::Decide(false, 22631).use_dxgi);
    // Win10（用户的 19045、DuplicateOutput1 起始的 1803、Win10 末尾）。
    assert(pol::Decide(true, 19045).use_dxgi);
    assert(pol::Decide(true, 17134).use_dxgi);
    assert(pol::Decide(true, 21999).use_dxgi);
    // Win11 首个 build 起走 GDI（含本机 29683）。
    assert(!pol::Decide(true, 22000).use_dxgi);
    assert(!pol::Decide(true, 26100).use_dxgi);
    assert(!pol::Decide(true, 29683).use_dxgi);
    // 版本取不到：保持改动前的 GDI。
    assert(!pol::Decide(true, 0).use_dxgi);
    // 每条判据都带非空原因，进诊断日志。
    for (uint32_t build : {0u, 19045u, 22000u}) {
      for (bool hdr : {false, true}) {
        const char* reason = pol::Decide(hdr, build).reason;
        assert(reason != nullptr && reason[0] != '\0');
      }
    }
  }

  std::printf("hdr_tone_map_test OK\n");
  return 0;
}
