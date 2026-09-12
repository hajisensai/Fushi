#ifndef RUNNER_CHILD_RESIZE_GATE_H_
#define RUNNER_CHILD_RESIZE_GATE_H_

#include <cstddef>
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
    if (pending_.has_value() && MayBeSurface(requested)) {
      // While a delivery is unconfirmed the engine's surface is one of
      // |surface_candidates_|: the last confirmed size, or any size delivered
      // since that Dart may already have rasterised without the report having
      // reached us (release batches FrameTiming for up to a second, and the
      // UI isolate being busy is exactly this bug's scenario). Delivering any
      // of them could hit the engine's "same size as surface" early return
      // and pin the target — park it until the pending size is confirmed and
      // the surface is exactly known again.
      deferred_ = requested;
      return Decision::kDefer;
    }
    if (pending_.has_value()) {
      // Superseding an unconfirmed delivery: Dart may or may not have
      // rasterised it in the meantime, so from now on it is one of the sizes
      // the surface may have.
      AddCandidate(*pending_);
    }
    deferred_.reset();
    // Only a report that arrives *during* this delivery may confirm it; an
    // older report of the same size says nothing about the new target.
    last_rasterized_.reset();
    child_ = requested;
    pending_ = requested;
    return Decision::kDeliver;
  }

  // Called right after the child was resized to the last kDeliver size.
  // `elapsed_ms` is how long the synchronous MoveWindow took. Returns the size
  // that was parked and must be delivered next (then call DeliveryFinished
  // again), if this delivery got confirmed and something is still parked —
  // only the watchdog path (ReleaseStuckDeferred) leaves a deferral parked
  // across a delivery, so for ordinary deliveries this is always empty.
  std::optional<ChildSize> DeliveryFinished(int64_t elapsed_ms) {
    if (!pending_.has_value()) {
      return std::nullopt;
    }
    if (elapsed_ms < kEngineResizeTimeoutMs ||
        (last_rasterized_.has_value() && *last_rasterized_ == *pending_)) {
      // Presented before the engine timeout, or Dart's report for this very
      // size already arrived while the platform thread was inside the
      // engine's wait loop (it pumps platform tasks).
      Confirm();
      return TakeDeferred();
    }
    return std::nullopt;
  }

  // Watchdog valve for a deferral whose confirmation never arrives. The gate
  // is otherwise a pure "wait for Dart's report" machine: if the report of the
  // pending size is lost (the Dart-side frame tracker evicts a frame before
  // its FrameTiming lands and Dart then idles; a batch dropped on the way),
  // the parked size stays parked and the child keeps the pending size while
  // the window has moved on — until some *new* size comes along.
  //
  // The valve must NOT simply deliver the parked size: the engine's surface
  // may still be that size (Dart never got to rasterise the pending one), and
  // delivering it would hit the same-size early return with the old target
  // still armed — turning "child a few pixels off but live" into "every frame
  // dropped". Instead deliver a *fresh* size the surface cannot be (the parked
  // size nudged by one pixel, skipping every candidate): it replaces the armed
  // target unconditionally, and once Dart presents it the parked size follows
  // as a plain delivery. Costs one extra resize; never pins.
  //
  // Returns the nudge size to deliver now (then call DeliveryFinished, which
  // hands back the parked size on a fast confirm), or nothing when there is
  // no stuck deferral.
  std::optional<ChildSize> ReleaseStuckDeferred() {
    if (!pending_.has_value() || !deferred_.has_value()) {
      return std::nullopt;
    }
    const ChildSize parked = *deferred_;
    ChildSize nudge = parked;
    // Walk away from the parked height until the size is neither the pending
    // one nor any surface candidate. Bounded: at most kMaxCandidates + 2
    // sizes can be excluded.
    for (int32_t step = 1; step <= static_cast<int32_t>(kMaxCandidates) + 2;
         ++step) {
      nudge.height = parked.height > step ? parked.height - step
                                          : parked.height + step;
      if (nudge != *pending_ && !MayBeSurface(nudge)) {
        break;
      }
    }
    // The superseded pending size may have been rasterised meanwhile.
    AddCandidate(*pending_);
    last_rasterized_.reset();
    child_ = nudge;
    pending_ = nudge;
    // deferred_ stays parked: it is released when the nudge is confirmed.
    return nudge;
  }

  // Dart reported that a frame of this size was rasterised. Returns the size
  // that was deferred and must be delivered now (then call DeliveryFinished
  // again), if any.
  std::optional<ChildSize> OnFrameRasterized(ChildSize rasterized) {
    last_rasterized_ = rasterized;
    if (!pending_.has_value()) {
      if (child_.has_value() && rasterized == *child_) {
        SetSurface(rasterized);
      }
      return std::nullopt;
    }
    if (rasterized != *pending_) {
      // A stale frame (built before the metrics of the pending size reached
      // Dart) or a frame for a size that has since been superseded. Neither
      // says anything about the pending target.
      return std::nullopt;
    }
    // The pending size is always the engine's armed target (Request never
    // delivers a size the surface may already have), so a rasterised frame of
    // it was accepted and the surface is now exactly this size.
    Confirm();
    return TakeDeferred();
  }

  // The child's current (last delivered) size, if any.
  std::optional<ChildSize> child_size() const { return child_; }
  // The size the engine is known to present at (only exact while nothing is
  // pending), if known.
  std::optional<ChildSize> surface_size() const { return surface_; }
  bool has_pending() const { return pending_.has_value(); }
  bool has_deferred() const { return deferred_.has_value(); }
  size_t surface_candidate_count() const { return candidate_count_; }

 private:
  // Bounded: candidates only accumulate while deliveries keep timing out and
  // keep being superseded (a drag-resize on a stalled UI isolate). Beyond the
  // cap the oldest entry is dropped — being wrong about a size that old costs
  // one extra deferral at worst, never a missed one for recent sizes.
  static constexpr size_t kMaxCandidates = 16;

  void Confirm() {
    SetSurface(*pending_);
    pending_.reset();
  }

  // With nothing pending, hand the parked size over as the next delivery.
  std::optional<ChildSize> TakeDeferred() {
    if (!deferred_.has_value()) {
      return std::nullopt;
    }
    const ChildSize next = *deferred_;
    deferred_.reset();
    if (child_.has_value() && next == *child_) {
      return std::nullopt;
    }
    child_ = next;
    pending_ = next;
    return next;
  }

  void SetSurface(ChildSize size) {
    surface_ = size;
    candidate_count_ = 0;
    AddCandidate(size);
  }

  void AddCandidate(ChildSize size) {
    for (size_t i = 0; i < candidate_count_; ++i) {
      if (surface_candidates_[i] == size) {
        return;
      }
    }
    if (candidate_count_ == kMaxCandidates) {
      for (size_t i = 1; i < kMaxCandidates; ++i) {
        surface_candidates_[i - 1] = surface_candidates_[i];
      }
      --candidate_count_;
    }
    surface_candidates_[candidate_count_++] = size;
  }

  bool MayBeSurface(ChildSize size) const {
    for (size_t i = 0; i < candidate_count_; ++i) {
      if (surface_candidates_[i] == size) {
        return true;
      }
    }
    return false;
  }

  std::optional<ChildSize> child_;
  std::optional<ChildSize> surface_;
  std::optional<ChildSize> pending_;
  std::optional<ChildSize> deferred_;
  std::optional<ChildSize> last_rasterized_;
  ChildSize surface_candidates_[kMaxCandidates] = {};
  size_t candidate_count_ = 0;
};

#endif  // RUNNER_CHILD_RESIZE_GATE_H_
