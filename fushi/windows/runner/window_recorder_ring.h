#ifndef RUNNER_WINDOW_RECORDER_RING_H_
#define RUNNER_WINDOW_RECORDER_RING_H_

#include <cstddef>
#include <cstdint>
#include <deque>
#include <utility>
#include <vector>

// galgame 制卡「持续滚动录制游戏窗口」的**纯逻辑**（只依赖 STL，无 Win32 / WRL），
// 供 window_recorder.cpp 使用并由 tests/window_recorder_ring_test.cpp 单测：
//   - 按 fps 决定 WGC 送来的哪些帧值得保留（FrameArrived 是显示刷新率，远高于 fps）；
//   - 环形队列按 max_seconds（相对最新帧的 tick）与总字节上限淘汰旧帧；
//   - 导出区间的解析（to<=0 = 到现在）与区间内帧的选取；
//   - BGRA 子矩形 box 缩放到 BGR24（JPEG 编码前的等比缩小）。
namespace fushi {
namespace window_recorder_ring {

// 按 [fps] 推出的最小保留间隔（毫秒）：floor(1000/fps)；fps 夹在 [1, 1000]。
inline int64_t MinIntervalMs(int fps) {
  if (fps < 1) {
    fps = 1;
  } else if (fps > 1000) {
    fps = 1000;
  }
  return 1000 / fps;
}

// 到达时刻 [now_tick] 的帧是否保留：还没保留过任何帧时保留；否则距上一次保留
// 至少 MinIntervalMs(fps)。时钟倒退（理论上 GetTickCount64 不会）按保留处理，
// 不让录制因此彻底停摆。
inline bool ShouldKeepFrame(uint64_t now_tick, bool has_last,
                            uint64_t last_kept_tick, int fps) {
  if (!has_last || now_tick < last_kept_tick) {
    return true;
  }
  return static_cast<int64_t>(now_tick - last_kept_tick) >=
         MinIntervalMs(fps);
}

// 环形队列淘汰策略：保留最近 [max_seconds] 秒（相对**最新帧**的 tick，而不是
// 墙钟——窗口最小化时 WGC 不出帧，队列里的旧帧不该因为时间流逝而蒸发），且总
// 字节不超过 [max_bytes]（超限时从最老的丢；最新一帧永远保留）。
struct RingPolicy {
  int max_seconds = 20;
  size_t max_bytes = static_cast<size_t>(24) * 1024 * 1024;
};

// 一帧：到达 tick（GetTickCount64，与 hook 台词时间戳同一时钟）+ JPEG 字节。
struct FrameEntry {
  uint64_t tick_ms = 0;
  std::vector<uint8_t> jpeg;
};

class FrameRing {
 public:
  explicit FrameRing(RingPolicy policy = RingPolicy()) : policy_(policy) {}

  // 追加一帧并按策略淘汰。空 JPEG 直接丢弃（编码失败的帧不占位）。
  void Push(uint64_t tick_ms, std::vector<uint8_t> jpeg) {
    if (jpeg.empty()) {
      return;
    }
    total_bytes_ += jpeg.size();
    FrameEntry entry;
    entry.tick_ms = tick_ms;
    entry.jpeg = std::move(jpeg);
    frames_.push_back(std::move(entry));
    Evict();
  }

  // 取 tick 落在 [from_tick, to_tick]（闭区间）内的帧副本，按 tick 升序。
  std::vector<FrameEntry> Select(uint64_t from_tick, uint64_t to_tick) const {
    std::vector<FrameEntry> out;
    if (from_tick > to_tick) {
      return out;
    }
    for (const FrameEntry& f : frames_) {
      if (f.tick_ms >= from_tick && f.tick_ms <= to_tick) {
        out.push_back(f);
      }
    }
    return out;
  }

  size_t size() const { return frames_.size(); }
  bool empty() const { return frames_.empty(); }
  size_t total_bytes() const { return total_bytes_; }
  const std::deque<FrameEntry>& frames() const { return frames_; }
  const RingPolicy& policy() const { return policy_; }

  void Clear() {
    frames_.clear();
    total_bytes_ = 0;
  }

 private:
  void Evict() {
    if (frames_.empty()) {
      return;
    }
    const uint64_t newest = frames_.back().tick_ms;
    const uint64_t window_ms =
        static_cast<uint64_t>(policy_.max_seconds < 0 ? 0
                                                      : policy_.max_seconds) *
        1000;
    while (frames_.size() > 1 &&
           frames_.front().tick_ms + window_ms < newest) {
      PopFront();
    }
    while (frames_.size() > 1 && total_bytes_ > policy_.max_bytes) {
      PopFront();
    }
  }

  void PopFront() {
    total_bytes_ -= frames_.front().jpeg.size();
    frames_.pop_front();
  }

  std::deque<FrameEntry> frames_;
  size_t total_bytes_ = 0;
  RingPolicy policy_;
};

// 导出区间：[from_tick] 负值夹到 0；[to_tick] <= 0 表示「到现在」（= now_tick）。
// from > to 时 [valid] 为 false（调用方按「无帧」处理）。
struct ExportRange {
  uint64_t from = 0;
  uint64_t to = 0;
  bool valid = false;
};

inline ExportRange ResolveExportRange(int64_t from_tick, int64_t to_tick,
                                      uint64_t now_tick) {
  ExportRange r;
  r.from = from_tick < 0 ? 0 : static_cast<uint64_t>(from_tick);
  r.to = to_tick <= 0 ? now_tick : static_cast<uint64_t>(to_tick);
  r.valid = r.from <= r.to;
  return r;
}

// 等比缩小到宽不超过 [max_width]（max_width 为 0 或源已不超过时原样返回）。
// 高度按比例取整，至少为 1。
struct ScaledSize {
  uint32_t width = 0;
  uint32_t height = 0;
};

inline ScaledSize FitWidth(uint32_t width, uint32_t height,
                           uint32_t max_width) {
  ScaledSize s;
  s.width = width;
  s.height = height;
  if (max_width == 0 || width == 0 || height == 0 || width <= max_width) {
    return s;
  }
  uint64_t h = static_cast<uint64_t>(height) * max_width / width;
  if (h == 0) {
    h = 1;
  }
  s.width = max_width;
  s.height = static_cast<uint32_t>(h);
  return s;
}

// 把 BGRA 缓冲（[src_stride] 字节/行）里的子矩形 ([src_x],[src_y],[src_w]×[src_h])
// 用 box 平均缩到 [dst_w]×[dst_h]，输出紧凑 BGR24（行距 = dst_w*3，无 padding，
// alpha 丢弃）。dst 尺寸须 ≥1 且 ≤ 源子矩形尺寸（只缩不放）；违反契约返回空。
inline std::vector<uint8_t> DownscaleBgraToBgr24(
    const uint8_t* src, size_t src_stride, uint32_t src_x, uint32_t src_y,
    uint32_t src_w, uint32_t src_h, uint32_t dst_w, uint32_t dst_h) {
  std::vector<uint8_t> out;
  if (src == nullptr || src_w == 0 || src_h == 0 || dst_w == 0 || dst_h == 0 ||
      dst_w > src_w || dst_h > src_h) {
    return out;
  }
  out.resize(static_cast<size_t>(dst_w) * dst_h * 3);
  for (uint32_t y = 0; y < dst_h; ++y) {
    const uint32_t sy0 =
        static_cast<uint32_t>(static_cast<uint64_t>(y) * src_h / dst_h);
    uint32_t sy1 =
        static_cast<uint32_t>(static_cast<uint64_t>(y + 1) * src_h / dst_h);
    if (sy1 <= sy0) {
      sy1 = sy0 + 1;
    }
    for (uint32_t x = 0; x < dst_w; ++x) {
      const uint32_t sx0 =
          static_cast<uint32_t>(static_cast<uint64_t>(x) * src_w / dst_w);
      uint32_t sx1 =
          static_cast<uint32_t>(static_cast<uint64_t>(x + 1) * src_w / dst_w);
      if (sx1 <= sx0) {
        sx1 = sx0 + 1;
      }
      uint64_t b = 0, g = 0, r = 0;
      for (uint32_t sy = sy0; sy < sy1; ++sy) {
        const uint8_t* row =
            src + static_cast<size_t>(src_y + sy) * src_stride +
            static_cast<size_t>(src_x + sx0) * 4;
        for (uint32_t sx = sx0; sx < sx1; ++sx) {
          b += row[0];
          g += row[1];
          r += row[2];
          row += 4;
        }
      }
      const uint64_t count =
          static_cast<uint64_t>(sy1 - sy0) * static_cast<uint64_t>(sx1 - sx0);
      uint8_t* dst = out.data() + (static_cast<size_t>(y) * dst_w + x) * 3;
      dst[0] = static_cast<uint8_t>(b / count);
      dst[1] = static_cast<uint8_t>(g / count);
      dst[2] = static_cast<uint8_t>(r / count);
    }
  }
  return out;
}

}  // namespace window_recorder_ring
}  // namespace fushi

#endif  // RUNNER_WINDOW_RECORDER_RING_H_
