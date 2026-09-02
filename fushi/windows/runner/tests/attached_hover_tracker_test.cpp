#include "../attached_hover_tracker.h"

#include <iostream>

namespace {

bool Expect(bool condition, const char *message) {
  if (condition)
    return true;
  std::cerr << "attached_hover_tracker_test: " << message << '\n';
  return false;
}

} // namespace

int main() {
  bool ok = true;
  fushi::AttachedHoverTracker tracker;

  ok &= Expect(!tracker.Observe(false, 3, 1, 1, 7),
               "shift released must never fire");
  ok &= Expect(tracker.last_cluster() == -1,
               "shift released must keep the anchor empty");
  ok &= Expect(!tracker.Observe(true, -1, 1, 1, 7),
               "shift over a gap must not fire");
  ok &= Expect(tracker.Observe(true, 3, 1, 1, 7),
               "first shift hover over a cluster must fire");
  ok &= Expect(!tracker.Observe(true, 3, 1, 1, 7),
               "polling the same cluster must not fire again");
  ok &= Expect(tracker.Observe(true, 4, 1, 1, 7),
               "moving to another cluster must fire");
  ok &= Expect(!tracker.Observe(true, -1, 1, 1, 7),
               "leaving the text must not fire");
  ok &= Expect(tracker.last_cluster() == -1,
               "leaving the text must release the anchor");
  ok &= Expect(tracker.Observe(true, 4, 1, 1, 7),
               "returning to the same cluster after a gap must fire again");
  ok &= Expect(!tracker.Observe(false, 4, 1, 1, 7),
               "releasing shift must not fire");
  ok &= Expect(tracker.Observe(true, 4, 1, 1, 7),
               "pressing shift again over the same cluster must fire");
  ok &= Expect(tracker.Observe(true, 4, 1, 1, 8),
               "a new text generation must count as a new cluster");
  ok &= Expect(tracker.Observe(true, 4, 1, 2, 8),
               "a new surface epoch must count as a new cluster");
  ok &= Expect(tracker.Observe(true, 4, 2, 2, 8),
               "a new session epoch must count as a new cluster");
  ok &= Expect(!tracker.Observe(true, 4, 2, 2, 8),
               "the same identity must still be de-duplicated");

  if (!ok) {
    std::cerr << "attached_hover_tracker_test: FAILED\n";
    return 1;
  }
  std::cout << "attached_hover_tracker_test: OK\n";
  return 0;
}
