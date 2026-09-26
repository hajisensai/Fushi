#pragma once

#include <algorithm>
#include <cstdint>

namespace fushi {

// Decides how many fixed-size audio chunks the loopback feeder owes WebRTC at a
// given moment, measured against a monotonic clock.
//
// Why it exists: upstream fed exactly one 10 ms chunk per tick of a periodic
// 10 ms waitable timer and only ever *skipped* ticks when ahead. A periodic
// timer never ticks faster than its period and routinely ticks slower (10.3 ms
// measured on a foreground console, 15.6 ms when Windows ignores the
// resolution request for a background GUI process), so the feeder fell 3–36 %
// behind real time. The WASAPI ring then pinned at its 200 ms cap and every
// tick trimmed a few samples off the oldest audio — continuous crackle. Owing
// chunks by elapsed time instead makes the tick rate irrelevant.
class AudioFeedClock {
 public:
  // [chunk_us] is the chunk duration; [max_burst] bounds one catch-up so a
  // stalled thread does not dump a wall of audio at once; a debt larger than
  // [resync_us] (sleep, debugger, long stall) restarts the clock rather than
  // replaying the gap.
  AudioFeedClock(int64_t chunk_us, int max_burst, int64_t resync_us)
      : chunk_us_(chunk_us), max_burst_(max_burst), resync_us_(resync_us) {}

  void Start(int64_t now_us) {
    start_us_ = now_us;
    delivered_ = 0;
    started_ = true;
  }

  void Stop() { started_ = false; }

  bool started() const { return started_; }

  // Chunks to deliver now; the caller must report each one via [Delivered].
  int Due(int64_t now_us) {
    if (!started_) return 0;
    const int64_t owed = (now_us - start_us_) / chunk_us_ - delivered_;
    if (owed <= 0) return 0;
    if (owed * chunk_us_ > resync_us_) {
      // Keep one chunk flowing and re-anchor so the next tick owes nothing.
      start_us_ = now_us - chunk_us_;
      delivered_ = 0;
      return 1;
    }
    return static_cast<int>(std::min<int64_t>(owed, max_burst_));
  }

  void Delivered() { ++delivered_; }

 private:
  int64_t chunk_us_;
  int max_burst_;
  int64_t resync_us_;
  int64_t start_us_ = 0;
  int64_t delivered_ = 0;
  bool started_ = false;
};

}  // namespace fushi
