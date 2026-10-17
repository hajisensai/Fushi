#ifndef RUNNER_HDR_TONE_MAP_H_
#define RUNNER_HDR_TONE_MAP_H_

// 系统开了 HDR 的显示器上截到的 scRGB 帧（R16G16B16A16_FLOAT，线性、BT.709 原色，
// 1.0 = 80 nit）→ 8bit sRGB BGRA 的纯函数色调映射（BUG：截屏识字在 HDR 下发白过曝）。
//
// 口径：
// * 参考白 = 该显示器的「SDR 内容亮度」（DISPLAYCONFIG_SDR_WHITE_LEVEL）。DWM 把每个
//   SDR 窗口的 sRGB 1.0 合成成 white_nits，所以 scRGB 值 ÷ (white_nits / 80) 就回到
//   SDR 窗口原本的线性值，再走 sRGB OETF 即还原原像素（量化误差 ≤ 1 级）。
//   查不到白电平（0）时按 80 nit（scRGB 1.0 本身）兜底，与 hdr_video_host_window 同口径。
// * 整帧峰值 ≤ 1（只有 SDR 内容，桌面常态）：恒等，逐像素还原。
// * 有超过参考白的 HDR 高光：按 max(R,G,B) 等比缩放（保色相），knee 以下恒等、
//   knee 以上用扩展 Reinhard 把 [knee, 峰值] 平滑压到 [knee, 1]，连续且一阶导连续。
// * 负值（广色域出了 sRGB 色域）钳 0；NaN / Inf 当 0 / 峰值处理。
//
// 不依赖 Windows 头，C++ 单测 tests/hdr_tone_map_test.cpp 直接 include。

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace fushi {
namespace hdr_tone_map {

// SDR 白电平查不到时的兜底（scRGB 1.0）。
constexpr float kFallbackSdrWhiteNits = 80.0f;
// HDR 高光压缩的 knee（参考白归一后的线性值）。knee 以下的 SDR 内容恒等。
constexpr float kKnee = 0.75f;

// IEEE 754 binary16 → float（含次正规数、Inf、NaN）。
inline float HalfToFloat(uint16_t h) {
  const uint32_t sign = static_cast<uint32_t>(h & 0x8000u) << 16;
  const uint32_t exponent = (h >> 10) & 0x1Fu;
  uint32_t mantissa = h & 0x3FFu;
  uint32_t bits;
  if (exponent == 0) {
    if (mantissa == 0) {
      bits = sign;
    } else {
      // 次正规数：规格化。
      int e = -1;
      do {
        ++e;
        mantissa <<= 1;
      } while ((mantissa & 0x400u) == 0);
      mantissa &= 0x3FFu;
      bits = sign | (static_cast<uint32_t>(127 - 15 - e) << 23) |
             (mantissa << 13);
    }
  } else if (exponent == 0x1F) {
    bits = sign | 0x7F800000u | (mantissa << 13);
  } else {
    bits = sign | ((exponent + (127 - 15)) << 23) | (mantissa << 13);
  }
  float out;
  std::memcpy(&out, &bits, sizeof(out));
  return out;
}

// 全部 65536 个 half 的 float 值（256 KiB，首次调用时建一次）：4K 一帧 2500 万次
// 解码改成查表，色调映射整帧从数百毫秒降到几十毫秒（平台线程上跑）。
inline const float* HalfToFloatTable() {
  static const std::vector<float> table = [] {
    std::vector<float> t(65536);
    for (uint32_t h = 0; h < 65536; ++h) {
      t[h] = HalfToFloat(static_cast<uint16_t>(h));
    }
    return t;
  }();
  return table.data();
}

// 参考白（scRGB 单位）：white_nits / 80；无效值兜底 1.0。
inline float ReferenceWhiteScRgb(float sdr_white_nits) {
  if (!(sdr_white_nits > 0.0f) || !std::isfinite(sdr_white_nits)) {
    return kFallbackSdrWhiteNits / 80.0f;
  }
  return sdr_white_nits / 80.0f;
}

// sRGB 电光转换（编码值 [0,1] → 线性）。
inline double SrgbToLinear(double s) {
  return s <= 0.04045 ? s / 12.92 : std::pow((s + 0.055) / 1.055, 2.4);
}

// 线性 → 8bit sRGB：按 255 个「相邻编码中点」的线性阈值二分，结果与
// round(OETF(x) * 255) 一致，但每像素只比较不做 pow。
class SrgbEncoder {
 public:
  SrgbEncoder() {
    for (int i = 0; i < 255; ++i) {
      thresholds_[i] =
          static_cast<float>(SrgbToLinear((static_cast<double>(i) + 0.5) / 255.0));
    }
  }
  uint8_t Encode(float linear) const {
    if (!(linear > 0.0f)) return 0;  // 含 NaN
    const float* end = thresholds_.data() + thresholds_.size();
    return static_cast<uint8_t>(
        std::upper_bound(thresholds_.data(), end, linear) - thresholds_.data());
  }

 private:
  std::array<float, 255> thresholds_{};
};

// 对归一后（参考白 = 1）的 max(R,G,B) 做的高光压缩曲线。
// |peak| ≤ 1：恒等（再钳到 [0,1]）。否则 knee 以下恒等，knee 以上扩展 Reinhard：
// a = (x-k)/(1-k)，A = (peak-k)/(1-k)，y = k + (1-k)·a(1 + a/A²)/(1 + a)。
// 性质：y(k)=k、y'(k)=1、y(peak)=1、单调递增。
inline float CompressHighlight(float x, float peak) {
  if (!(x > 0.0f)) return 0.0f;
  if (!(peak > 1.0f)) return std::min(x, 1.0f);
  if (x <= kKnee) return x;
  if (x >= peak) return 1.0f;
  const float headroom = 1.0f - kKnee;
  const float a = (x - kKnee) / headroom;
  const float big_a = (peak - kKnee) / headroom;
  return kKnee + headroom * (a * (1.0f + a / (big_a * big_a)) / (1.0f + a));
}

// 一个 RGBA16F 像素归一后的亮度代表值 max(R,G,B)（NaN 当 0，+Inf 原样）。
inline float MaxChannel(float r, float g, float b) {
  float m = 0.0f;
  if (r > m) m = r;
  if (g > m) m = g;
  if (b > m) m = b;
  return m;
}

// 整帧峰值（归一后 max(R,G,B) 的最大值；只看有限值）。
// |rgba16f| 每像素 4 个 half，|row_pitch_bytes| 为源行跨度。
inline float FramePeak(const uint8_t* rgba16f, size_t row_pitch_bytes, int width,
                       int height, float inv_white) {
  const float* half = HalfToFloatTable();
  float peak = 0.0f;
  for (int y = 0; y < height; ++y) {
    const uint16_t* row =
        reinterpret_cast<const uint16_t*>(rgba16f + row_pitch_bytes * y);
    for (int x = 0; x < width; ++x) {
      const float m = MaxChannel(half[row[x * 4 + 0]], half[row[x * 4 + 1]],
                                 half[row[x * 4 + 2]]);
      if (m > peak && std::isfinite(m)) peak = m;
    }
  }
  return peak * inv_white;
}

struct ToneMapStats {
  float reference_white_scrgb = 1.0f;  // 实际用的参考白（scRGB 单位）
  float peak = 0.0f;                   // 归一后整帧峰值
};

// scRGB(RGBA16F) → 8bit sRGB BGRA（alpha 置 255，stride = width * 4）。
// |out_bgra| 至少 width * height * 4 字节。
inline ToneMapStats ToneMapScRgbToBgra8(const uint8_t* rgba16f,
                                        size_t row_pitch_bytes, int width,
                                        int height, float sdr_white_nits,
                                        uint8_t* out_bgra) {
  ToneMapStats stats;
  stats.reference_white_scrgb = ReferenceWhiteScRgb(sdr_white_nits);
  const float inv_white = 1.0f / stats.reference_white_scrgb;
  stats.peak = FramePeak(rgba16f, row_pitch_bytes, width, height, inv_white);
  const float peak = stats.peak;
  static const SrgbEncoder encoder;
  const float* half = HalfToFloatTable();
  // knee 以下（以及整帧没有高光时的全部像素）各通道独立：half → 8bit 一张表。
  std::vector<uint8_t> direct(65536);
  for (uint32_t h = 0; h < 65536; ++h) {
    direct[h] = encoder.Encode(half[h] * inv_white);
  }
  const bool compress = peak > 1.0f;
  for (int y = 0; y < height; ++y) {
    const uint16_t* row =
        reinterpret_cast<const uint16_t*>(rgba16f + row_pitch_bytes * y);
    uint8_t* dst = out_bgra + static_cast<size_t>(y) * width * 4;
    for (int x = 0; x < width; ++x) {
      const uint16_t hr = row[x * 4 + 0];
      const uint16_t hg = row[x * 4 + 1];
      const uint16_t hb = row[x * 4 + 2];
      dst[x * 4 + 3] = 0xFF;
      if (compress) {
        float r = half[hr] * inv_white;
        float g = half[hg] * inv_white;
        float b = half[hb] * inv_white;
        if (!(r > 0.0f)) r = 0.0f;
        if (!(g > 0.0f)) g = 0.0f;
        if (!(b > 0.0f)) b = 0.0f;
        const float m = MaxChannel(r, g, b);
        if (m > kKnee) {
          // 等比缩放保色相；Inf 直接落到白。
          if (!std::isfinite(m)) {
            r = g = b = 1.0f;
          } else {
            const float scale = CompressHighlight(m, peak) / m;
            r *= scale;
            g *= scale;
            b *= scale;
          }
          dst[x * 4 + 0] = encoder.Encode(b);
          dst[x * 4 + 1] = encoder.Encode(g);
          dst[x * 4 + 2] = encoder.Encode(r);
          continue;
        }
      }
      dst[x * 4 + 0] = direct[hb];
      dst[x * 4 + 1] = direct[hg];
      dst[x * 4 + 2] = direct[hr];
    }
  }
  return stats;
}

}  // namespace hdr_tone_map
}  // namespace fushi

#endif  // RUNNER_HDR_TONE_MAP_H_
