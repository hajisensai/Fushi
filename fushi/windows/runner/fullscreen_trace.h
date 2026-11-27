#ifndef RUNNER_FULLSCREEN_TRACE_H_
#define RUNNER_FULLSCREEN_TRACE_H_

#include <windows.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace fushi {

// BUG-5591: timeline of the latest runner-owned fullscreen transition
// (Win32Window::SetFullscreen), the objective record behind "one geometry
// step, no intermediate window size, exact restore":
//
//   kBegin / kEnd     SetFullscreen entry and return (|a| = 1 entering)
//   kWindowPos        every WM_WINDOWPOSCHANGED of the main window: the window
//                     rectangle, zoom / minimize state and client size after
//                     each geometry change, including any the system inserts
//   kChildDelivered   a child (Flutter view) resize returned; |a| x |b| is the
//                     delivered size, |c| how long the engine blocked in it (ms)
//   kRasterized       Dart reported a rasterized frame of |a| x |b| (the first
//                     frame at a new size)
//   kSnapshotReleased the transition snapshot left the surface (|a| = reason)
//
// Times are microseconds since kBegin. The ring is cleared on every kBegin and
// keeps recording until the next one, so the frames after SetFullscreen
// returns are part of the record. Read through the window channel
// (`fullscreenTrace`) by integration_test/win_fullscreen_geometry_itest.dart.
enum class FullscreenTraceKind : int {
  kBegin = 0,
  kEnd = 1,
  kWindowPos = 2,
  kChildDelivered = 3,
  kRasterized = 4,
  kSnapshotReleased = 5,
};

enum class SnapshotReleaseReason : int {
  kOpaqueSurface = 0,   // opaque surface: pixels stay under the view
  kSameClientSize = 1,  // nothing exposed, no new frame size to wait for
  kRasterized = 2,      // see-through surface: view rasterized the new size
  kResizedAgain = 3,    // a later resize outside a transition
  kSurfaceChanged = 4,  // the surface turned see-through again
};

struct FullscreenTraceEvent {
  FullscreenTraceKind kind = FullscreenTraceKind::kBegin;
  int64_t t_us = 0;
  RECT window = {};
  SIZE client = {};
  bool zoomed = false;
  bool iconic = false;
  int32_t a = 0;
  int32_t b = 0;
  int32_t c = 0;
};

class FullscreenTrace {
 public:
  static constexpr size_t kCapacity = 256;

  // Starts a new record at |now_us| (any monotonic microsecond clock).
  void Begin(int64_t now_us) {
    count_ = 0;
    origin_us_ = now_us;
    armed_ = true;
  }

  // Appends |event| stamped relative to Begin; no-op before the first Begin
  // or once full (a transition produces a few dozen events).
  void Record(FullscreenTraceEvent event, int64_t now_us) {
    if (!armed_ || count_ >= kCapacity) {
      return;
    }
    event.t_us = now_us - origin_us_;
    events_[count_++] = event;
  }

  bool armed() const { return armed_; }

  std::vector<FullscreenTraceEvent> Events() const {
    return std::vector<FullscreenTraceEvent>(events_.begin(),
                                             events_.begin() + count_);
  }

 private:
  std::array<FullscreenTraceEvent, kCapacity> events_{};
  size_t count_ = 0;
  int64_t origin_us_ = 0;
  bool armed_ = false;
};

// Distinct window sizes the window passed through between kBegin and kEnd
// (consecutive repeats collapsed). A single-step transition yields exactly
// one entry: the final size.
inline std::vector<SIZE> WindowSizesDuringTransition(
    const std::vector<FullscreenTraceEvent>& events) {
  std::vector<SIZE> sizes;
  bool inside = false;
  for (const FullscreenTraceEvent& e : events) {
    if (e.kind == FullscreenTraceKind::kBegin) {
      inside = true;
      continue;
    }
    if (e.kind == FullscreenTraceKind::kEnd) {
      break;
    }
    if (!inside || e.kind != FullscreenTraceKind::kWindowPos) {
      continue;
    }
    const SIZE size{e.window.right - e.window.left,
                    e.window.bottom - e.window.top};
    if (sizes.empty() || sizes.back().cx != size.cx ||
        sizes.back().cy != size.cy) {
      sizes.push_back(size);
    }
  }
  return sizes;
}

}  // namespace fushi

#endif  // RUNNER_FULLSCREEN_TRACE_H_
