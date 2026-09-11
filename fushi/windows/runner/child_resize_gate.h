#ifndef RUNNER_CHILD_RESIZE_GATE_H_
#define RUNNER_CHILD_RESIZE_GATE_H_

#include <cstdint>
#include <optional>

// BUG-2462: the only gate through which the Flutter view (child HWND) is ever
// resized. It exists because of a hazard in the Flutter Windows engine's resize
// synchroniser (flutter_windows_view.cc, `OnWindowSizeChanged` /
// `OnFrameGenerated`, verified on engine 3.44):
//
//   * a child WM_SIZE arms a resize *target*; until a frame of exactly that
//     size is rasterised, EVERY other frame is dropped. The platform thread
//     waits at most 100 ms (`kWindowResizeTimeout`) and then returns without
//     clearing the target;
//   * a child WM_SIZE whose size equals the engine's *current surface* takes an
//     early return that only forwards the metrics and leaves the armed target
//     untouched (`SurfaceWillUpdate` == false);
//   * external-texture frames (the video player) re-rasterise the last layer
//     tree without a Dart build, so they carry the stale size forever.
//
// Put together, "A → B → A" delivered to the child while Dart is busy (the
// first step times out, the second one hits the early return) pins the target
// to B while Dart keeps rendering A: every frame is dropped and the whole
// window freezes until the next size change replaces the target. Entering /
// leaving the runner-owned fullscreen from a maximised window produces exactly
// that sequence when the maximised client already spans the monitor
// (measured: 2560x1440 → 2549x1434 → 2560x1440, 106 ms apart), and the user
// sees it as "the picture freezes when I go fullscreen while the video is
// still loading".
//
// The gate closes the hazard structurally instead of guessing at timing: a
// delivered size stays *pending* until the engine is known to present it, and
// while something is pending a request for the size the surface currently has
// is deferred until that confirmation arrives. Two confirmation sources:
//
//   1. the delivery itself returned in under the engine timeout — the timeout
//      branch cannot return earlier than 100 ms, so a fast return means the
//      frame was presented (or the size was a no-op / there was no surface
//      yet, both of which leave nothing armed);
//   2. Dart reports the size of every *rasterised* frame whose size changed
//      (`reportRasterizedFrameSize` on `app.fushi/window`, driven by
//      `FrameTiming.frameNumber`), which is the authoritative "surface is now
//      this size" signal when the delivery did time out.
//
// Pure state machine, no HWND: the owner performs the MoveWindow and feeds back
// the measured duration. Sizes are the child's client size in physical pixels.
struct ChildSize {
  int32_t width = 0;
  int32_t height = 0;

  bool operator==(const ChildSize& other) const {
    return width == other.width && height == other.height;
  }
  bool operator!=(const ChildSize& other) const { return !(*this == other); }
  bool IsEmpty() const { return width <= 0 || height <= 0; }
};

class ChildResizeGate {
 public:
  // Mirrors `kWindowResizeTimeout` in flutter_windows_view.cc. A delivery that
  // took at least this long went through the timeout branch.
  static constexpr int64_t kEngineResizeTimeoutMs = 100;

  enum class Decision {
    // Resize the child to the requested size now, then call DeliveryFinished.
    kDeliver,
    // Nothing to do: the child already has this size (or the size is empty).
    kNoChange,
    // Hazardous right now; the size is parked and handed back by
    // OnFrameRasterized once the pending delivery is confirmed.
    kDefer,
  };

  Decision Request(ChildSize requested) {
    if (requested.IsEmpty()) {
      // The engine ignores zero-area targets entirely
      // (`non_zero_target_dims`). Delivering them would only replace the
      // child's real size with something Dart can never confirm (minimised
      // windows stop scheduling frames), so keep the child at its last real
      // size while the window is minimised.
      return Decision::kNoChange;
    }
    if (child_.has_value() && requested == *child_) {
      deferred_.reset();
      return Decision::kNoChange;
    }
    if (pending_.has_value() && surface_.has_value() && requested == *surface_) {
      deferred_ = requested;
      return Decision::kDefer;
    }
    deferred_.reset();
    child_ = requested;
    pending_ = requested;
    return Decision::kDeliver;
  }

  // Called right after the child was resized to the last kDeliver size.
  // `elapsed_ms` is how long the synchronous MoveWindow took.
  void DeliveryFinished(int64_t elapsed_ms) {
    if (!pending_.has_value()) {
      return;
    }
    if (elapsed_ms < kEngineResizeTimeoutMs ||
        (last_rasterized_.has_value() && *last_rasterized_ == *pending_)) {
      // Presented before the engine timeout, or Dart's report for this very
      // size already arrived while the platform thread was inside the
      // engine's wait loop (it pumps platform tasks).
      Confirm();
    }
  }

  // Dart reported that a frame of this size was rasterised. Returns the size
  // that was deferred and must be delivered now (then call DeliveryFinished
  // again), if any.
  std::optional<ChildSize> OnFrameRasterized(ChildSize rasterized) {
    last_rasterized_ = rasterized;
    if (!pending_.has_value()) {
      if (child_.has_value() && rasterized == *child_) {
        surface_ = rasterized;
      }
      return std::nullopt;
    }
    if (rasterized != *pending_) {
      // A stale frame (built before the metrics of the pending size reached
      // Dart) or a frame for a size that has since been superseded.
      return std::nullopt;
    }
    Confirm();
    if (!deferred_.has_value()) {
      return std::nullopt;
    }
    const ChildSize next = *deferred_;
    deferred_.reset();
    child_ = next;
    pending_ = next;
    return next;
  }

  // The child's current (last delivered) size, if any.
  std::optional<ChildSize> child_size() const { return child_; }
  // The size the engine is known to present at, if known.
  std::optional<ChildSize> surface_size() const { return surface_; }
  bool has_pending() const { return pending_.has_value(); }
  bool has_deferred() const { return deferred_.has_value(); }

 private:
  void Confirm() {
    surface_ = pending_;
    pending_.reset();
  }

  std::optional<ChildSize> child_;
  std::optional<ChildSize> surface_;
  std::optional<ChildSize> pending_;
  std::optional<ChildSize> deferred_;
  std::optional<ChildSize> last_rasterized_;
};

#endif  // RUNNER_CHILD_RESIZE_GATE_H_
