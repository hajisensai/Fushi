#ifndef RUNNER_GAME_STREAM_WEBRTC_CAPTURE_HELPERS_H_
#define RUNNER_GAME_STREAM_WEBRTC_CAPTURE_HELPERS_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace flutter_webrtc_plugin {

inline uint8_t ClampByte(int value) {
  if (value < 0) return 0;
  if (value > 255) return 255;
  return static_cast<uint8_t>(value);
}

inline uint8_t BgraToY(uint8_t b, uint8_t g, uint8_t r) {
  return ClampByte(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
}

inline uint8_t BgrToU(int b, int g, int r) {
  return ClampByte(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
}

inline uint8_t BgrToV(int b, int g, int r) {
  return ClampByte(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
}

struct OutputSize {
  uint32_t width = 0;
  uint32_t height = 0;
};

inline uint32_t MakeEvenAtLeastTwo(uint32_t value) {
  if (value < 2) return 0;
  value &= ~uint32_t{1};
  return value < 2 ? 0 : value;
}

// Capture limits negotiated through getDisplayMedia video.mandatory
// (frameRate / maxWidth / maxHeight). Absent values use the defaults; supplied
// values are clamped so a remote-chosen profile can never ask the host for an
// unbounded frame rate or output size.
constexpr int kCaptureMinFps = 1;
constexpr int kCaptureMaxFps = 120;
constexpr uint32_t kCaptureDefaultMaxWidth = 1920;
constexpr uint32_t kCaptureDefaultMaxHeight = 1080;
constexpr uint32_t kCaptureMinMaxWidth = 320;
constexpr uint32_t kCaptureMinMaxHeight = 180;
constexpr uint32_t kCaptureMaxMaxWidth = 3840;
constexpr uint32_t kCaptureMaxMaxHeight = 2160;

inline int ClampCaptureFps(int fps) {
  return std::clamp(fps, kCaptureMinFps, kCaptureMaxFps);
}

// value <= 0 means "not supplied" and selects [fallback].
inline uint32_t ClampCaptureExtent(long long value, uint32_t fallback,
                                   uint32_t min_value, uint32_t max_value) {
  if (value <= 0) return fallback;
  if (value < static_cast<long long>(min_value)) return min_value;
  if (value > static_cast<long long>(max_value)) return max_value;
  return static_cast<uint32_t>(value);
}

inline uint32_t ClampCaptureMaxWidth(long long value) {
  return ClampCaptureExtent(value, kCaptureDefaultMaxWidth,
                            kCaptureMinMaxWidth, kCaptureMaxMaxWidth);
}

inline uint32_t ClampCaptureMaxHeight(long long value) {
  return ClampCaptureExtent(value, kCaptureDefaultMaxHeight,
                            kCaptureMinMaxHeight, kCaptureMaxMaxHeight);
}

// Scales [width]x[height] to fit inside [max_width]x[max_height] preserving the
// aspect ratio (never upscales), then rounds both sides down to even values.
inline OutputSize FitInsideEven(uint32_t width, uint32_t height,
                                uint32_t max_width = kCaptureDefaultMaxWidth,
                                uint32_t max_height = kCaptureDefaultMaxHeight) {
  OutputSize out;
  if (width < 2 || height < 2 || max_width < 2 || max_height < 2) return out;
  uint64_t dst_w = width;
  uint64_t dst_h = height;
  if (dst_w > max_width) {
    dst_h = std::max<uint64_t>(1, dst_h * max_width / dst_w);
    dst_w = max_width;
  }
  if (dst_h > max_height) {
    dst_w = std::max<uint64_t>(1, dst_w * max_height / dst_h);
    dst_h = max_height;
  }
  out.width = MakeEvenAtLeastTwo(static_cast<uint32_t>(dst_w));
  out.height = MakeEvenAtLeastTwo(static_cast<uint32_t>(dst_h));
  return out;
}

inline bool ConvertBgraToI420(const uint8_t* src, size_t src_stride,
                              uint32_t src_x, uint32_t src_y, uint32_t src_w,
                              uint32_t src_h, uint32_t dst_w,
                              uint32_t dst_h, std::vector<uint8_t>* y,
                              std::vector<uint8_t>* u,
                              std::vector<uint8_t>* v) {
  const uint64_t min_row_bytes =
      (static_cast<uint64_t>(src_x) + src_w) * uint64_t{4};
  if (src == nullptr || y == nullptr || u == nullptr || v == nullptr ||
      src_w < 2 || src_h < 2 || dst_w < 2 || dst_h < 2 ||
      (dst_w & 1) != 0 || (dst_h & 1) != 0 ||
      src_stride < min_row_bytes) {
    return false;
  }
  y->assign(static_cast<size_t>(dst_w) * dst_h, 0);
  u->assign(static_cast<size_t>(dst_w / 2) * (dst_h / 2), 128);
  v->assign(static_cast<size_t>(dst_w / 2) * (dst_h / 2), 128);

  for (uint32_t dy = 0; dy < dst_h; ++dy) {
    const uint32_t sy = std::min<uint32_t>(
        src_h - 1, static_cast<uint32_t>(static_cast<uint64_t>(dy) * src_h /
                                         dst_h));
    const uint8_t* row = src + static_cast<size_t>(src_y + sy) * src_stride;
    for (uint32_t dx = 0; dx < dst_w; ++dx) {
      const uint32_t sx = std::min<uint32_t>(
          src_w - 1, static_cast<uint32_t>(static_cast<uint64_t>(dx) * src_w /
                                           dst_w));
      const uint8_t* px = row + static_cast<size_t>(src_x + sx) * 4;
      (*y)[static_cast<size_t>(dy) * dst_w + dx] = BgraToY(px[0], px[1], px[2]);
    }
  }

  for (uint32_t dy = 0; dy < dst_h; dy += 2) {
    for (uint32_t dx = 0; dx < dst_w; dx += 2) {
      int b = 0, g = 0, r = 0;
      for (uint32_t oy = 0; oy < 2; ++oy) {
        const uint32_t sy = std::min<uint32_t>(
            src_h - 1,
            static_cast<uint32_t>(static_cast<uint64_t>(dy + oy) * src_h /
                                  dst_h));
        const uint8_t* row = src + static_cast<size_t>(src_y + sy) * src_stride;
        for (uint32_t ox = 0; ox < 2; ++ox) {
          const uint32_t sx = std::min<uint32_t>(
              src_w - 1,
              static_cast<uint32_t>(static_cast<uint64_t>(dx + ox) * src_w /
                                    dst_w));
          const uint8_t* px = row + static_cast<size_t>(src_x + sx) * 4;
          b += px[0];
          g += px[1];
          r += px[2];
        }
      }
      b /= 4;
      g /= 4;
      r /= 4;
      const size_t uv_index = static_cast<size_t>(dy / 2) * (dst_w / 2) + dx / 2;
      (*u)[uv_index] = BgrToU(b, g, r);
      (*v)[uv_index] = BgrToV(b, g, r);
    }
  }
  return true;
}

}  // namespace flutter_webrtc_plugin

#endif  // RUNNER_GAME_STREAM_WEBRTC_CAPTURE_HELPERS_H_
