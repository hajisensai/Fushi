#pragma once

#include <array>
#include <limits>
#include <tuple>

#include "siglus_legacy_owner.h"
#include "siglus_legacy_runtime.h"
#include "siglus_ninearg_family.h"

// Live reads for the nine-argument family. The static resolver proves only
// sites; every field below is re-read here and cross-checked through the
// owner's own aliases, so a different build of the generation fails closed.
namespace fushi_voice_hook::siglus_ninearg_runtime {
namespace na = siglus_ninearg;
using siglus_legacy_runtime::Read;
using siglus_legacy_runtime::Viewport;

struct Snapshot {
  bool structure_valid = false;
  // Necessary input gates only (the engine's own visibility/input predicates);
  // the glyph occurrence and text are admitted separately.
  bool dialogue_input_allowed = false;
  uint32_t config = 0;
  uint32_t owner = 0;
  uint32_t window = 0;
  uint32_t input = 0;
  uint32_t modal = 0;
  uint32_t hidden = 0;
  uint32_t auxiliary = 0;
  uint32_t window_vtable = 0;
  // window+4 is the opaque x86 HWND the engine passes to ScreenToClient; the
  // caller checks IsWindow, process ownership and the client rectangle.
  uint32_t window_handle = 0;
  int32_t design_width = 0;
  int32_t design_height = 0;
  Viewport viewport{};
  // Modal, hidden dialogue, auxiliary and the gate byte. Raw bytes so any
  // change between the two reads rejects the mixed snapshot.
  std::array<uint8_t, 4> blocked_flags{};
};

inline bool ReadOnce(uintptr_t base, const na::Sites& sites, Read read,
                     void* context, Snapshot* output) {
  using siglus_legacy_runtime::Alias;
  using siglus_legacy_runtime::Pointer;
  using siglus_legacy_runtime::Scalar;
  Snapshot result;
  if (!Pointer(read, context, base, sites.config_slot, &result.config) ||
      !Pointer(read, context, base, sites.owner_slot, &result.owner) ||
      !Pointer(read, context, base, sites.window_slot, &result.window) ||
      !Pointer(read, context, base, sites.input_slot, &result.input) ||
      !Pointer(read, context, base, sites.modal_slot, &result.modal) ||
      !Pointer(read, context, base, sites.hidden_slot, &result.hidden) ||
      !Pointer(read, context, base, sites.auxiliary_slot, &result.auxiliary))
    return false;
  if (!Alias(result.config, na::kConfigOwner, result.owner) ||
      !Alias(result.owner, na::kOwnerWindow, result.window) ||
      !Alias(result.owner, na::kOwnerInput, result.input) ||
      !Alias(result.owner, na::kOwnerModal, result.modal) ||
      !Alias(result.owner, na::kOwnerHidden, result.hidden) ||
      !Alias(result.owner, na::kOwnerAuxiliary, result.auxiliary))
    return false;
  if (!Scalar(read, context, result.window, 0, &result.window_vtable) ||
      result.window_vtable == 0 || (result.window_vtable & 3u) != 0 ||
      !Scalar(read, context, result.window, 4, &result.window_handle) ||
      result.window_handle == 0)
    return false;
  uint32_t handler = 0, expected_handler = 0;
  if (sites.main_message_handler == 0 ||
      !siglus_legacy_runtime::Add(base, sites.main_message_handler,
                                  &expected_handler) ||
      !Scalar(read, context, result.window_vtable, 4, &handler) ||
      handler != expected_handler)
    return false;
  int32_t owner_width = 0, owner_height = 0;
  if (!Scalar(read, context, result.config, na::kConfigWidth, &result.design_width) ||
      !Scalar(read, context, result.config, na::kConfigHeight, &result.design_height) ||
      !Scalar(read, context, result.owner, na::kOwnerDesignWidth, &owner_width) ||
      !Scalar(read, context, result.owner, na::kOwnerDesignHeight, &owner_height) ||
      result.design_width < 256 || result.design_width > 16384 ||
      result.design_height < 256 || result.design_height > 16384 ||
      result.design_width != owner_width || result.design_height != owner_height)
    return false;
  if (!Scalar(read, context, result.owner, na::kOwnerViewportX, &result.viewport.x) ||
      !Scalar(read, context, result.owner, na::kOwnerViewportY, &result.viewport.y) ||
      !Scalar(read, context, result.owner, na::kOwnerViewportWidth,
              &result.viewport.width) ||
      !Scalar(read, context, result.owner, na::kOwnerViewportHeight,
              &result.viewport.height) ||
      !siglus_legacy_runtime::ValidViewport(result.viewport))
    return false;
  if (!Scalar(read, context, result.modal, na::kModalByte, &result.blocked_flags[0]) ||
      !Scalar(read, context, result.hidden, na::kHiddenByte, &result.blocked_flags[1]) ||
      !Scalar(read, context, result.auxiliary, na::kAuxiliaryByte,
              &result.blocked_flags[2]) ||
      !Scalar(read, context, result.owner, na::kOwnerGateByte, &result.blocked_flags[3]))
    return false;
  result.structure_valid = true;
  result.dialogue_input_allowed = result.blocked_flags == std::array<uint8_t, 4>{};
  *output = result;
  return true;
}

inline auto Identity(const Snapshot& s) {
  return std::tie(s.config, s.owner, s.window, s.input, s.modal, s.hidden,
                  s.auxiliary, s.window_vtable, s.window_handle, s.design_width,
                  s.design_height, s.viewport.x, s.viewport.y, s.viewport.width,
                  s.viewport.height, s.blocked_flags);
}

// Two complete bounded reads; any observed drift rejects without retrying.
inline bool ReadSnapshot(uintptr_t module_base, const na::Sites& sites, Read read,
                         void* context, Snapshot* output) {
  if (output == nullptr) return false;
  *output = {};
  if (read == nullptr || module_base == 0 || (module_base & 3u) != 0 ||
      module_base > std::numeric_limits<uint32_t>::max())
    return false;
  Snapshot first, second;
  if (!ReadOnce(module_base, sites, read, context, &first) ||
      !ReadOnce(module_base, sites, read, context, &second) ||
      Identity(first) != Identity(second))
    return false;
  *output = second;
  return true;
}

}  // namespace fushi_voice_hook::siglus_ninearg_runtime

// Owner -> normal groups -> render owners -> dialogue entries -> glyphs. Same
// bounded snapshot/publication contract as the legacy owner walk, with this
// generation's vectors and strides.
namespace fushi_voice_hook::siglus_ninearg_owner {
namespace na = siglus_ninearg;
using siglus_legacy_owner::Contains;
using siglus_legacy_owner::kMaxGlyphs;
using siglus_legacy_owner::kMaxPaths;
using siglus_legacy_owner::kMaxWalkNodes;
using siglus_legacy_owner::Path;
using siglus_legacy_owner::Read;
using siglus_legacy_owner::Same;
using siglus_legacy_owner::Snapshot;
using siglus_legacy_owner::Valid;
using siglus_legacy_owner::Vector;

template <typename Reader>
inline bool OwnerRootCurrent(const Snapshot& snapshot, Reader& reader) {
  uint32_t config = 0, manager = 0;
  return Read(reader, snapshot.config_slot, 0, &config) &&
      Read(reader, snapshot.manager_slot, 0, &manager) &&
      config >= 0x10000 && config == snapshot.config && manager == snapshot.manager &&
      uint64_t{config} + na::kConfigOwner == manager;
}

// Worker-only bounded enumeration; on budget exhaustion or an invalid read no
// snapshot is published, never a truncated owner set.
template <typename Reader>
inline bool BuildSnapshot(uint32_t config_slot, uint32_t manager_slot,
                          Reader& reader, Snapshot* out) {
  if (!out) return false;
  *out = {};
  Snapshot next;
  next.config_slot = config_slot; next.manager_slot = manager_slot;
  if (!Read(reader, config_slot, 0, &next.config) ||
      !Read(reader, manager_slot, 0, &next.manager) ||
      next.config < 0x10000 ||
      uint64_t{next.config} + na::kConfigOwner != next.manager ||
      !Read(reader, next.manager, na::kOwnerGroups, &next.groups) ||
      !Valid(next.groups, na::kGroupStride, kMaxPaths)) return false;
  size_t visited = 0;
  for (uint32_t group = next.groups.begin; group < next.groups.end;
       group += na::kGroupStride) {
    if (++visited > kMaxWalkNodes) return false;
    Vector owners;
    if (!Read(reader, group, na::kGroupOwners, &owners) ||
        !Valid(owners, na::kOwnerStride, kMaxPaths)) return false;
    for (uint32_t owner = owners.begin; owner < owners.end; owner += na::kOwnerStride) {
      if (++visited > kMaxWalkNodes) return false;
      Vector entries;
      if (!Read(reader, owner, na::kOwnerEntries, &entries) ||
          !Valid(entries, na::kEntryStride, kMaxPaths)) return false;
      for (uint32_t entry = entries.begin; entry < entries.end;
           entry += na::kEntryStride) {
        if (++visited > kMaxWalkNodes) return false;
        Vector glyphs;
        if (!Read(reader, entry, na::kEntryGlyphs, &glyphs) ||
            !Valid(glyphs, na::kGlyphStride, kMaxGlyphs)) return false;
        if (glyphs.begin == glyphs.end) continue;
        if (next.count == kMaxPaths) return false;
        for (size_t i = 0; i < next.count; ++i) {
          const auto& other = next.paths[i].glyphs;
          if (glyphs.begin < other.end && other.begin < glyphs.end) return false;
        }
        next.paths[next.count++] = {group, owner, entry, owners, entries, glyphs};
      }
    }
  }
  Vector groups;
  if (!next.count || !OwnerRootCurrent(next, reader) ||
      !Read(reader, next.manager, na::kOwnerGroups, &groups) ||
      !Same(groups, next.groups)) return false;
  *out = next;
  return true;
}

// Callback cost: bounded interval checks plus eight reads for the one path.
// Ownership only; visibility, occurrence and publication stay with the caller.
template <typename Reader>
inline bool ContainsCurrentGlyph(const Snapshot& snapshot, uint32_t self,
                                 Reader& reader) {
  if (!self || !snapshot.count || snapshot.count > kMaxPaths) return false;
  const Path* found = nullptr;
  for (size_t i = 0; i < snapshot.count; ++i) {
    if (!Contains(snapshot.paths[i].glyphs, self, na::kGlyphStride)) continue;
    if (found) return false;
    found = &snapshot.paths[i];
  }
  if (!found || !Contains(snapshot.groups, found->group, na::kGroupStride) ||
      !Contains(found->owners, found->owner, na::kOwnerStride) ||
      !Contains(found->entries, found->entry, na::kEntryStride) ||
      !OwnerRootCurrent(snapshot, reader)) return false;
  Vector groups, owners, entries, glyphs;
  return Read(reader, snapshot.manager, na::kOwnerGroups, &groups) &&
      Same(groups, snapshot.groups) &&
      Read(reader, found->group, na::kGroupOwners, &owners) &&
      Same(owners, found->owners) &&
      Read(reader, found->owner, na::kOwnerEntries, &entries) &&
      Same(entries, found->entries) &&
      Read(reader, found->entry, na::kEntryGlyphs, &glyphs) &&
      Same(glyphs, found->glyphs) && OwnerRootCurrent(snapshot, reader);
}

}  // namespace fushi_voice_hook::siglus_ninearg_owner
