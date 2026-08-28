#pragma once

#include <cstddef>
#include <cstdint>

namespace fushi_voice_hook {

// Fixed, numeric-only telemetry for the exact WHITE ALBUM2 D3D9 profile.
// It deliberately contains no text, texture bytes, or other game payloads.
// The x64 ring probe resolves this export from the live x86 hook DLL and reads
// it with ReadProcessMemory, so every field has an explicit cross-arch width.
inline constexpr char kLeafD3DTraceExportName[] = "FushiLeafD3DTraceV1";
inline constexpr uint32_t kLeafD3DTraceMagic = 0x3344464cu; // "LFD3"
inline constexpr uint32_t kLeafD3DTraceVersion = 1u;
inline constexpr uint32_t kLeafD3DTraceCapacity = 2048u;

struct alignas(8) LeafD3DTraceEvent {
  uint64_t sequence = 0;
  uint64_t timestamp_ms = 0;
  uint64_t frame_sequence = 0;
  uint64_t traversal_id = 0;
  uint64_t texture0 = 0;
  uint32_t caller_rva = 0;
  uint32_t primitive_type = 0;
  uint32_t primitive_count = 0;
  uint32_t vertex_stride = 0;
  uint32_t fvf = 0;
  uint32_t vertex_count = 0;
  uint32_t glyph_index = 0;
  uint32_t glyph_count = 0;
  // Kept for v1 layout compatibility. Always zero: matching text is private.
  uint32_t match_reserved = 0;
  uint32_t reserved = 0;
  float left = 0.0f;
  float top = 0.0f;
  float right = 0.0f;
  float bottom = 0.0f;
};

struct alignas(8) LeafD3DTraceSlot {
  int32_t writing = 0;
  uint32_t reserved = 0;
  LeafD3DTraceEvent event = {};
};

struct alignas(8) LeafD3DTraceBuffer {
  uint32_t magic = kLeafD3DTraceMagic;
  uint32_t version = kLeafD3DTraceVersion;
  uint32_t event_size = sizeof(LeafD3DTraceEvent);
  uint32_t slot_size = sizeof(LeafD3DTraceSlot);
  uint32_t capacity = kLeafD3DTraceCapacity;
  uint32_t reserved = 0;
  int64_t next_sequence = 0;
  int64_t dropped_busy = 0;
  int64_t glyph_calls = 0;
  int64_t glyph_describe_failures = 0;
  int64_t glyph_armed_calls = 0;
  int64_t armed_draw_calls = 0;
  int64_t quad_candidates = 0;
  int64_t primary_quad_candidates = 0;
  int64_t alternate_quad_candidates = 0;
  int64_t caller_rejects = 0;
  int64_t primitive_type_rejects = 0;
  int64_t primitive_count_rejects = 0;
  int64_t vertex_stride_rejects = 0;
  int64_t bounds_rejects = 0;
  uint32_t last_primitive_type = 0;
  uint32_t last_primitive_count = 0;
  uint32_t last_vertex_stride = 0;
  uint32_t last_caller_rva = 0;
  uint32_t input_poller_owner_tid = 0;
  uint32_t input_poller_conflicts = 0;
  uint32_t input_poller_last_conflict_tid = 0;
  // Whether a non-owner thread entered the admitted poller range since the
  // previous worker tick, i.e. contention *right now* rather than "ever".
  // Lookup is suppressed exactly while this is 1, so it is the field that
  // explains a "clicking does nothing" report for this profile. It replaces a
  // v1 reserved word at the same offset; the exported layout is unchanged.
  uint32_t input_poller_contended = 0;
  LeafD3DTraceSlot slots[kLeafD3DTraceCapacity] = {};
};

static_assert(sizeof(LeafD3DTraceEvent) == 96,
              "Leaf D3D trace event ABI drifted");
static_assert(sizeof(LeafD3DTraceSlot) == 104,
              "Leaf D3D trace slot ABI drifted");
static_assert(offsetof(LeafD3DTraceBuffer, slots) == 168,
              "Leaf D3D trace header ABI drifted");

} // namespace fushi_voice_hook
