#include "../attached_glyph_transaction_latch.h"

#include <cstdint>
#include <iostream>

namespace {

bool Expect(bool condition, const char *message) {
  if (condition)
    return true;
  std::cerr << "attached_glyph_transaction_latch_test: " << message << '\n';
  return false;
}

} // namespace

int main() {
  bool ok = true;
  fushi::AttachedGlyphTransactionLatch latch;

  ok &= Expect(latch.Begin(0x100000001ull, 17), "first down must latch");
  ok &= Expect(!latch.Begin(0x100000002ull, 18),
               "a second down must not replace a live transaction");

  latch.Cancel();
  ok &= Expect(latch.active(),
               "snapshot cancellation must retain the physical transaction");
  ok &= Expect(latch.cancelled(), "cancellation marker must be observable");
  ok &= Expect(latch.transaction_id() == 0x100000001ull,
               "cancellation must retain the original transaction id");

  ok &= Expect(latch.MarkPhysicalUp(), "paired up must be recorded");
  ok &= Expect(!latch.MarkPhysicalUp(),
               "a duplicate up must not create another release edge");
  ok &= Expect(!latch.CanPublishRelease(17, 0),
               "release must wait until the hook acknowledges down");
  ok &= Expect(!latch.CanPublishRelease(18, 18),
               "an unrelated acknowledged request must not unlock release");
  ok &= Expect(latch.CanPublishRelease(17, 17),
               "the exact down acknowledgement must unlock release");
  ok &= Expect(latch.RecordReleaseRequest(19),
               "release publication sequence must latch exactly once");
  ok &= Expect(!latch.RecordReleaseRequest(20),
               "a duplicate release publication must be rejected");
  ok &= Expect(!latch.CanRetire(19, 17, 0),
               "transaction must remain owned until release is acknowledged");
  ok &= Expect(!latch.CanRetire(19, 19, 1),
               "non-neutral release acknowledgement must not retire");
  ok &= Expect(latch.CanRetire(19, 19, 0),
               "acknowledged neutral tail must allow retirement");
  ok &= Expect(latch.Retire() == 0x100000001ull,
               "neutral tail must retire the original transaction once");
  ok &= Expect(!latch.active(), "neutral tail must clear the latch");
  ok &= Expect(latch.Retire() == 0,
               "a duplicate retirement must not release a second time");

  ok &= Expect(latch.Begin(0x200000001ull, 23),
               "latch must accept the next independent down");
  ok &= Expect(latch.MarkPhysicalUp(),
               "non-cancelled transactions use the same up edge");
  ok &= Expect(latch.CanPublishRelease(23, 23),
               "acknowledged down can advance to release");

  fushi::AttachedGlyphTransactionLatch post_failure_latch;
  ok &= Expect(post_failure_latch.Begin(0x300000001ull, 31),
               "post-message failure must still own the published down");
  post_failure_latch.Cancel();
  ok &= Expect(post_failure_latch.active(),
               "post-message failure cancellation must retain ownership");
  ok &= Expect(!post_failure_latch.physical_up(),
               "post-message failure must not synthesize physical up");
  ok &= Expect(!post_failure_latch.CanPublishRelease(31, 31),
               "cancelled submission must retain the sampled-input tail");
  ok &= Expect(post_failure_latch.MarkPhysicalUp(),
               "only a later physical observation may release the tail");
  ok &= Expect(post_failure_latch.CanPublishRelease(31, 31),
               "the exact acknowledged down may release after real up");

  fushi::AttachedGlyphTransactionLatch disconnected_latch;
  ok &= Expect(disconnected_latch.Begin(0x400000001ull, 41),
               "disconnect fixture must own a published down");
  ok &= Expect(disconnected_latch.FailOpenRetireAfterPhysicalUp() == 0,
               "IPC loss must never abort a transaction still physically held");
  ok &= Expect(disconnected_latch.active(),
               "held transaction must remain owned after failed abort");
  ok &= Expect(disconnected_latch.MarkPhysicalUp(),
               "a real up must make terminal fail-open safe");
  ok &= Expect(disconnected_latch.FailOpenRetireAfterPhysicalUp() ==
                   0x400000001ull,
               "IPC loss after physical up must retire the host latch");
  ok &= Expect(!disconnected_latch.active(),
               "terminal fail-open must prevent a permanent global click sink");
  ok &= Expect(!fushi::AttachedGlyphAcknowledgeTimedOut(0, 10000, 3000),
               "held/no-up transactions must not have an abort deadline");
  ok &= Expect(!fushi::AttachedGlyphAcknowledgeTimedOut(7000, 9999, 3000),
               "acknowledgement wait must retain the full grace interval");
  ok &= Expect(fushi::AttachedGlyphAcknowledgeTimedOut(7000, 10000, 3000),
               "acknowledgement wait must terminate at the bounded deadline");

  if (!ok)
    return 1;
  std::cout << "attached_glyph_transaction_latch_test passed\n";
  return 0;
}
