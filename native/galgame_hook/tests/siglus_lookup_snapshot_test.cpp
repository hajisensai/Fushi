#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../hook/adapters/siglus_lookup.h"
#include <Windows.h>
#include <cassert>
#include <cstring>
#include <string>

namespace {
using fushi_voice_hook::SiglusLookupTextSnapshot;
constexpr size_t kSiglusLookupMaxTextUnits =
    fushi_voice_hook::kSiglusLookupTextCapacity;
constexpr size_t kSiglusLookupTextSlots = 4;
volatile LONG64 g_siglus_lookup_text_count = 0;
uint64_t g_siglus_lookup_text_processed_seq = 0;
SiglusLookupTextSnapshot g_siglus_lookup_text_snapshots[kSiglusLookupTextSlots];

// Execute the production publisher and seqlock reader, not a copied model.
#include "../hook/adapters/siglus_lookup_text_snapshot.inc"

void Consume(SiglusLookupTextSnapshot *snapshot) {
  uint64_t seq = 0;
  assert(ReadLatestSiglusLookupText(snapshot, &seq));
  g_siglus_lookup_text_processed_seq = seq;
}
} // namespace

int main() {
  SiglusLookupTextSnapshot snapshot;
  PublishSiglusLookupTextSnapshot(L"ABC", 3, {1, 5});
  Consume(&snapshot);
  assert(snapshot.identity.event_id == 1 && snapshot.text_units == 3);
  // A real new event with an unsupported body must reach the consumer as an
  // invalidation. Previously publication silently returned and event 1 lived
  // on.
  const std::wstring long_text(kSiglusLookupMaxTextUnits + 1, L'X');
  PublishSiglusLookupTextSnapshot(
      long_text.data(), static_cast<uint32_t>(long_text.size()), {2, 5});
  Consume(&snapshot);
  assert(snapshot.identity.event_id == 2 && snapshot.identity.thread_id == 5);
  assert(snapshot.text_units == 0);

  // Several unsupported occurrences still advance identity; none is truncated.
  const std::wstring maximum_native_text(1500, L'Z');
  PublishSiglusLookupTextSnapshot(maximum_native_text.data(), 1500, {3, 5});
  Consume(&snapshot);
  assert(snapshot.identity.event_id == 3 && snapshot.text_units == 0);

  // Empty/invalid callbacks alone do not prove a new message occurrence.
  const uint64_t before = g_siglus_lookup_text_processed_seq;
  PublishSiglusLookupTextSnapshot(nullptr, 20, {4, 5});
  PublishSiglusLookupTextSnapshot(L"", 0, {5, 5});
  uint64_t seq = 0;
  assert(!ReadLatestSiglusLookupText(&snapshot, &seq));
  assert(g_siglus_lookup_text_count == static_cast<LONG64>(before));

  // The next supported event can recover, even when its text equals event 1.
  PublishSiglusLookupTextSnapshot(L"ABC", 3, {6, 5});
  Consume(&snapshot);
  assert(snapshot.identity.event_id == 6 && snapshot.text_units == 3);
  assert(std::memcmp(snapshot.text, L"ABC", 3 * sizeof(wchar_t)) == 0);
  const std::wstring at_limit(kSiglusLookupMaxTextUnits, L'Y');
  PublishSiglusLookupTextSnapshot(
      at_limit.data(), static_cast<uint32_t>(at_limit.size()), {7, 5});
  Consume(&snapshot);
  assert(snapshot.identity.event_id == 7 &&
         snapshot.text_units == kSiglusLookupMaxTextUnits);
  return 0;
}
