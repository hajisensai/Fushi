#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <tuple>

namespace fushi_voice_hook::siglus_eightarg_runtime {

using Read = bool (*)(void*, uint32_t, void*, size_t);

struct Snapshot {
  // Necessary engine input predicates only; glyph membership and current
  // dialogue occurrence must be established independently by the caller.
  bool input_allowed = false;
  uint32_t root = 0, config = 0, owner = 0;
  uint32_t window = 0, input = 0, current_input = 0, prior_input = 0;
  uint32_t viewport_state = 0, gate2 = 0, gate3 = 0, manager = 0, scene = 0;
  uint32_t window_vtable = 0, window_handle = 0;
  int32_t design_width = 0, design_height = 0;
  int32_t viewport_x = 0, viewport_y = 0;
  int32_t viewport_width = 0, viewport_height = 0;
  std::array<uint8_t, 3> blocked{};
};

inline bool Add(uintptr_t base, uintptr_t offset, uint32_t* out) {
  constexpr auto maximum = std::numeric_limits<uint32_t>::max();
  if (!out || base == 0 || base > maximum || offset > maximum - base)
    return false;
  *out = static_cast<uint32_t>(base + offset);
  return true;
}

template <typename T>
inline bool Scalar(Read read, void* context, uintptr_t base, uintptr_t offset,
                   T* out) {
  static_assert(sizeof(T) == 1 || sizeof(T) == 4);
  uint32_t address = 0;
  return read && out && Add(base, offset, &address) &&
      address <= std::numeric_limits<uint32_t>::max() - (sizeof(T) - 1) &&
      (sizeof(T) == 1 || (address & 3u) == 0) &&
      read(context, address, out, sizeof(T));
}

inline bool Alias(uint32_t base, uint32_t offset, uint32_t actual) {
  uint32_t expected = 0;
  return Add(base, offset, &expected) && expected == actual;
}

// Sites is the independently admitted eight-argument input/viewport Sites.
// No title, digest or measured RVA is accepted in place of its structural proof.
template <typename Sites>
inline bool ReadOnce(uintptr_t base, const Sites& sites, Read read,
                     void* context, Snapshot* out) {
  Snapshot s;
  const std::array<uintptr_t, 12> slots = {sites.root_slot, sites.config_slot,
      sites.owner_slot, sites.window_slot, sites.input_slot,
      sites.current_input_slot, sites.prior_input_slot, sites.viewport_slot,
      sites.gate2_slot, sites.gate3_slot, sites.manager_slot, sites.scene_slot};
  const std::array<uint32_t*, 12> pointers = {&s.root, &s.config, &s.owner,
      &s.window, &s.input, &s.current_input, &s.prior_input, &s.viewport_state,
      &s.gate2, &s.gate3, &s.manager, &s.scene};
  for (size_t i = 0; i < slots.size(); ++i) {
    if (slots[i] == 0 || !Scalar(read, context, base, slots[i], pointers[i]) ||
        *pointers[i] < 0x10000u || (*pointers[i] & 3u) != 0) return false;
  }
  if (!Alias(s.root, 0x54, s.config) ||
      !Alias(s.root, 0xa476b0, s.owner) ||
      !Alias(s.owner, 0x178, s.window) ||
      !Alias(s.owner, 0x35ad4, s.input) ||
      !Alias(s.owner, 0x3939c, s.current_input) ||
      !Alias(s.owner, 0x3b000, s.prior_input) ||
      !Alias(s.owner, 0x3cca0, s.viewport_state) ||
      !Alias(s.owner, 0x3d124, s.gate2) ||
      !Alias(s.owner, 0x4296c, s.gate3) ||
      !Alias(s.owner, 0x3d174, s.manager) ||
      !Alias(s.owner, 0x42898, s.scene)) return false;
  uint32_t expected_vtable = 0, handler = 0, expected_handler = 0;
  if (sites.window_vtable == 0 || sites.window_handler == 0 ||
      !Add(base, sites.window_vtable, &expected_vtable) ||
      !Add(base, sites.window_handler, &expected_handler) ||
      !Scalar(read, context, s.window, 0, &s.window_vtable) ||
      s.window_vtable != expected_vtable ||
      !Scalar(read, context, s.window_vtable, 4, &handler) ||
      handler != expected_handler ||
      !Scalar(read, context, s.window, 4, &s.window_handle) ||
      s.window_handle == 0) return false;
  int32_t owner_width = 0, owner_height = 0;
  if (!Scalar(read, context, s.config, 0x64, &s.design_width) ||
      !Scalar(read, context, s.config, 0x68, &s.design_height) ||
      !Scalar(read, context, s.owner, 0x3cca8, &owner_width) ||
      !Scalar(read, context, s.owner, 0x3ccac, &owner_height) ||
      s.design_width < 256 || s.design_width > 16384 ||
      s.design_height < 256 || s.design_height > 16384 ||
      owner_width != s.design_width || owner_height != s.design_height ||
      !Scalar(read, context, s.owner, 0x3ccb0, &s.viewport_x) ||
      !Scalar(read, context, s.owner, 0x3ccb4, &s.viewport_y) ||
      !Scalar(read, context, s.owner, 0x3ccc0, &s.viewport_width) ||
      !Scalar(read, context, s.owner, 0x3ccc4, &s.viewport_height) ||
      s.viewport_width <= 0 || s.viewport_height <= 0 ||
      static_cast<int64_t>(s.viewport_x) + s.viewport_width > INT32_MAX ||
      static_cast<int64_t>(s.viewport_y) + s.viewport_height > INT32_MAX ||
      !Scalar(read, context, s.viewport_state, 0xb4, &s.blocked[0]) ||
      !Scalar(read, context, s.gate2, 2, &s.blocked[1]) ||
      !Scalar(read, context, s.gate3, 0x138, &s.blocked[2])) return false;
  s.input_allowed = s.blocked == std::array<uint8_t, 3>{};
  *out = s;
  return true;
}

inline auto Identity(const Snapshot& s) {
  return std::tie(s.root, s.config, s.owner, s.window, s.input, s.current_input,
      s.prior_input, s.viewport_state, s.gate2, s.gate3, s.manager, s.scene,
      s.window_vtable, s.window_handle, s.design_width, s.design_height,
      s.viewport_x, s.viewport_y, s.viewport_width, s.viewport_height, s.blocked);
}

// Two bounded reads reject observed drift without retrying. This is not an
// engine atomic transaction: ABA between reads remains possible. Revalidate
// on publication/input, including actual HWND ownership and glyph occurrence.
template <typename Sites>
inline bool ReadSnapshot(uintptr_t base, const Sites& sites, Read read,
                         void* context, Snapshot* out) {
  if (!out) return false;
  *out = {};
  if (!read || base == 0 || base > UINT32_MAX || (base & 3u) != 0) return false;
  Snapshot first, second;
  if (!ReadOnce(base, sites, read, context, &first) ||
      !ReadOnce(base, sites, read, context, &second) ||
      Identity(first) != Identity(second)) return false;
  *out = second;
  return true;
}

}  // namespace fushi_voice_hook::siglus_eightarg_runtime
