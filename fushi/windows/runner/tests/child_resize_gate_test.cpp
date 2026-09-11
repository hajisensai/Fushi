// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批
// 消失、测试空跑照样"通过"。与 window_activation_policy_test.cpp 同一写法。
#undef NDEBUG

#include "../child_resize_gate.h"

#include <iostream>
#include <string>

namespace {

using Decision = ChildResizeGate::Decision;

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

constexpr ChildSize kMaximized{2560, 1440};   // S0: maximised client
constexpr ChildSize kUnzoomed{2549, 1434};    // size1: monitor rect minus frame
constexpr ChildSize kFullscreen{2560, 1440};  // size2 == S0 on this monitor
constexpr ChildSize kNormal{1634, 1133};

// A delivery that returned before the engine timeout = frame presented.
constexpr int64_t kFast = 12;
// A delivery that hit the engine's 100 ms timeout branch.
constexpr int64_t kTimedOut = 106;

// Deliver |size| and report the measured duration, the way Win32Window does.
Decision Deliver(ChildResizeGate& gate, ChildSize size, int64_t elapsed_ms) {
  const Decision decision = gate.Request(size);
  if (decision == Decision::kDeliver) {
    gate.DeliveryFinished(elapsed_ms);
  }
  return decision;
}

bool TestFastPathNeverDefers() {
  bool ok = true;
  ChildResizeGate gate;
  ok &= Expect(Deliver(gate, kNormal, kFast) == Decision::kDeliver,
               "first size is delivered");
  ok &= Expect(!gate.has_pending(), "fast delivery is confirmed immediately");
  ok &= Expect(Deliver(gate, kMaximized, kFast) == Decision::kDeliver,
               "maximise delivered");
  ok &= Expect(Deliver(gate, kUnzoomed, kFast) == Decision::kDeliver,
               "unzoom step delivered when the engine keeps up");
  ok &= Expect(Deliver(gate, kFullscreen, kFast) == Decision::kDeliver,
               "A -> B -> A is plain deliveries when every step was presented");
  ok &= Expect(!gate.has_pending() && !gate.has_deferred(),
               "nothing pending after fast round trip");
  return ok;
}

bool TestSameSizeIsNoChange() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kNormal, kFast);
  ok &= Expect(gate.Request(kNormal) == Decision::kNoChange,
               "re-requesting the current child size is a no-op");
  ok &= Expect(gate.Request(ChildSize{0, 0}) == Decision::kNoChange,
               "zero-area (minimised) sizes are never delivered");
  ok &= Expect(gate.Request(ChildSize{2560, 0}) == Decision::kNoChange,
               "zero height is never delivered");
  ok &= Expect(gate.child_size().has_value() &&
                   *gate.child_size() == kNormal,
               "child keeps its last real size across minimise");
  return ok;
}

// The measured BUG-2462 sequence: maximised → unzoom (times out, Dart busy) →
// back to the maximised size. The last step must be deferred, not delivered.
bool TestFullscreenRoundTripWhileBusyDefers() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kMaximized, kFast);
  ok &= Expect(Deliver(gate, kUnzoomed, kTimedOut) == Decision::kDeliver,
               "unzoom step is delivered (surface differs)");
  ok &= Expect(gate.has_pending(), "timed-out delivery stays pending");
  ok &= Expect(gate.Request(kFullscreen) == Decision::kDefer,
               "returning to the surface size while pending is deferred");
  ok &= Expect(gate.has_deferred(), "deferred size is parked");
  ok &= Expect(gate.child_size().has_value() &&
                   *gate.child_size() == kUnzoomed,
               "child stays at the pending size until confirmation");
  // A stale frame (old size) must not confirm anything.
  ok &= Expect(!gate.OnFrameRasterized(kMaximized).has_value(),
               "stale frame of the old size does not release the deferral");
  ok &= Expect(gate.has_pending() && gate.has_deferred(),
               "stale frame leaves state untouched");
  // Dart finally rasterises the pending size: confirm and hand back the
  // deferred request.
  const std::optional<ChildSize> next = gate.OnFrameRasterized(kUnzoomed);
  ok &= Expect(next.has_value() && *next == kFullscreen,
               "confirmation releases the deferred size for delivery");
  ok &= Expect(gate.has_pending() && !gate.has_deferred(),
               "released size becomes the new pending delivery");
  gate.DeliveryFinished(kFast);
  ok &= Expect(!gate.has_pending(), "fast re-delivery confirms");
  ok &= Expect(gate.surface_size().has_value() &&
                   *gate.surface_size() == kFullscreen,
               "surface tracks the confirmed size");
  return ok;
}

// Dart's report can arrive while the platform thread is still inside the
// engine's wait loop (it pumps platform tasks); DeliveryFinished must honour
// a report that already names the pending size.
bool TestReportDuringDeliveryConfirms() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kMaximized, kFast);
  ok &= Expect(gate.Request(kUnzoomed) == Decision::kDeliver, "deliver");
  gate.OnFrameRasterized(kUnzoomed);  // arrives before DeliveryFinished
  gate.DeliveryFinished(kTimedOut);
  ok &= Expect(!gate.has_pending(),
               "report received during the delivery confirms it");
  ok &= Expect(gate.Request(kFullscreen) == Decision::kDeliver,
               "no deferral once the pending size was confirmed");
  return ok;
}

// A different size while pending is not hazardous: it simply replaces the
// engine's target. The parked request is dropped (latest wins).
bool TestDifferentSizeWhilePendingDelivers() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kMaximized, kFast);
  Deliver(gate, kUnzoomed, kTimedOut);
  ok &= Expect(gate.Request(kFullscreen) == Decision::kDefer, "deferred");
  ok &= Expect(Deliver(gate, kNormal, kTimedOut) == Decision::kDeliver,
               "a third size is delivered even while pending");
  ok &= Expect(!gate.has_deferred(), "latest request supersedes the deferral");
  ok &= Expect(!gate.OnFrameRasterized(kUnzoomed).has_value(),
               "confirmation of a superseded size is ignored");
  ok &= Expect(gate.has_pending(), "the newest delivery is what stays pending");
  ok &= Expect(!gate.OnFrameRasterized(kNormal).has_value(),
               "confirming the newest size has nothing deferred to release");
  ok &= Expect(!gate.has_pending(), "newest size confirmed");
  return ok;
}

// Review finding on the first cut: a single "last confirmed surface" is stale
// while a timed-out delivery may already have been rasterised but not yet
// reported. W → X (times out) → Y (times out) → X must NOT deliver X: the
// engine's surface may already be X, and delivering it would hit the
// same-size early return with target Y armed.
bool TestSupersededUnconfirmedSizeIsStillHazardous() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kNormal, kFast);  // W confirmed
  ok &= Expect(Deliver(gate, kMaximized, kTimedOut) == Decision::kDeliver,
               "X delivered");
  ok &= Expect(Deliver(gate, kUnzoomed, kTimedOut) == Decision::kDeliver,
               "Y supersedes the unconfirmed X");
  ok &= Expect(gate.surface_candidate_count() == 2,
               "surface may now be W or X");
  ok &= Expect(gate.Request(kMaximized) == Decision::kDefer,
               "returning to the superseded, unconfirmed X is deferred");
  ok &= Expect(gate.Request(kNormal) == Decision::kDefer,
               "returning to the last confirmed W is deferred too");
  // Dart's late report of X (rasterised before Y's metrics reached it) says
  // nothing about the armed target Y.
  ok &= Expect(!gate.OnFrameRasterized(kMaximized).has_value(),
               "late report of the superseded X does not release anything");
  ok &= Expect(gate.has_pending(), "Y still pending after X's late report");
  // Y confirmed: the surface is exactly Y again, candidates collapse, and the
  // parked request (latest one wins: W) is delivered.
  const std::optional<ChildSize> next = gate.OnFrameRasterized(kUnzoomed);
  ok &= Expect(next.has_value() && *next == kNormal,
               "confirming Y releases the parked request");
  ok &= Expect(gate.surface_candidate_count() == 1 &&
                   gate.surface_size().has_value() &&
                   *gate.surface_size() == kUnzoomed,
               "candidates collapse to the confirmed surface");
  gate.DeliveryFinished(kFast);
  ok &= Expect(Deliver(gate, kMaximized, kFast) == Decision::kDeliver,
               "with nothing pending, X is a plain delivery again");
  return ok;
}

// An old report of a size must not confirm a *later* delivery of that size.
bool TestStaleReportDoesNotConfirmLaterDelivery() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kNormal, kFast);
  gate.OnFrameRasterized(kMaximized);  // stray report, size != child
  ok &= Expect(Deliver(gate, kMaximized, kTimedOut) == Decision::kDeliver,
               "deliver X later");
  ok &= Expect(gate.has_pending(),
               "the earlier stray report of X must not confirm this delivery");
  return ok;
}

// The parked size can equal the size being confirmed (parent bounced back to
// the pending size); nothing is delivered then.
bool TestDeferredEqualToConfirmedIsDropped() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kMaximized, kFast);
  Deliver(gate, kUnzoomed, kTimedOut);
  ok &= Expect(gate.Request(kMaximized) == Decision::kDefer, "deferred");
  ok &= Expect(gate.Request(kUnzoomed) == Decision::kNoChange,
               "parent bounced back to the pending size: nothing to deliver");
  ok &= Expect(!gate.OnFrameRasterized(kUnzoomed).has_value(),
               "confirmation with nothing parked delivers nothing");
  ok &= Expect(!gate.has_pending() && !gate.has_deferred(), "settled");
  return ok;
}

// Before the first confirmation the surface is unknown; nothing can be judged
// hazardous, so every size is delivered (the engine has no surface yet and
// never arms a target in that state).
bool TestUnknownSurfaceDeliversUnseenSizes() {
  bool ok = true;
  ChildResizeGate gate;
  ok &= Expect(Deliver(gate, kMaximized, kTimedOut) == Decision::kDeliver,
               "first delivery");
  ok &= Expect(Deliver(gate, kUnzoomed, kTimedOut) == Decision::kDeliver,
               "second delivery while first is pending");
  ok &= Expect(Deliver(gate, kNormal, kTimedOut) == Decision::kDeliver,
               "a never-delivered size is delivered: it cannot be the surface");
  // The superseded first delivery may have become the surface meanwhile, so
  // it is hazardous even though no size was ever confirmed.
  ok &= Expect(gate.Request(kMaximized) == Decision::kDefer,
               "return to a superseded unconfirmed size is deferred");
  return ok;
}

// Re-requesting the deferred size itself, or the pending size, while a
// deferral is parked.
bool TestRequestsWhileDeferred() {
  bool ok = true;
  ChildResizeGate gate;
  Deliver(gate, kMaximized, kFast);
  Deliver(gate, kUnzoomed, kTimedOut);
  ok &= Expect(gate.Request(kFullscreen) == Decision::kDefer, "deferred");
  ok &= Expect(gate.Request(kFullscreen) == Decision::kDefer,
               "repeating the deferred request keeps it parked");
  ok &= Expect(gate.Request(kUnzoomed) == Decision::kNoChange,
               "requesting the pending (current child) size is a no-op");
  ok &= Expect(!gate.has_deferred(),
               "asking for the current child size cancels the deferral");
  return ok;
}

}  // namespace

int main() {
  bool passed = true;
  passed &= TestFastPathNeverDefers();
  passed &= TestSameSizeIsNoChange();
  passed &= TestFullscreenRoundTripWhileBusyDefers();
  passed &= TestReportDuringDeliveryConfirms();
  passed &= TestDifferentSizeWhilePendingDelivers();
  passed &= TestSupersededUnconfirmedSizeIsStillHazardous();
  passed &= TestStaleReportDoesNotConfirmLaterDelivery();
  passed &= TestDeferredEqualToConfirmedIsDropped();
  passed &= TestUnknownSurfaceDeliversUnseenSizes();
  passed &= TestRequestsWhileDeferred();

  if (!passed) {
    std::cerr << "child_resize_gate_test FAILED\n";
    return 1;
  }
  std::cout << "child_resize_gate_test passed\n";
  return 0;
}
