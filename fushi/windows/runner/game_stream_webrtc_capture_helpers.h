#ifndef RUNNER_GAME_STREAM_WEBRTC_CAPTURE_HELPERS_H_
#define RUNNER_GAME_STREAM_WEBRTC_CAPTURE_HELPERS_H_

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <thread>
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


// One output sample of a centre-aligned linear resampler: the output pixel
// blends source samples [i0] and [i1] with weight [w1] / 256 on [i1].
struct ScaleTap {
  uint32_t i0 = 0;
  uint32_t i1 = 0;
  uint32_t w1 = 0;
};

// Builds the taps mapping [dst] samples onto [src]. Equal sizes produce the
// identity (w1 == 0) so an unscaled crop is copied exactly; an exact 2:1
// downscale lands every tap between two samples (w1 == 128), i.e. a box
// average. Integer-only so the per-pixel loop has no division.
inline void BuildScaleTaps(uint32_t src, uint32_t dst,
                           std::vector<ScaleTap>* taps) {
  taps->resize(dst);
  for (uint32_t d = 0; d < dst; ++d) {
    // Source position of the output centre in 1/256 pixel:
    // ((d + 0.5) * src / dst - 0.5) * 256.
    const int64_t pos =
        ((static_cast<int64_t>(2 * d + 1) * src - dst) * 128) / dst;
    ScaleTap tap;
    if (pos > 0) {
      tap.i0 = static_cast<uint32_t>(pos >> 8);
      tap.w1 = static_cast<uint32_t>(pos & 255);
    }
    if (tap.i0 >= src - 1) {
      tap.i0 = src - 1;
      tap.w1 = 0;
    }
    tap.i1 = std::min<uint32_t>(tap.i0 + 1, src - 1);
    (*taps)[d] = tap;
  }
}

// Converts a cropped BGRA region to I420 (BT.601 limited range), scaling with
// a bilinear filter. Keeps its lookup tables and scratch rows between frames,
// so a steady stream allocates nothing after the first frame. The earlier
// nearest-neighbour sampler dropped whole source rows/columns on any
// downscale, which shredded the thin strokes of Japanese text.
class BgraToI420Converter {
 public:
  bool Convert(const uint8_t* src, size_t src_stride, uint32_t src_x,
               uint32_t src_y, uint32_t src_w, uint32_t src_h, uint32_t dst_w,
               uint32_t dst_h, std::vector<uint8_t>* y,
               std::vector<uint8_t>* u, std::vector<uint8_t>* v) {
    const uint64_t min_row_bytes =
        (static_cast<uint64_t>(src_x) + src_w) * uint64_t{4};
    if (src == nullptr || y == nullptr || u == nullptr || v == nullptr ||
        src_w < 2 || src_h < 2 || dst_w < 2 || dst_h < 2 ||
        (dst_w & 1) != 0 || (dst_h & 1) != 0 ||
        src_stride < min_row_bytes) {
      return false;
    }
    if (src_w != taps_src_w_ || dst_w != taps_dst_w_) {
      BuildScaleTaps(src_w, dst_w, &x_taps_);
      taps_src_w_ = src_w;
      taps_dst_w_ = dst_w;
    }
    if (src_h != taps_src_h_ || dst_h != taps_dst_h_) {
      BuildScaleTaps(src_h, dst_h, &y_taps_);
      taps_src_h_ = src_h;
      taps_dst_h_ = dst_h;
    }
    // Every element is written below; resize only reallocates on growth.
    y->resize(static_cast<size_t>(dst_w) * dst_h);
    u->resize(static_cast<size_t>(dst_w / 2) * (dst_h / 2));
    v->resize(static_cast<size_t>(dst_w / 2) * (dst_h / 2));

    const uint8_t* origin = src + static_cast<size_t>(src_y) * src_stride +
                            static_cast<size_t>(src_x) * 4;
    const Job job{origin, src_stride, src_w == dst_w, dst_w,
                  y->data(), u->data(), v->data()};
    // Row pairs are independent: split them into bands converted in
    // parallel. A 1080p frame is ~17 M cycles (~5 ms) of single-core work at
    // 1:1 and about three times that when scaling from 1440p; the capture
    // callback must stay well inside one frame interval at 60-120 fps.
    const uint32_t pairs = dst_h / 2;
    const uint64_t pixels = static_cast<uint64_t>(dst_w) * dst_h;
    const uint32_t bands = pixels < kParallelMinPixels
        ? 1
        : std::min<uint32_t>(ConverterThreads(), pairs);
    if (scratch_.size() < bands) scratch_.resize(bands);
    std::vector<std::thread> workers;
    workers.reserve(bands - 1);
    for (uint32_t band = 1; band < bands; ++band) {
      const uint32_t first = pairs * band / bands * 2;
      const uint32_t last = pairs * (band + 1) / bands * 2;
      workers.emplace_back([this, &job, first, last, band] {
        ConvertRows(job, first, last, &scratch_[band]);
      });
    }
    ConvertRows(job, 0, pairs / bands * 2, &scratch_[0]);
    for (std::thread& worker : workers) worker.join();
    return true;
  }

  static constexpr uint64_t kParallelMinPixels = 640 * 360;

 private:
  struct Job {
    const uint8_t* origin;
    size_t stride;
    bool unscaled_w;
    uint32_t dst_w;
    uint8_t* y;
    uint8_t* u;
    uint8_t* v;
  };
  using Scratch = std::array<std::vector<uint8_t>, 2>;

  static uint32_t ConverterThreads() {
    const unsigned cores = std::thread::hardware_concurrency();
    return std::clamp<uint32_t>(cores / 4, 1, 4);
  }

  void ConvertRows(const Job& job, uint32_t first, uint32_t last,
                   Scratch* scratch) const {
    const uint32_t dst_w = job.dst_w;
    for (uint32_t dy = first; dy < last; dy += 2) {
      const uint8_t* rows[2];
      for (uint32_t k = 0; k < 2; ++k) {
        const ScaleTap& ty = y_taps_[dy + k];
        const uint8_t* r0 = job.origin + static_cast<size_t>(ty.i0) * job.stride;
        if (job.unscaled_w && ty.w1 == 0) {
          rows[k] = r0;  // An exact source row: read it in place.
          continue;
        }
        const uint8_t* r1 = job.origin + static_cast<size_t>(ty.i1) * job.stride;
        std::vector<uint8_t>& row = (*scratch)[k];
        row.resize(static_cast<size_t>(dst_w) * 4);
        ScaleRow(r0, r1, ty.w1, dst_w, row.data());
        rows[k] = row.data();
      }
      StoreRowPair(rows[0], rows[1], dst_w,
                   job.y + static_cast<size_t>(dy) * dst_w,
                   job.u + static_cast<size_t>(dy / 2) * (dst_w / 2),
                   job.v + static_cast<size_t>(dy / 2) * (dst_w / 2));
    }
  }

  // Bilinear sample of one output row into BGRA ([out] alpha is unused).
  void ScaleRow(const uint8_t* r0, const uint8_t* r1, uint32_t wy1,
                uint32_t dst_w, uint8_t* out) const {
    const uint32_t wy0 = 256 - wy1;
    for (uint32_t dx = 0; dx < dst_w; ++dx) {
      const ScaleTap& tx = x_taps_[dx];
      const uint8_t* a = r0 + static_cast<size_t>(tx.i0) * 4;
      const uint8_t* b = r0 + static_cast<size_t>(tx.i1) * 4;
      uint8_t* o = out + static_cast<size_t>(dx) * 4;
      const uint32_t wx1 = tx.w1;
      const uint32_t wx0 = 256 - wx1;
      if (wy1 == 0) {
        for (int ch = 0; ch < 3; ++ch) {
          o[ch] = static_cast<uint8_t>((a[ch] * wx0 + b[ch] * wx1 + 128) >> 8);
        }
        continue;
      }
      const uint8_t* c = r1 + static_cast<size_t>(tx.i0) * 4;
      const uint8_t* d = r1 + static_cast<size_t>(tx.i1) * 4;
      for (int ch = 0; ch < 3; ++ch) {
        const uint32_t top = a[ch] * wx0 + b[ch] * wx1;
        const uint32_t bottom = c[ch] * wx0 + d[ch] * wx1;
        o[ch] = static_cast<uint8_t>((top * wy0 + bottom * wy1 + 32768) >> 16);
      }
    }
  }

  // BT.601 limited range from two BGRA rows. The coefficients keep every
  // result inside 16..240, so no clamping (and no branch) is needed.
  static void StoreRowPair(const uint8_t* top, const uint8_t* bottom,
                           uint32_t dst_w, uint8_t* y0, uint8_t* u,
                           uint8_t* v) {
    uint8_t* y1 = y0 + dst_w;
    for (uint32_t dx = 0; dx < dst_w; dx += 2) {
      const uint8_t* p00 = top + static_cast<size_t>(dx) * 4;
      const uint8_t* p10 = bottom + static_cast<size_t>(dx) * 4;
      const int b00 = p00[0], g00 = p00[1], r00 = p00[2];
      const int b01 = p00[4], g01 = p00[5], r01 = p00[6];
      const int b10 = p10[0], g10 = p10[1], r10 = p10[2];
      const int b11 = p10[4], g11 = p10[5], r11 = p10[6];
      y0[dx] = static_cast<uint8_t>(
          ((66 * r00 + 129 * g00 + 25 * b00 + 128) >> 8) + 16);
      y0[dx + 1] = static_cast<uint8_t>(
          ((66 * r01 + 129 * g01 + 25 * b01 + 128) >> 8) + 16);
      y1[dx] = static_cast<uint8_t>(
          ((66 * r10 + 129 * g10 + 25 * b10 + 128) >> 8) + 16);
      y1[dx + 1] = static_cast<uint8_t>(
          ((66 * r11 + 129 * g11 + 25 * b11 + 128) >> 8) + 16);
      const int b = (b00 + b01 + b10 + b11) >> 2;
      const int g = (g00 + g01 + g10 + g11) >> 2;
      const int r = (r00 + r01 + r10 + r11) >> 2;
      u[dx / 2] = static_cast<uint8_t>(
          ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
      v[dx / 2] = static_cast<uint8_t>(
          ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
  }

  std::vector<ScaleTap> x_taps_;
  std::vector<ScaleTap> y_taps_;
  uint32_t taps_src_w_ = 0;
  uint32_t taps_dst_w_ = 0;
  uint32_t taps_src_h_ = 0;
  uint32_t taps_dst_h_ = 0;
  std::vector<Scratch> scratch_;
};

inline bool ConvertBgraToI420(const uint8_t* src, size_t src_stride,
                              uint32_t src_x, uint32_t src_y, uint32_t src_w,
                              uint32_t src_h, uint32_t dst_w,
                              uint32_t dst_h, std::vector<uint8_t>* y,
                              std::vector<uint8_t>* u,
                              std::vector<uint8_t>* v) {
  BgraToI420Converter converter;
  return converter.Convert(src, src_stride, src_x, src_y, src_w, src_h, dst_w,
                           dst_h, y, u, v);
}

// Decides which WGC frames to forward at a target rate. WGC delivers at the
// display's refresh with jitter; the former "now - last >= interval" test
// dropped every frame arriving a fraction early, so a 60 Hz display streaming
// at 60 fps delivered roughly every other frame. This keeps a deadline that
// advances by exactly one interval and accepts a frame up to a quarter
// interval early, so the long-run rate equals the target (or the source rate
// when that is lower). After a gap the deadline restarts from the frame.
class FramePacer {
 public:
  explicit FramePacer(int fps)
      : interval_us_((1000000LL + std::max<int>(fps, 1) - 1) /
                     std::max<int>(fps, 1)) {}

  bool ShouldKeep(int64_t now_us) {
    if (!started_) {
      started_ = true;
      next_due_us_ = now_us + interval_us_;
      return true;
    }
    if (now_us + interval_us_ / 4 < next_due_us_) return false;
    next_due_us_ += interval_us_;
    if (next_due_us_ <= now_us) next_due_us_ = now_us + interval_us_;
    return true;
  }

  void Reset() { started_ = false; }
  int64_t interval_us() const { return interval_us_; }

 private:
  int64_t interval_us_;
  int64_t next_due_us_ = 0;
  bool started_ = false;
};

// A window whose content does not change (a visual novel waiting on a line)
// produces no WGC frames. Without new input frames the encoder can neither
// answer a receiver's keyframe request after packet loss nor refine the
// first, bitrate-starved encode of a new scene, so the picture would stay
// corrupt or blurry until the game redraws. The capture therefore re-sends
// the last converted frame once it has been idle this long, at this cadence;
// identical frames encode to a few bytes.
constexpr int64_t kCaptureIdleRepeatUs = 100000;

inline bool ShouldRepeatIdleFrame(bool has_frame, int64_t now_us,
                                  int64_t last_delivered_us) {
  return has_frame && now_us - last_delivered_us >= kCaptureIdleRepeatUs;
}

}  // namespace flutter_webrtc_plugin

#endif  // RUNNER_GAME_STREAM_WEBRTC_CAPTURE_HELPERS_H_
