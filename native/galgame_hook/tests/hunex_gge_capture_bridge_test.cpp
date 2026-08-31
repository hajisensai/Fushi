#include "hunex_gge_capture_bridge.h"

#include <atomic>
#include <cassert>
#include <cstdint>
#include <limits>
#include <thread>

namespace bridge = fushi_voice_hook::hunex_capture_bridge;

namespace fushi_voice_hook::hunex_capture_bridge {

struct TraversalCaptureBridgeTestPeer {
  static void HoldCallback(TraversalCaptureBridge *capture_bridge) {
    assert(capture_bridge != nullptr);
    uint32_t expected_owner = TraversalCaptureBridge::kOwnerIdle;
    assert(capture_bridge->owner_.compare_exchange_strong(
        expected_owner, TraversalCaptureBridge::kOwnerCallback,
        std::memory_order_acq_rel, std::memory_order_acquire));
  }

  static void ReleaseCallback(TraversalCaptureBridge *capture_bridge) {
    assert(capture_bridge != nullptr);
    capture_bridge->owner_.store(TraversalCaptureBridge::kOwnerIdle,
                                 std::memory_order_release);
  }
};

} // namespace fushi_voice_hook::hunex_capture_bridge

namespace {

constexpr uint32_t kRenderThread = 77u;

bridge::LogicalRect RectFor(uint32_t raw_index, int32_t base_x = 100) {
  return {base_x + static_cast<int32_t>(raw_index), 20, 12, 24};
}

bridge::SubmitOutcome Submit(bridge::TraversalCaptureBridge *capture_bridge,
                             uint32_t raw_index, uint32_t scalar = u'A',
                             uint32_t width = 1u,
                             bridge::LogicalRect rect = RectFor(0u)) {
  if (rect.x == 100)
    rect = RectFor(raw_index);
  return capture_bridge->SubmitGlyph(kRenderThread, raw_index, scalar, width,
                                     rect);
}

void TestIncreasingTraversalSealsOnlyOnRestart() {
  bridge::TraversalCaptureBridge capture_bridge;
  assert(capture_bridge.Reset());
  assert(Submit(&capture_bridge, 4u).glyph_accepted);
  assert(Submit(&capture_bridge, 6u).glyph_accepted);
  assert(Submit(&capture_bridge, 8u).glyph_accepted);

  bridge::TraversalSnapshot snapshot;
  assert(!capture_bridge.ReadLatest(&snapshot));

  const bridge::SubmitOutcome boundary = Submit(&capture_bridge, 4u);
  assert(boundary.glyph_accepted);
  assert(boundary.snapshot_published);
  assert(capture_bridge.ReadLatest(&snapshot));
  assert(snapshot.epoch == 1u);
  assert(snapshot.render_thread_id == kRenderThread);
  assert(snapshot.glyph_count == 3u);
  assert(snapshot.glyphs[0].raw_utf16_index == 4u);
  assert(snapshot.glyphs[1].raw_utf16_index == 6u);
  assert(snapshot.glyphs[2].raw_utf16_index == 8u);
}

void TestEqualIndexCreatesANewTraversalWithoutDuplicateGlyphs() {
  bridge::TraversalCaptureBridge capture_bridge;
  assert(capture_bridge.Reset());
  assert(Submit(&capture_bridge, 0u).glyph_accepted);
  assert(Submit(&capture_bridge, 1u).glyph_accepted);

  bridge::SubmitOutcome outcome = Submit(&capture_bridge, 1u);
  assert(outcome.glyph_accepted && outcome.snapshot_published);
  bridge::TraversalSnapshot snapshot;
  assert(capture_bridge.ReadLatest(&snapshot));
  assert(snapshot.glyph_count == 2u);
  assert(snapshot.glyphs[0].raw_utf16_index == 0u);
  assert(snapshot.glyphs[1].raw_utf16_index == 1u);

  outcome = Submit(&capture_bridge, 0u);
  assert(outcome.glyph_accepted && outcome.snapshot_published);
  assert(capture_bridge.ReadLatest(&snapshot));
  assert(snapshot.epoch == 2u);
  assert(snapshot.glyph_count == 1u);
  assert(snapshot.glyphs[0].raw_utf16_index == 1u);
}

void ExpectMalformedTraversalDropped(uint32_t raw_index, uint32_t scalar,
                                     uint32_t width,
                                     bridge::LogicalRect rect) {
  bridge::TraversalCaptureBridge capture_bridge;
  assert(capture_bridge.Reset());
  assert(Submit(&capture_bridge, 0u).glyph_accepted);
  const bridge::SubmitOutcome malformed =
      capture_bridge.SubmitGlyph(kRenderThread, raw_index, scalar, width, rect);
  assert(!malformed.glyph_accepted);
  assert(!malformed.quarantined);

  // The restart drops the whole malformed traversal; no prefix is exposed.
  bridge::SubmitOutcome outcome = Submit(&capture_bridge, 0u);
  assert(outcome.glyph_accepted && !outcome.snapshot_published);
  bridge::TraversalSnapshot snapshot;
  assert(!capture_bridge.ReadLatest(&snapshot));

  // A later clean traversal can be sealed normally.
  outcome = Submit(&capture_bridge, 0u);
  assert(outcome.glyph_accepted && outcome.snapshot_published);
  assert(capture_bridge.ReadLatest(&snapshot));
  assert(snapshot.glyph_count == 1u);
}

void TestInvalidScalarWidthIndexAndRectDropWholeTraversal() {
  ExpectMalformedTraversalDropped(1u, 0xd800u, 1u, RectFor(1u));
  ExpectMalformedTraversalDropped(1u, 0x1f600u, 1u, RectFor(1u));
  ExpectMalformedTraversalDropped(1u, u'A', 2u, RectFor(1u));
  ExpectMalformedTraversalDropped(0xffffu, u'A', 1u, RectFor(1u));
  ExpectMalformedTraversalDropped(1u, u'A', 1u, {10, 10, 0, 10});
  ExpectMalformedTraversalDropped(
      1u, u'A', 1u,
      {(std::numeric_limits<int32_t>::max)() - 2, 10, 10, 10});
}

void TestOverflowDropsWholeTraversal() {
  static_assert(bridge::kGlyphCapacity >= 512u);
  bridge::TraversalCaptureBridge capture_bridge;
  assert(capture_bridge.Reset());
  for (uint32_t index = 0u; index < bridge::kGlyphCapacity; ++index) {
    assert(Submit(&capture_bridge, index).glyph_accepted);
  }
  const bridge::SubmitOutcome overflow =
      Submit(&capture_bridge, static_cast<uint32_t>(bridge::kGlyphCapacity));
  assert(!overflow.glyph_accepted && !overflow.quarantined);

  bridge::SubmitOutcome outcome = Submit(&capture_bridge, 0u);
  assert(outcome.glyph_accepted && !outcome.snapshot_published);
  bridge::TraversalSnapshot snapshot;
  assert(!capture_bridge.ReadLatest(&snapshot));
  outcome = Submit(&capture_bridge, 0u);
  assert(outcome.snapshot_published);
  assert(capture_bridge.ReadLatest(&snapshot));
  assert(snapshot.glyph_count == 1u);
}

void TestSecondRenderThreadPermanentlyQuarantinesUntilReset() {
  bridge::TraversalCaptureBridge capture_bridge;
  assert(capture_bridge.Reset());
  assert(Submit(&capture_bridge, 0u).glyph_accepted);
  bridge::SubmitOutcome outcome = capture_bridge.SubmitGlyph(
      kRenderThread + 1u, 1u, u'B', 1u, RectFor(1u));
  assert(outcome.quarantined && !outcome.glyph_accepted);
  assert(capture_bridge.quarantined());
  assert(capture_bridge.bound_render_thread_id() == kRenderThread);
  assert(Submit(&capture_bridge, 0u).quarantined);
  bridge::TraversalSnapshot snapshot;
  assert(!capture_bridge.ReadLatest(&snapshot));

  assert(capture_bridge.Reset());
  outcome = capture_bridge.SubmitGlyph(kRenderThread + 1u, 0u, u'A', 1u,
                                       RectFor(0u));
  assert(outcome.glyph_accepted && !outcome.quarantined);
  assert(capture_bridge.bound_render_thread_id() == kRenderThread + 1u);
}

void TestConcurrentReentryQuarantinesButResetContentionOnlyRetries() {
  bridge::TraversalCaptureBridge capture_bridge;
  assert(capture_bridge.Reset());
  bridge::TraversalCaptureBridgeTestPeer::HoldCallback(&capture_bridge);
  const bridge::SubmitOutcome outcome = Submit(&capture_bridge, 0u);
  assert(outcome.quarantined && !outcome.glyph_accepted);
  assert(capture_bridge.quarantined());
  bridge::TraversalCaptureBridgeTestPeer::ReleaseCallback(&capture_bridge);
  assert(Submit(&capture_bridge, 0u).quarantined);
  assert(capture_bridge.Reset());

  bridge::TraversalCaptureBridgeTestPeer::HoldCallback(&capture_bridge);
  assert(!capture_bridge.Reset());
  assert(!capture_bridge.quarantined());
  assert(capture_bridge.quarantine_reason() ==
         bridge::CaptureQuarantineReason::kNone);
  bridge::TraversalCaptureBridgeTestPeer::ReleaseCallback(&capture_bridge);
  assert(Submit(&capture_bridge, 0u).glyph_accepted);
  assert(capture_bridge.Reset());
}

void TestWorkerNeverReadsATornSnapshot() {
  bridge::TraversalCaptureBridge capture_bridge;
  assert(capture_bridge.Reset());
  std::atomic<bool> writer_started{false};
  std::atomic<bool> writer_done{false};
  std::thread writer([&]() {
    writer_started.store(true, std::memory_order_release);
    for (uint32_t generation = 1u; generation <= 300u; ++generation) {
      const uint32_t scalar = u'A' + (generation % 26u);
      const int32_t base_x = static_cast<int32_t>(generation * 1000u);
      for (uint32_t index = 0u; index < 32u; ++index) {
        const bridge::SubmitOutcome outcome = capture_bridge.SubmitGlyph(
            kRenderThread, index, scalar, 1u,
            {base_x + static_cast<int32_t>(index),
             static_cast<int32_t>(scalar), 12, 24});
        assert(outcome.glyph_accepted && !outcome.quarantined);
      }
      std::this_thread::yield();
    }
    // Force the last complete traversal to seal.
    assert(capture_bridge
               .SubmitGlyph(kRenderThread, 0u, u'Z', 1u,
                            {999000, static_cast<int32_t>(u'Z'), 12, 24})
               .glyph_accepted);
    writer_done.store(true, std::memory_order_release);
  });

  while (!writer_started.load(std::memory_order_acquire))
    std::this_thread::yield();
  size_t stable_reads = 0u;
  do {
    bridge::TraversalSnapshot snapshot;
    if (!capture_bridge.ReadLatest(&snapshot)) {
      std::this_thread::yield();
      continue;
    }
    ++stable_reads;
    assert(snapshot.glyph_count == 32u);
    const uint32_t scalar = snapshot.glyphs[0].scalar;
    const int32_t base_x = snapshot.glyphs[0].logical_rect.x;
    for (uint32_t index = 0u; index < snapshot.glyph_count; ++index) {
      const bridge::GlyphSnapshot &glyph = snapshot.glyphs[index];
      assert(glyph.raw_utf16_index == index);
      assert(glyph.consumed_utf16_width == 1u);
      assert(glyph.scalar == scalar);
      assert(glyph.logical_rect.x == base_x + static_cast<int32_t>(index));
      assert(glyph.logical_rect.y == static_cast<int32_t>(scalar));
    }
  } while (!writer_done.load(std::memory_order_acquire));
  writer.join();

  bridge::TraversalSnapshot latest;
  assert(capture_bridge.ReadLatest(&latest));
  assert(latest.glyph_count == 32u);
  assert(stable_reads != 0u);
}

} // namespace

int main() {
  TestIncreasingTraversalSealsOnlyOnRestart();
  TestEqualIndexCreatesANewTraversalWithoutDuplicateGlyphs();
  TestInvalidScalarWidthIndexAndRectDropWholeTraversal();
  TestOverflowDropsWholeTraversal();
  TestSecondRenderThreadPermanentlyQuarantinesUntilReset();
  TestConcurrentReentryQuarantinesButResetContentionOnlyRetries();
  TestWorkerNeverReadsATornSnapshot();
  return 0;
}
