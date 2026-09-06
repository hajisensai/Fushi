#ifndef RUNNER_ATTACHED_HOVER_TRACKER_H_
#define RUNNER_ATTACHED_HOVER_TRACKER_H_

#include <cstdint>

namespace fushi {

// Pure decision seam for Shift+hover lookup on the attached calibrated glyph
// surface (attached_text_surface_window.cpp hover timer).
//
// Shift is the explicit user intent (same contract as the floating lyric
// window's pass-through hover, BUG-1480): with Shift released nothing fires
// and the anchor is dropped.  While Shift is held, a lookup fires once per
// distinct cluster; leaving the text (cluster < 0) releases the anchor so
// returning to the same cluster fires again, and a new session/surface epoch
// or text generation always counts as a new cluster.  The tracker never
// consumes input and knows nothing about the shield transaction.
class AttachedHoverTracker {
public:
  bool Observe(bool shift_down, int cluster, uint64_t session_epoch,
               uint64_t surface_epoch, int64_t text_generation) {
    if (!shift_down || cluster < 0) {
      Reset();
      return false;
    }
    if (cluster == last_cluster_ && session_epoch == session_epoch_ &&
        surface_epoch == surface_epoch_ &&
        text_generation == text_generation_) {
      return false;
    }
    last_cluster_ = cluster;
    session_epoch_ = session_epoch;
    surface_epoch_ = surface_epoch;
    text_generation_ = text_generation;
    return true;
  }

  void Reset() {
    last_cluster_ = -1;
    session_epoch_ = 0;
    surface_epoch_ = 0;
    text_generation_ = 0;
  }

  int last_cluster() const { return last_cluster_; }

private:
  int last_cluster_ = -1;
  uint64_t session_epoch_ = 0;
  uint64_t surface_epoch_ = 0;
  int64_t text_generation_ = 0;
};

} // namespace fushi

#endif // RUNNER_ATTACHED_HOVER_TRACKER_H_
