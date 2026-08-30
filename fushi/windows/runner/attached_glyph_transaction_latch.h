#ifndef RUNNER_ATTACHED_GLYPH_TRANSACTION_LATCH_H_
#define RUNNER_ATTACHED_GLYPH_TRANSACTION_LATCH_H_

#include <cstdint>

namespace fushi {

inline bool AttachedGlyphAcknowledgeTimedOut(uint64_t physical_up_tick,
                                             uint64_t now,
                                             uint64_t timeout) {
  return physical_up_tick != 0 && timeout != 0 &&
         now - physical_up_tick >= timeout;
}

// Pure state seam for the WH_MOUSE_LL attached-glyph down/up lifetime.
// Removing a hit-test snapshot must not release a physical down: the game may
// sample the matching up through a different input API.  Cancellation therefore
// only marks the live transaction; ConsumeRelease() remains the sole normal
// release edge and is called by the paired WM_LBUTTONUP path.
class AttachedGlyphTransactionLatch {
public:
  bool Begin(uint64_t transaction_id, uint32_t down_request_seq) {
    if (transaction_id == 0 || down_request_seq == 0 || transaction_id_ != 0) {
      return false;
    }
    transaction_id_ = transaction_id;
    down_request_seq_ = down_request_seq;
    release_request_seq_ = 0;
    physical_up_ = false;
    cancelled_ = false;
    return true;
  }

  void Cancel() {
    if (transaction_id_ != 0)
      cancelled_ = true;
  }

  bool MarkPhysicalUp() {
    if (transaction_id_ == 0)
      return false;
    const bool first = !physical_up_;
    physical_up_ = true;
    return first;
  }

  bool CanPublishRelease(uint32_t request_seq, uint32_t applied_seq) const {
    return transaction_id_ != 0 && physical_up_ && release_request_seq_ == 0 &&
           request_seq == down_request_seq_ && applied_seq == down_request_seq_;
  }

  bool RecordReleaseRequest(uint32_t release_request_seq) {
    if (transaction_id_ == 0 || !physical_up_ || release_request_seq == 0 ||
        release_request_seq_ != 0) {
      return false;
    }
    release_request_seq_ = release_request_seq;
    return true;
  }

  bool CanRetire(uint32_t request_seq, uint32_t applied_seq,
                 uint32_t active_buttons) const {
    return transaction_id_ != 0 && release_request_seq_ != 0 &&
           request_seq == release_request_seq_ &&
           applied_seq == release_request_seq_ && active_buttons == 0;
  }

  uint64_t Retire() {
    const uint64_t transaction_id = transaction_id_;
    transaction_id_ = 0;
    down_request_seq_ = 0;
    release_request_seq_ = 0;
    physical_up_ = false;
    cancelled_ = false;
    return transaction_id;
  }

  // IPC can disappear after the physical up has already been swallowed.  At
  // that point there is no acknowledgement left to wait for, and retaining the
  // host latch would make the process-wide LL hook eat every future left click.
  // This is deliberately unavailable while the button may still be held: only
  // a real WM_LBUTTONUP or the delayed physical-state reconciliation may open
  // this terminal fail-open edge.
  uint64_t FailOpenRetireAfterPhysicalUp() {
    if (transaction_id_ == 0 || !physical_up_)
      return 0;
    cancelled_ = true;
    return Retire();
  }

  uint64_t transaction_id() const { return transaction_id_; }
  uint32_t down_request_seq() const { return down_request_seq_; }
  uint32_t release_request_seq() const { return release_request_seq_; }
  bool active() const { return transaction_id_ != 0; }
  bool physical_up() const { return physical_up_; }
  bool cancelled() const { return cancelled_; }

private:
  uint64_t transaction_id_ = 0;
  uint32_t down_request_seq_ = 0;
  uint32_t release_request_seq_ = 0;
  bool physical_up_ = false;
  bool cancelled_ = false;
};

} // namespace fushi

#endif // RUNNER_ATTACHED_GLYPH_TRANSACTION_LATCH_H_
