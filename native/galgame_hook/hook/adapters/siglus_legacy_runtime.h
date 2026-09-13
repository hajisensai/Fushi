#pragma once

#include <array>
#include <limits>
#include <tuple>

#include "siglus_legacy_input_viewport.h"

namespace fushi_voice_hook::siglus_legacy_runtime {
namespace sites = siglus_legacy_input_viewport;

// The callback must copy exactly bytes readable bytes or return false, without
// throwing. Production supplies its bounded/SEH-protected in-process reader.
using Read = bool (*)(void* context, uint32_t address, void* output,
                      size_t bytes);

struct Viewport {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

struct Snapshot {
  bool structure_valid = false;
  // Necessary input gates only: IME/script predicates and the independently
  // admitted glyph/text occurrence are not proved by this snapshot.
  bool dialogue_input_allowed = false;
  uint32_t config = 0;
  uint32_t owner = 0;
  uint32_t window = 0;
  uint32_t input = 0;
  uint32_t modal = 0;
  uint32_t hidden = 0;
  uint32_t auxiliary = 0;
  uint32_t window_vtable = 0;
  // window+4 is passed to the engine's named ScreenToClient import. This is
  // an opaque x86 HWND value, not a pointer to dereference; caller checks
  // IsWindow, target process ownership and the current client rectangle.
  uint32_t window_handle = 0;
  int32_t design_width = 0;
  int32_t design_height = 0;
  Viewport viewport{};
  // Modal, hidden dialogue, log, auxiliary. Preserve raw bytes so any state
  // change between the two reads rejects the mixed snapshot.
  std::array<uint8_t, 4> blocked_flags{};
};

inline bool Add(uintptr_t base, uintptr_t offset, uint32_t* output) {
  constexpr auto maximum = std::numeric_limits<uint32_t>::max();
  if (base == 0 || base > maximum || offset > maximum - base) return false;
  *output = static_cast<uint32_t>(base + offset);
  return true;
}

template <typename T>
inline bool Scalar(Read read, void* context, uintptr_t base, uintptr_t offset,
                   T* output) {
  static_assert(sizeof(T) == 1 || sizeof(T) == 4);
  uint32_t address = 0;
  if (!Add(base, offset, &address) ||
      address > std::numeric_limits<uint32_t>::max() - (sizeof(T) - 1) ||
      (sizeof(T) == 4 && (address & 3u) != 0))
    return false;
  return read(context, address, output, sizeof(T));
}

inline bool Pointer(Read read, void* context, uintptr_t base, uintptr_t offset,
                    uint32_t* output) {
  return offset != 0 && Scalar(read, context, base, offset, output) &&
         *output != 0 && (*output & 3u) == 0;
}

inline bool Alias(uint32_t base, uint32_t offset, uint32_t actual) {
  uint32_t expected = 0;
  return Add(base, offset, &expected) && expected == actual;
}

inline bool ValidViewport(const Viewport& viewport) {
  if (viewport.width <= 0 || viewport.height <= 0) return false;
  const int64_t right = static_cast<int64_t>(viewport.x) + viewport.width;
  const int64_t bottom = static_cast<int64_t>(viewport.y) + viewport.height;
  return right <= std::numeric_limits<int32_t>::max() &&
         bottom <= std::numeric_limits<int32_t>::max();
}

// Private to the two-pass public operation: each read is one byte or one DWORD.
inline bool ReadOnce(uintptr_t base, const sites::Sites& resolved, Read read,
                     void* context, Snapshot* output) {
  Snapshot result;
  if (!Pointer(read, context, base, resolved.config_slot, &result.config) ||
      !Pointer(read, context, base, resolved.owner_slot, &result.owner) ||
      !Pointer(read, context, base, resolved.window_slot, &result.window) ||
      !Pointer(read, context, base, resolved.input_slot, &result.input) ||
      !Pointer(read, context, base, resolved.modal_slot, &result.modal) ||
      !Pointer(read, context, base, resolved.hidden_slot, &result.hidden) ||
      !Pointer(read, context, base, resolved.auxiliary_visibility_slot,
               &result.auxiliary))
    return false;
  if (!Alias(result.config, sites::kConfigOwner, result.owner) ||
      !Alias(result.owner, sites::kOwnerWindow, result.window) ||
      !Alias(result.owner, sites::kOwnerInput, result.input) ||
      !Alias(result.owner, sites::kOwnerModal, result.modal) ||
      !Alias(result.owner, sites::kOwnerHidden, result.hidden))
    return false;
  if (!Scalar(read, context, result.window, 0, &result.window_vtable) ||
      result.window_vtable == 0 || (result.window_vtable & 3u) != 0 ||
      !Scalar(read, context, result.window, 4, &result.window_handle) ||
      result.window_handle == 0)
    return false;
  uint32_t handler = 0, expected_handler = 0;
  if (resolved.main_message_handler == 0 ||
      !Add(base, resolved.main_message_handler, &expected_handler) ||
      !Scalar(read, context, result.window_vtable, 4, &handler) ||
      handler != expected_handler)
    return false;
  int32_t owner_width = 0, owner_height = 0;
  if (!Scalar(read, context, result.config, sites::kConfigWidth,
              &result.design_width) ||
      !Scalar(read, context, result.config, sites::kConfigHeight,
              &result.design_height) ||
      !Scalar(read, context, result.owner, sites::kOwnerDesignWidth,
              &owner_width) ||
      !Scalar(read, context, result.owner, sites::kOwnerDesignHeight,
              &owner_height) ||
      result.design_width < 256 || result.design_width > 16384 ||
      result.design_height < 256 || result.design_height > 16384 ||
      result.design_width != owner_width ||
      result.design_height != owner_height)
    return false;
  if (!Scalar(read, context, result.owner, sites::kOwnerViewportX,
              &result.viewport.x) ||
      !Scalar(read, context, result.owner, sites::kOwnerViewportY,
              &result.viewport.y) ||
      !Scalar(read, context, result.owner, sites::kOwnerViewportWidth,
              &result.viewport.width) ||
      !Scalar(read, context, result.owner, sites::kOwnerViewportHeight,
              &result.viewport.height) ||
      !ValidViewport(result.viewport))
    return false;
  if (!Scalar(read, context, result.modal, sites::kModalByte,
              &result.blocked_flags[0]) ||
      !Scalar(read, context, result.hidden, sites::kHiddenByte,
              &result.blocked_flags[1]) ||
      !Scalar(read, context, result.owner, sites::kOwnerLogByte,
              &result.blocked_flags[2]) ||
      !Scalar(read, context, result.auxiliary, 0x5c, &result.blocked_flags[3]))
    return false;
  result.structure_valid = true;
  result.dialogue_input_allowed =
      result.blocked_flags == std::array<uint8_t, 4>{};
  *output = result;
  return true;
}

inline auto Identity(const Snapshot& s) {
  return std::tie(s.config, s.owner, s.window, s.input, s.modal, s.hidden,
                  s.auxiliary, s.window_vtable, s.window_handle, s.design_width,
                  s.design_height, s.viewport.x, s.viewport.y, s.viewport.width,
                  s.viewport.height, s.blocked_flags);
}

// There is no engine-owned atomic snapshot epoch here. Two complete bounded
// reads reject any observed pointer/field drift without retrying; an ABA change
// entirely between reads cannot be detected. Callers revalidate on publication
// and every input operation, together with their session/window/occurrence
// gates.
inline bool ReadSnapshot(uintptr_t module_base, const sites::Sites& resolved,
                         Read read, void* context, Snapshot* output) {
  if (output == nullptr) return false;
  *output = {};
  if (read == nullptr || module_base == 0 || (module_base & 3u) != 0 ||
      module_base > std::numeric_limits<uint32_t>::max())
    return false;
  Snapshot first, second;
  if (!ReadOnce(module_base, resolved, read, context, &first) ||
      !ReadOnce(module_base, resolved, read, context, &second) ||
      Identity(first) != Identity(second))
    return false;
  *output = second;
  return true;
}

}  // namespace fushi_voice_hook::siglus_legacy_runtime
