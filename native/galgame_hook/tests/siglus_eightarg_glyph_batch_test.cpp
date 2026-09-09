#include "siglus_eightarg_glyph_batch.h"
#include <cstdio>
#include <cstdlib>
#include <thread>

namespace {
using namespace fushi_voice_hook;
namespace batch = siglus_eightarg_glyph_batch;
unsigned checks = 0;
void Check(bool value) {
  ++checks;
  if (!value) { std::fprintf(stderr, "check %u failed\n", checks); std::exit(91); }
}
const batch::Identity kIdentity{7, 0, {0x10000, 1, 0x20000, 0x20248, 0x20124},
                                0x30000, 0x30000 + 2 * 0x3b4, 0x30000 + 4 * 0x3b4};
SiglusGlyphRecord Glyph(uint32_t ordinal) {
  return {static_cast<uint16_t>(0x3041 + ordinal), 20,
          static_cast<int32_t>(ordinal * 20), 40};
}
void Complete(batch::Collector& c, const batch::Identity& identity, uint32_t count) {
  for (uint32_t i = 0; i < count; ++i) {
    const auto r = c.Push(identity, i, count, Glyph(i));
    Check(r.accepted && r.complete == (i + 1 == count));
    if (i + 1 != count) Check(c.size() == 0 && !c.entries() && !c.identity());
  }
  Check(c.size() == count && c.entries() && c.identity() && batch::Same(*c.identity(), identity));
  for (uint32_t i = 0; i < count; ++i) Check(batch::Same(c.entries()[i], Glyph(i)));
}
void TestCompleteAndIdenticalRedraw() {
  for (uint32_t count : {1u, 2u, 16u, 256u}) {
    batch::Collector c;
    Check(c.size() == 0 && c.entries() == nullptr);
    Complete(c, kIdentity, count);
    // Every identical redraw is delivered, including after a window reset.
    for (unsigned round = 0; round < 3; ++round) {
      for (uint32_t i = 0; i < count; ++i) {
        const auto r = c.Push(kIdentity, i, count, Glyph(i));
        Check(r.accepted && !r.invalidate_previous && r.complete == (i + 1 == count));
      }
    }
    c.Reset(); Check(!c.entries() && !c.identity() && c.size() == 0);
    Complete(c, kIdentity, count);
  }
}
void TestChangedRecordBarrier() {
  for (uint32_t changed = 0; changed < 4; ++changed) {
    for (unsigned field = 0; field < 4; ++field) {
      batch::Collector c; Complete(c, kIdentity, 4);
      SiglusGlyphRecord modified = Glyph(changed);
      if (field == 0) ++modified.code_unit;
      if (field == 1) ++modified.extent;
      if (field == 2) ++modified.x;
      if (field == 3) ++modified.y;
      for (uint32_t i = 0; i < 4; ++i) {
        const auto r = c.Push(kIdentity, i, 4, i == changed ? modified : Glyph(i));
        Check(r.accepted && r.invalidate_previous == (i == changed));
        Check(r.complete == (i == 3));
      }
      Check(batch::Same(c.entries()[changed], modified));
      // Reverting B to A is another real change, not revival of old A.
      for (uint32_t i = 0; i < 4; ++i) {
        const auto r = c.Push(kIdentity, i, 4, Glyph(i));
        Check(r.invalidate_previous == (i == changed));
      }
    }
  }
}
void TestSequenceAndCountFailures() {
  struct Failure { uint32_t ordinal, count; };
  for (auto f : {Failure{0, 4}, {2, 4}, {3, 4}, {1, 3}, {1, 5},
                 {1, 0}, {1, 257}, {UINT32_MAX, UINT32_MAX}}) {
    batch::Collector c; Complete(c, kIdentity, 4);
    Check(c.Push(kIdentity, 0, 4, Glyph(0)).accepted);
    const auto r = c.Push(kIdentity, f.ordinal, f.count, Glyph(1));
    Check(!r.accepted && !r.complete && r.invalidate_previous);
    Check(!c.entries() && !c.identity() && c.size() == 0);
    auto tail = c.Push(kIdentity, 1, 4, Glyph(1));
    Check(!tail.accepted && !tail.invalidate_previous && !tail.complete);
    Complete(c, kIdentity, 4);
  }
  for (uint32_t count : {0u, 257u, UINT32_MAX}) {
    batch::Collector c; auto r = c.Push(kIdentity, 0, count, Glyph(0));
    Check(!r.accepted && !r.complete && !r.invalidate_previous);
  }
  batch::Collector c; Complete(c, kIdentity, 3);
  Check(c.Push(kIdentity, 0, 2, Glyph(0)).invalidate_previous);
  auto done = c.Push(kIdentity, 1, 2, Glyph(1));
  Check(done.complete && !done.invalidate_previous && c.size() == 2);
  // Complete is not permission to continue at ordinal count or replay a tail.
  auto tail = c.Push(kIdentity, 1, 2, Glyph(1));
  Check(!tail.accepted && tail.invalidate_previous && !c.entries());
}
void TestIdentityAndReset() {
  for (unsigned field = 0; field < 10; ++field) {
    auto other = kIdentity;
    if (field == 0) ++other.occurrence;
    if (field == 1) ++other.capture_epoch;
    if (field == 2) other.body.address += 0x1630;
    if (field == 3) ++other.body.surface_index;
    if (field == 4) other.body.surface_begin += 0x124;
    if (field == 5) other.body.surface_end += 0x124;
    if (field == 6) other.body.surface += 0x124;
    if (field == 7) other.glyph_begin += 0x3b4;
    if (field == 8) other.glyph_end += 0x3b4;
    if (field == 9) other.glyph_capacity += 0x3b4;
    batch::Collector c; Complete(c, kIdentity, 2);
    auto start = c.Push(other, 0, 2, Glyph(0));
    Check(start.accepted && start.invalidate_previous && !start.complete);
    Check(c.Push(other, 1, 2, Glyph(1)).complete);
    c.Reset(); Complete(c, kIdentity, 2);
    c.Push(kIdentity, 0, 2, Glyph(0));
    const auto bad = c.Push(other, 1, 2, Glyph(1));
    Check(!bad.accepted && bad.invalidate_previous && !c.entries());
    Complete(c, other, 2);
  }
  for (unsigned field = 0; field < 3; ++field) {
    auto invalid = kIdentity;
    if (field == 0) invalid.occurrence = 0;
    if (field == 1) invalid.body.address = 0;
    if (field == 2) invalid.body.surface = 0;
    batch::Collector c; Complete(c, kIdentity, 2);
    auto result = c.Push(invalid, 0, 2, Glyph(0));
    Check(!result.accepted && result.invalidate_previous);
  }
  batch::Collector c; Complete(c, kIdentity, 2);
  c.Push(kIdentity, 0, 2, Glyph(0));
  c.Reset(); // Decode failure, window/session reset: a tail cannot revive it.
  Check(!c.Push(kIdentity, 1, 2, Glyph(1)).accepted);
  Complete(c, kIdentity, 2);
  // No lifetime capacity exhaustion: each complete batch reuses fixed slots.
  for (uint64_t occurrence = 10; occurrence < 1034; ++occurrence) {
    auto id = kIdentity; id.occurrence = occurrence;
    Check(c.Push(id, 0, 1, Glyph(0)).complete);
  }
}
// Compile the actual collector with the same Windows TLS storage used by a
// producer callback; another thread cannot inherit an incomplete prefix.
__declspec(thread) batch::Collector tls_collector;
void TestTls() {
  tls_collector.Reset();
  Check(tls_collector.Push(kIdentity, 0, 2, Glyph(0)).accepted);
  bool accepted = true;
  std::thread other([&] { accepted = tls_collector.Push(kIdentity, 1, 2, Glyph(1)).accepted; });
  other.join(); Check(!accepted);
  Check(tls_collector.Push(kIdentity, 1, 2, Glyph(1)).complete);
}
} // namespace
int main() {
  TestCompleteAndIdenticalRedraw(); TestChangedRecordBarrier();
  TestSequenceAndCountFailures(); TestIdentityAndReset(); TestTls();
  std::printf("siglus_eightarg_glyph_batch: %u checks passed\n", checks);
}
