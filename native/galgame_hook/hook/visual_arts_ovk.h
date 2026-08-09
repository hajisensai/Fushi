#pragma once

#include "siglus_ovk.h"

// RealLive and Siglus are kept as separate engine profiles. They share only the strictly validated
// OVK container reader; this alias does not claim that every RealLive title uses the same format.
namespace fushi_voice_hook::visual_arts {

using OvkEntry = fushi_voice_hook::siglus::OvkEntry;
constexpr uint32_t kOvkEntryBytes = fushi_voice_hook::siglus::kOvkEntryBytes;
constexpr uint32_t kMaxEntryBytes = fushi_voice_hook::siglus::kMaxEntryBytes;
constexpr uint32_t kMaxEntryCount = fushi_voice_hook::siglus::kMaxEntryCount;

inline bool FindEntryAtOffset(const uint8_t* index, size_t index_bytes,
                              uint64_t file_bytes, uint64_t wanted_offset,
                              OvkEntry* out) {
  return fushi_voice_hook::siglus::FindEntryAtOffset(
      index, index_bytes, file_bytes, wanted_offset, out);
}

inline uint32_t CompleteOggBytes(const uint8_t* data, uint32_t bytes) {
  return fushi_voice_hook::siglus::CompleteOggBytes(data, bytes);
}

}  // namespace fushi_voice_hook::visual_arts
