#pragma once
#include <windows.h>
#include <cstdint>
#include <limits>

namespace fushi_voice_hook {
inline constexpr wchar_t kLookupWheelSourceRequiredProperty[] =
    L"Fushi.LookupWheelSource.Required.v1";
inline constexpr uint32_t kLookupWheelSourceMagic = 0x314c4857u;

// Separate, fixed-width mapping: the existing voice/lookup ABI is unchanged.
// One LL-hook thread writes outside_total. UI only controls ready; consumer
// only acknowledges. The game process creation time is part of the map name.
struct alignas(8) LookupWheelSource {
  uint32_t magic = kLookupWheelSourceMagic;
  uint32_t game_pid = 0;
  uint32_t host_pid = 0;
  uint32_t ready = 0;
  uint32_t sequence = 0;
  uint32_t consumer_ready = 0;
  uint64_t generation = 0;
  uint64_t outside_total = 0;
  uint64_t consumer_generation = 0;
};
static_assert(sizeof(LookupWheelSource) == 48);
inline uint32_t LoadWheelWord(const uint32_t* word) {
  return static_cast<uint32_t>(InterlockedCompareExchange(
      reinterpret_cast<volatile LONG*>(const_cast<uint32_t*>(word)), 0, 0));
}
inline void StoreWheelWord(uint32_t* word, uint32_t value) {
  InterlockedExchange(reinterpret_cast<volatile LONG*>(word), value);
}
inline uint64_t LoadWheelTotal(const uint64_t* word) {
  return static_cast<uint64_t>(InterlockedCompareExchange64(
      reinterpret_cast<volatile LONG64*>(const_cast<uint64_t*>(word)), 0, 0));
}
inline void StoreWheelTotal(uint64_t* word, uint64_t value) {
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(word),
                        static_cast<LONG64>(value));
}
inline void PublishOutsideWheel(LookupWheelSource* source, int32_t delta) {
  InterlockedIncrement(reinterpret_cast<volatile LONG*>(&source->sequence));
  const uint64_t next = LoadWheelTotal(&source->outside_total) +
                        static_cast<uint64_t>(static_cast<int64_t>(delta));
  InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&source->outside_total),
                        static_cast<LONG64>(next));
  InterlockedIncrement(reinterpret_cast<volatile LONG*>(&source->sequence));
}
struct LookupWheelSnapshot {
  bool coherent = false;
  bool ready = false;
  uint64_t generation = 0;
  uint64_t total = 0;
};
inline LookupWheelSnapshot ReadWheelSource(const LookupWheelSource* source) {
  LookupWheelSnapshot out;
  if (!source) return out;
  const uint32_t before = LoadWheelWord(&source->sequence);
  if ((before & 1u) != 0) return out;
  out.generation = LoadWheelTotal(&source->generation);
  out.total = LoadWheelTotal(&source->outside_total);
  const uint32_t ready = LoadWheelWord(&source->ready);
  if (ready == 2) return {}; // HHOOK reinstallation: neutral until resumed.
  out.ready = ready == 1;
  out.coherent = before == LoadWheelWord(&source->sequence);
  return out;
}
struct LookupWheelCursor {
  uint64_t generation = 0;
  uint64_t total = 0;
  bool bound = false;
};
inline int32_t ConsumeOutsideWheel(LookupWheelSnapshot source, int32_t raw,
                                  LookupWheelCursor* cursor) {
  if (!cursor) return 0;
  if (!source.coherent) return 0;
  if (!source.ready) {
    // A neutral DI read is not a delivery barrier for an earlier LL event.
    // Once admitted, do not release raw pending host input on producer loss.
    return 0;
  }
  if (!cursor->bound || cursor->generation != source.generation) {
    *cursor = {source.generation, source.total, true};
    return 0;  // Establish baseline; never replay pre-bind inputs.
  }
  const int64_t delta = static_cast<int64_t>(source.total - cursor->total);
  cursor->total = source.total;
  if (delta < std::numeric_limits<int32_t>::min() ||
      delta > std::numeric_limits<int32_t>::max()) return 0;
  return static_cast<int32_t>(delta);
}
inline bool WheelSourceName(DWORD pid, HANDLE process, wchar_t* name,
                            size_t capacity) {
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) return false;
  const uint64_t stamp = (static_cast<uint64_t>(created.dwHighDateTime) << 32) |
                         created.dwLowDateTime;
  return swprintf_s(name, capacity, L"Local\\FushiLookupWheel_%lu_%016llx",
                    static_cast<unsigned long>(pid),
                    static_cast<unsigned long long>(stamp)) > 0;
}
}  // namespace fushi_voice_hook
