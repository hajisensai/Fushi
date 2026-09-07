#ifndef RUNNER_LOOKUP_GEOMETRY_SNAPSHOT_H_
#define RUNNER_LOOKUP_GEOMETRY_SNAPSHOT_H_

#include <cstdint>

namespace fushi::lookup_geometry_snapshot {

struct Identity {
  uint32_t provider_kind = 0;
  uint32_t provider_id = 0;
  uint32_t provider_status = 0;
  uint64_t generation = 0;
  uint64_t text_generation = 0;
};

inline bool SameIdentity(const Identity& left, const Identity& right) {
  return left.provider_kind == right.provider_kind &&
         left.provider_id == right.provider_id &&
         left.provider_status == right.provider_status &&
         left.generation == right.generation &&
         left.text_generation == right.text_generation;
}

// A failed sample contains no provider decision. In particular it must not be
// confused with a coherent all-zero identity (the registry has no owner).
// read() supplies an ordered atomic snapshot; it may be called at most 8 times.
template <typename Read>
bool TryRead(Read read, Identity* out) {
  if (out == nullptr) return false;
  for (int attempt = 0; attempt < 4; ++attempt) {
    const Identity before = read();
    const Identity after = read();
    if (SameIdentity(before, after)) {
      *out = after;
      return true;
    }
  }
  return false;
}

}  // namespace fushi::lookup_geometry_snapshot

#endif  // RUNNER_LOOKUP_GEOMETRY_SNAPSHOT_H_
