#include "generic_input_shield.h"

#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>

#ifndef FUSHI_NATIVE_SOURCE_DIR
#error FUSHI_NATIVE_SOURCE_DIR must identify the native galgame hook tree
#endif

namespace {

struct BufferedEvent {
  uint32_t dwOfs = 0;
  uint32_t dwData = 0;
  uint32_t timestamp = 0;
};

void TestAsyncKeyStateOwnsCompleteTail() {
  fushi_voice_hook::LeftButtonShieldLatch latch;
  int16_t state = static_cast<int16_t>(0x8001u);
  auto filtered = fushi_voice_hook::FilterSampledLeftButtonState(
      true, true, &state, &latch);
  assert(filtered.supported && filtered.changed && filtered.pending);
  assert(state == 0);

  // Popup/request has gone, but the physical hold must remain hidden.
  state = static_cast<int16_t>(0x8000u);
  filtered = fushi_voice_hook::FilterSampledLeftButtonState(false, true, &state,
                                                            &latch);
  assert(state == 0 && filtered.pending);

  // First neutral sample is the hidden release, the second is its tail.
  state = 0;
  filtered = fushi_voice_hook::FilterSampledLeftButtonState(false, true, &state,
                                                            &latch);
  assert(filtered.pending);
  state = 0;
  filtered = fushi_voice_hook::FilterSampledLeftButtonState(false, true, &state,
                                                            &latch);
  assert(!filtered.pending);
}

void TestSampledStateLeavesUnownedInputAlone() {
  fushi_voice_hook::LeftButtonShieldLatch latch;
  int16_t state = static_cast<int16_t>(0x8001u);
  const auto filtered = fushi_voice_hook::FilterSampledLeftButtonState(
      false, true, &state, &latch);
  assert(filtered.supported && !filtered.changed && !filtered.pending);
  assert(static_cast<uint16_t>(state) == 0x8001u);
}

void TestKeyboardStateOnlyClearsLeftButton() {
  std::array<uint8_t, 256> keys{};
  keys[1] = 0x81u;
  keys[2] = 0x82u;
  keys[0x10] = 0x80u;
  fushi_voice_hook::LeftButtonShieldLatch latch;
  auto filtered = fushi_voice_hook::FilterKeyboardStateLeftButton(
      true, keys.data(), keys.size(), &latch);
  assert(filtered.supported && filtered.changed && filtered.pending);
  assert(keys[1] == 0x01u);
  assert(keys[2] == 0x82u);
  assert(keys[0x10] == 0x80u);

  std::array<uint8_t, 255> truncated{};
  filtered = fushi_voice_hook::FilterKeyboardStateLeftButton(
      true, truncated.data(), truncated.size(), &latch);
  assert(!filtered.supported);
}

void TestDirectInputImmediateLayoutsAndIsolation() {
  for (const size_t size : {size_t{16}, size_t{20}}) {
    std::array<uint8_t, 20> state{};
    for (size_t i = 0; i < state.size(); ++i) {
      state[i] = static_cast<uint8_t>(i + 1);
    }
    state[12] = 0x80u;
    const auto original = state;
    fushi_voice_hook::LeftButtonShieldLatch latch;
    auto filtered = fushi_voice_hook::FilterDirectInputImmediateLeftButton(
        true, state.data(), size, &latch);
    assert(filtered.supported && filtered.changed && filtered.pending);
    assert(state[12] == 0);
    for (size_t i = 0; i < size; ++i) {
      if (i != 12)
        assert(state[i] == original[i]);
    }
  }

  std::array<uint8_t, 24> custom{};
  custom[12] = 0x80u;
  fushi_voice_hook::LeftButtonShieldLatch latch;
  const auto filtered = fushi_voice_hook::FilterDirectInputImmediateLeftButton(
      true, custom.data(), custom.size(), &latch);
  assert(!filtered.supported && custom[12] == 0x80u);
}

void TestRawInputPreservesMovementWheelAndOtherButtons() {
  fushi_voice_hook::LeftButtonShieldLatch latch;
  uint16_t flags = static_cast<uint16_t>(
      fushi_voice_hook::kRawMouseLeftButtonDown | 0x0004u | 0x0400u);
  auto filtered =
      fushi_voice_hook::FilterRawInputLeftButtonFlags(true, &flags, &latch);
  assert(filtered.changed && filtered.pending);
  assert(flags == static_cast<uint16_t>(0x0004u | 0x0400u));

  flags =
      static_cast<uint16_t>(fushi_voice_hook::kRawMouseLeftButtonUp | 0x0008u);
  filtered =
      fushi_voice_hook::FilterRawInputLeftButtonFlags(false, &flags, &latch);
  assert(filtered.changed && filtered.pending && flags == 0x0008u);
  flags = 0;
  filtered =
      fushi_voice_hook::FilterRawInputLeftButtonFlags(false, &flags, &latch);
  assert(!filtered.pending);
}

void TestBufferedDirectInputCompactsStably() {
  constexpr uint32_t kButton0 = 12;
  std::array<BufferedEvent, 5> events{{
      {0, 3, 10},
      {kButton0, 0x80u, 11},
      {4, 7, 12},
      {kButton0, 0u, 13},
      {8, 9, 14},
  }};
  size_t count = events.size();
  fushi_voice_hook::LeftButtonShieldLatch latch;
  auto filtered = fushi_voice_hook::FilterDirectInputBufferedLeftButton(
      true, events.data(), &count, kButton0, &latch);
  assert(filtered.supported && filtered.changed && filtered.pending);
  assert(count == 3);
  assert(events[0].timestamp == 10);
  assert(events[1].timestamp == 12);
  assert(events[2].timestamp == 14);

  // A zero-event poll after the request is released drains the buffered tail.
  count = 0;
  filtered = fushi_voice_hook::FilterDirectInputBufferedLeftButton(
      false, events.data(), &count, kButton0, &latch);
  assert(!filtered.pending);
}

void TestFastClickPreArmHidesQueuedSignalsAfterReleasePublication() {
  // The host's physical down+up both happened before the injected game thread
  // first polled. Down acknowledgement pre-arms each ready surface; by the
  // time these reducers run, the shared request is already the release
  // (request_active=false), yet no queued signal may escape.
  fushi_voice_hook::LeftButtonShieldLatch sampled;
  fushi_voice_hook::PreArmLeftButtonShieldLatch(&sampled);
  int16_t key_state = 0;
  auto sampled_result = fushi_voice_hook::FilterSampledLeftButtonState(
      false, true, &key_state, &sampled);
  assert(sampled_result.pending && key_state == 0);
  sampled_result = fushi_voice_hook::FilterSampledLeftButtonState(
      false, true, &key_state, &sampled);
  assert(!sampled_result.pending && key_state == 0);

  fushi_voice_hook::LeftButtonShieldLatch immediate;
  fushi_voice_hook::PreArmLeftButtonShieldLatch(&immediate);
  std::array<uint8_t, 16> mouse_state{};
  auto immediate_result =
      fushi_voice_hook::FilterDirectInputImmediateLeftButton(
          false, mouse_state.data(), mouse_state.size(), &immediate);
  assert(immediate_result.pending && mouse_state[12] == 0);
  immediate_result = fushi_voice_hook::FilterDirectInputImmediateLeftButton(
      false, mouse_state.data(), mouse_state.size(), &immediate);
  assert(!immediate_result.pending && mouse_state[12] == 0);

  fushi_voice_hook::LeftButtonShieldLatch buffered;
  fushi_voice_hook::PreArmLeftButtonShieldLatch(&buffered);
  std::array<BufferedEvent, 2> queued{{
      {12, 0x80u, 1},
      {12, 0u, 2},
  }};
  size_t queued_count = queued.size();
  auto buffered_result = fushi_voice_hook::FilterDirectInputBufferedLeftButton(
      false, queued.data(), &queued_count, 12, &buffered);
  assert(buffered_result.changed && buffered_result.pending &&
         queued_count == 0);
  buffered_result = fushi_voice_hook::FilterDirectInputBufferedLeftButton(
      false, queued.data(), &queued_count, 12, &buffered);
  assert(!buffered_result.pending && queued_count == 0);

  fushi_voice_hook::LeftButtonShieldLatch raw;
  fushi_voice_hook::PreArmLeftButtonShieldLatch(&raw);
  uint16_t raw_flags = fushi_voice_hook::kRawMouseLeftButtonDown;
  auto raw_result =
      fushi_voice_hook::FilterRawInputLeftButtonFlags(false, &raw_flags, &raw);
  assert(raw_result.changed && raw_result.pending && raw_flags == 0);
  raw_flags = fushi_voice_hook::kRawMouseLeftButtonUp;
  raw_result =
      fushi_voice_hook::FilterRawInputLeftButtonFlags(false, &raw_flags, &raw);
  assert(raw_result.changed && raw_result.pending && raw_flags == 0);
  raw_flags = 0;
  raw_result =
      fushi_voice_hook::FilterRawInputLeftButtonFlags(false, &raw_flags, &raw);
  assert(!raw_result.pending && raw_flags == 0);
}

void TestPreArmEligibilityExcludesNeverObservedAlternatives() {
  constexpr uint32_t kKey = 0x1u;
  constexpr uint32_t kRawData = 0x2u;
  constexpr uint32_t kRawBuffer = 0x4u;
  const uint32_t eligible = fushi_voice_hook::PreArmEligibleShieldMask(
      kKey | kRawData | kRawBuffer, kKey | kRawData | kRawBuffer,
      kKey | kRawBuffer);
  assert(eligible == (kKey | kRawBuffer));
}

void TestObservationOnlyKeyDetourIsKnownUncovered() {
  constexpr uint32_t kAllKeyExports = 0x7u;
  constexpr uint32_t kKeySurface = 0x4u;
  assert(!fushi_voice_hook::IsCompleteGenericKeyStateCoverage(
      kAllKeyExports, kAllKeyExports, true));
  assert(fushi_voice_hook::IsCompleteGenericKeyStateCoverage(
      kAllKeyExports, kAllKeyExports, false));
  assert(fushi_voice_hook::ClassifyGenericShieldCoverage(0u, kKeySurface,
                                                         kKeySurface) ==
         fushi_voice_hook::GenericShieldCoverageConclusion::kKnownUncovered);
}

void TestDestroyedTargetFaultDoesNotPolluteReplacementWindow() {
  constexpr uint32_t kPersistentHookFault = 0x02u;
  constexpr uint32_t kRequiredForOldTarget = 0x1du;
  const uint32_t old_target_fault =
      fushi_voice_hook::TargetScopedGenericShieldFaultMask(
          kPersistentHookFault, kRequiredForOldTarget, false);
  assert(old_target_fault == (kPersistentHookFault | kRequiredForOldTarget));

  // Reusing the same injected process for a new same-PID HWND starts from
  // actual persistent hook failures only; the old HWND validity fault is not
  // global state and cannot survive into the new request.
  const uint32_t replacement_fault =
      fushi_voice_hook::TargetScopedGenericShieldFaultMask(
          kPersistentHookFault, kRequiredForOldTarget, true);
  assert(replacement_fault == kPersistentHookFault);
  assert(fushi_voice_hook::TargetScopedGenericShieldFaultMask(
             0u, kRequiredForOldTarget, true) == 0u);
}

void TestWriterHeldGenericRequestCannotBeReportedVerified() {
  // The request seqlock deliberately makes a writer-held payload unreadable.
  // Public-API coverage is a risk-mode fallback, so its coordinator must never
  // turn that fail-open interval into a Verified claim.
  std::ifstream input(std::string(FUSHI_NATIVE_SOURCE_DIR) +
                      "/hook/generic_input_shield.inc");
  assert(input.good());
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
  const size_t begin = source.find("void ProcessGenericLookupInputShield()");
  const size_t end = source.find("void ShutdownGenericLookupInputShield()",
                                 begin);
  assert(begin != std::string::npos && end != std::string::npos && end > begin);
  const std::string coordinator = source.substr(begin, end - begin);
  assert(coordinator.find("kLookupShieldStatusVerified") == std::string::npos);
  assert(coordinator.find("kLookupShieldStatusPartial") != std::string::npos);

  assert(fushi_voice_hook::ClassifyGenericShieldCoverage(0u, 0u, 0x7fu) ==
         fushi_voice_hook::GenericShieldCoverageConclusion::kPartial);
}

} // namespace

int main() {
  TestAsyncKeyStateOwnsCompleteTail();
  TestSampledStateLeavesUnownedInputAlone();
  TestKeyboardStateOnlyClearsLeftButton();
  TestDirectInputImmediateLayoutsAndIsolation();
  TestRawInputPreservesMovementWheelAndOtherButtons();
  TestBufferedDirectInputCompactsStably();
  TestFastClickPreArmHidesQueuedSignalsAfterReleasePublication();
  TestPreArmEligibilityExcludesNeverObservedAlternatives();
  TestObservationOnlyKeyDetourIsKnownUncovered();
  TestDestroyedTargetFaultDoesNotPolluteReplacementWindow();
  TestWriterHeldGenericRequestCannotBeReportedVerified();
  return 0;
}
