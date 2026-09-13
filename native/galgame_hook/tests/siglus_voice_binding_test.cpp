#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include "../hook/siglus_voice_binding.h"

using namespace fushi_voice_hook::siglus;
using Status = VoiceBindingStatus;
using Cache = VoiceBindingCache<2, 2, 2>;

static VoiceResourceMetadata Resource(uint32_t member = 7) {
  return {1, member, L"C:\\synthetic\\koe\\z0001.ovk",
          100 + static_cast<uint64_t>(member) * 100, 11};
}

static void TestArrivalOrderAndIndependentOccurrences() {
  Cache cache;
  VoiceBinding out;
  const auto resource = Resource();
  assert(cache.ObserveResource(resource) == Status::kAccepted);
  assert(cache.ObserveText({2, 100007, 9999}) == Status::kAccepted);
  assert(cache.GetBinding(2, &out) == Status::kReady);
  assert(out.text.event_id == 2 && out.text.text_tick == 9999);
  assert(out.resource.source_path == resource.source_path);
  assert(out.resource.source_offset == resource.source_offset);
  assert(out.resource.archive_revision == 11);
  // Identical dialogue needs no string comparison: each committed seq owns
  // its own output, even when it references the same previously read member.
  assert(cache.ObserveText({500, 100007, 1}) == Status::kAccepted);
  assert(cache.ConsumeEvent(2) == Status::kConsumed);
  assert(cache.GetBinding(500, &out) == Status::kReady);
  assert(out.text.event_id == 500 && out.text.text_tick == 1);
  assert(cache.ConsumeEvent(500) == Status::kConsumed);
  assert(cache.ObserveText({2, 100008, 9999}) == Status::kStaleEvent);
  assert(cache.GetBinding(2, &out) == Status::kStaleEvent);
  assert(out.text.event_id == 0 && out.resource.source_path.empty());

  cache.Reset();
  assert(cache.ObserveText({1, 100007, 0}) == Status::kAccepted);
  assert(cache.GetBinding(1, &out) == Status::kPending);
  // Near or equal times cannot turn another resource into a match.
  assert(cache.ObserveResource(Resource(8)) == Status::kAccepted);
  assert(cache.GetBinding(1, &out) == Status::kPending);
  assert(cache.ObserveResource(resource) == Status::kAccepted);
  assert(cache.NextBinding(&out) == Status::kReady);
  assert(out.text.event_id == 1 && out.text.text_tick == 0);
}

static void TestDuplicatesAndAmbiguity() {
  for (int conflict = 0; conflict < 3; ++conflict) {
    Cache cache;
    VoiceBinding out;
    auto resource = Resource();
    assert(cache.ObserveResource(resource) == Status::kAccepted);
    assert(cache.ObserveResource(resource) == Status::kDuplicate);
    assert(cache.ObserveText({1, 100007, 44}) == Status::kAccepted);
    assert(cache.ObserveText({1, 100007, 44}) == Status::kDuplicate);
    auto changed = resource;
    if (conflict == 0) changed.source_path = L"C:\\other\\z0001.ovk";
    if (conflict == 1) ++changed.source_offset;
    if (conflict == 2) ++changed.archive_revision;
    assert(cache.ObserveResource(changed) == Status::kAmbiguous);
    assert(cache.GetBinding(1, &out) == Status::kAmbiguous);
    assert(out.text.event_id == 0);
    assert(cache.ObserveResource(resource) == Status::kAmbiguous);
    assert(cache.DiscardEvent(1));
    assert(cache.ObserveText({2, 100008, 45}) == Status::kAccepted);
    assert(cache.ObserveResource(Resource(8)) == Status::kAmbiguous);
    assert(cache.GetBinding(2, &out) == Status::kAmbiguous);
    cache.Reset();
    assert(cache.ObserveResource(resource) == Status::kAccepted);
    assert(cache.ObserveText({1, 100007, 44}) == Status::kAccepted);
    assert(cache.GetBinding(1, &out) == Status::kReady);
  }
  for (int conflict = 0; conflict < 3; ++conflict) {
    Cache cache;
    VoiceBinding out;
    assert(cache.ObserveText({7, 100007, 12}) == Status::kAccepted);
    VoiceTextEvent changed{7, 100007, 12};
    if (conflict == 0) ++changed.voice_key;
    if (conflict == 1) ++changed.text_tick;
    if (conflict == 2) changed.voice_key = kNoVoiceKey;
    assert(cache.ObserveText(changed) == Status::kAmbiguous);
    assert(cache.ObserveText({7, 100007, 12}) == Status::kAmbiguous);
    assert(cache.GetBinding(7, &out) == Status::kAmbiguous);
    assert(cache.DiscardEvent(7));
    assert(cache.ObserveText({7, 100007, 12}) == Status::kStaleEvent);
  }
}

static void TestBoundedQueuesAndStreaming() {
  Cache cache;
  VoiceBinding out;
  assert(cache.ObserveText({1, 100001, 10}) == Status::kAccepted);
  assert(cache.ObserveText({3, 100002, 11}) == Status::kAccepted);
  assert(cache.ObserveText({9, 100003, 12}) == Status::kCapacityExceeded);
  assert(cache.ObserveResource(Resource(1)) == Status::kAccepted);
  assert(cache.ObserveResource(Resource(2)) == Status::kAccepted);
  assert(cache.ObserveResource(Resource(3)) == Status::kCapacityExceeded);
  assert(cache.ConsumeEvent(1) == Status::kConsumed);
  assert(cache.ObserveText({9, 100003, 12}) == Status::kStaleEvent);
  assert(cache.ObserveResource(Resource(3)) == Status::kAccepted);
  assert(cache.ObserveText({10, 100003, 12}) == Status::kAccepted);
  assert(cache.GetBinding(3, &out) == Status::kReady);  // Pinned member survived.
  assert(cache.ConsumeEvent(3) == Status::kConsumed);
  assert(cache.ConsumeEvent(10) == Status::kConsumed);
  for (uint32_t i = 11; i < 10011; ++i) {
    // Thousands of members/events exceed both capacities without exhausting
    // the session; old events cannot revive after their resource was evicted.
    assert(cache.ObserveText({i, 100000 + i, i}) == Status::kAccepted);
    assert(cache.ObserveResource(Resource(i)) == Status::kAccepted);
    assert(cache.GetBinding(i, &out) == Status::kReady);
    assert(out.resource.member_id == i);
    assert(cache.ConsumeEvent(i) == Status::kConsumed);
    assert(cache.ObserveText({i, 100001, i}) == Status::kStaleEvent);
  }
  // A frozen archive revision change is caught even after member eviction.
  auto changed = Resource(1);
  ++changed.archive_revision;
  assert(cache.ObserveResource(changed) == Status::kAmbiguous);
  assert(cache.ObserveText({20000, 100001, 1}) == Status::kAccepted);
  assert(cache.GetBinding(20000, &out) == Status::kAmbiguous);

  cache.Reset();
  assert(cache.ObserveResource(Resource()) == Status::kAccepted);
  auto second_archive = Resource();
  second_archive.archive_component = 2;
  second_archive.source_path = L"C:\\synthetic\\koe\\z0002.ovk";
  assert(cache.ObserveResource(second_archive) == Status::kAccepted);
  auto third_archive = second_archive;
  third_archive.archive_component = 3;
  assert(cache.ObserveResource(third_archive) == Status::kCapacityExceeded);
  assert(cache.ObserveText({1, 100007, 1}) == Status::kAccepted);
  assert(cache.GetBinding(1, &out) == Status::kReady);
}

static void TestInvalidInputsAndReset() {
  uint32_t key = 123;
  assert(ComposeVoiceKey(0, 0, &key) && key == 0);
  assert(ComposeVoiceKey(0, 0xffff, &key) && key == 0xffff);
  assert(!ComposeVoiceKey(1, 100000, &key));
  assert(!ComposeVoiceKey(UINT32_MAX, 0, &key));
  assert(!ComposeVoiceKey(42949, 67295, &key));
  assert(!ComposeVoiceKey(1, 1, nullptr));
  Cache cache;
  VoiceBinding out;
  assert(cache.ObserveText({0, 100007, 1}) == Status::kInvalid);
  assert(cache.ObserveText({1, kNoVoiceKey, 1}) == Status::kInvalid);
  assert(cache.ObserveText({1, 100007, 1}) == Status::kStaleEvent);
  for (int invalid = 0; invalid < 5; ++invalid) {
    auto resource = Resource();
    if (invalid == 0) resource.archive_revision = 0;
    if (invalid == 1) resource.source_path.clear();
    if (invalid == 2) resource.source_path.assign(kVoiceSourcePathCapacity, L'x');
    if (invalid == 3) resource.source_path.push_back(L'\0');
    if (invalid == 4) resource.member_id = 100000;
    assert(cache.ObserveResource(resource) == Status::kInvalid);
  }
  assert(cache.GetBinding(1, nullptr) == Status::kInvalid);
  assert(cache.NextBinding(nullptr) == Status::kInvalid);
  assert(!cache.DiscardEvent(0));
  cache.Reset();
  assert(cache.GetBinding(1, &out) == Status::kPending);
  assert(cache.ObserveText({1, 0, 0}) == Status::kAccepted);
  auto zero = Resource(0);
  zero.archive_component = 0;
  assert(cache.ObserveResource(zero) == Status::kAccepted);
  assert(cache.GetBinding(1, &out) == Status::kReady);
  assert(cache.ConsumeEvent(1) == Status::kConsumed);
  auto ffff = zero;
  ffff.member_id = 0xffff;
  assert(cache.ObserveResource(ffff) == Status::kAccepted);
  assert(cache.ObserveText({2, 0xffff, 0}) == Status::kAccepted);
  assert(cache.GetBinding(2, &out) == Status::kReady);
  cache.Reset();
  assert(cache.ObserveText({1, 0xffff, 0}) == Status::kAccepted);
  assert(cache.GetBinding(1, &out) == Status::kPending);  // No old session member.
}

int main() {
  TestArrivalOrderAndIndependentOccurrences();
  TestDuplicatesAndAmbiguity();
  TestBoundedQueuesAndStreaming();
  TestInvalidInputsAndReset();
}
