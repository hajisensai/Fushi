#pragma once

#include "siglus_legacy_glyph_sites.h"
#include "siglus_legacy_input_viewport.h"

namespace fushi_voice_hook::siglus_legacy_owner {
namespace input = siglus_legacy_input_viewport;
namespace glyph = siglus_legacy_glyph;
using siglus_family::Signature;

// Normal manager group -> render owner -> dialogue entry -> glyph records.
// The manager's separate auxiliary group vector is deliberately not admitted.
inline constexpr uint32_t kManagerGroups = 0x3c2cc;
inline constexpr uint32_t kGroupStride = 0x3e0;
inline constexpr uint32_t kGroupOwners = 0x1cc;
inline constexpr uint32_t kOwnerStride = 0xea0;
inline constexpr uint32_t kOwnerEntries = 0x154;
inline constexpr uint32_t kEntryStride = 0x10c;
inline constexpr uint32_t kEntryGlyphs = 0x100;
inline constexpr uint32_t kGlyphStride = 0x1e0;

inline constexpr Signature kRenderEntry{
    "81 EC F8 00 00 00 53 55 8B AC 24 04 01 00 00 56 57 55 E8 ?? ?? ?? ??"};
inline constexpr Signature kRenderExit{
    "5F 5E 5D B0 01 5B 81 C4 F8 00 00 00 C2 0C 00"};
inline constexpr Signature kGroupRender{
    "53 8B 5C 24 08 8B 83 C8 00 00 00 85 C0 55 56 57 75 04 33 FF EB 19 8B 8B CC 00 00 00 2B C8 B8 63 EE 6D 02 F7 E9 C1 FA 05 8B FA C1 EF 1F 03 FA 33 F6 85 FF 0F 8E 84 00 00 00 33 ED EB 03 8D 49 00 8B 83 C8 00 00 00 85 C0 74 1D 8B 8B CC 00 00 00 2B C8 B8 63 EE 6D 02 F7 E9 C1 FA 05 8B C2 C1 E8 1F 03 C2 3B F0 72 05 E8 ?? ?? ?? ?? 8B 83 C8 00 00 00 80 7C 28 60 00 74 37 85 C0 74 1D 8B 8B CC 00 00 00 2B C8 B8 63 EE 6D 02 F7 E9 C1 FA 05 8B C2 C1 E8 1F 03 C2 3B F0 72 05 E8 ?? ?? ?? ?? 8B 8B C8 00 00 00 6A 00 6A 00 03 CD E8 ?? ?? ?? ?? 83 C6 01 81 C5 2C 0D 00 00 3B F7 7C 83 8B 0D ?? ?? ?? ?? 80 79 02 00 0F 85 AA 00 00 00 8B 15 ?? ?? ?? ?? 80 BA FB 01 00 00 00 0F 85 97 00 00 00 A1 ?? ?? ?? ?? 80 78 5C 00 0F 85 88 00 00 00 8B 83 CC 01 00 00 85 C0 75 04 33 FF EB 1B 8B 8B D0 01 00 00 2B C8 B8 8D C0 08 8C F7 E9 03 D1 C1 FA 0B 8B FA C1 EF 1F 03 FA 33 F6 85 FF 7E 59 33 ED 8B 83 CC 01 00 00 85 C0 74 1F 8B 8B D0 01 00 00 2B C8 B8 8D C0 08 8C F7 E9 03 D1 C1 FA 0B 8B C2 C1 E8 1F 03 C2 3B F0 72 05 E8 ?? ?? ?? ?? 8B 4C 24 1C 8B 83 CC 01 00 00 8B 54 24 18 51 03 C5 52 50 E8 ?? ?? ?? ?? 84 C0 74 57 83 C6 01 81 C5 A0 0E 00 00 3B F7 7C A9"};
inline constexpr Signature kNormalGroups{
    "8B 85 CC C2 03 00 85 C0 75 04 33 FF EB 1B 8B 8D D0 C2 03 00 2B C8 B8 43 08 21 84 F7 E9 03 D1 C1 FA 09 8B FA C1 EF 1F 03 FA 33 F6 85 FF 7E 5D 33 DB 8B 85 CC C2 03 00 85 C0 74 1F 8B 8D D0 C2 03 00 2B C8 B8 43 08 21 84 F7 E9 03 D1 C1 FA 09 8B C2 C1 E8 1F 03 C2 3B F0 72 05 E8 ?? ?? ?? ?? 8B 4C 24 14 8B 85 CC C2 03 00 8B 54 24 1C 51 03 C3 52 50 E8 ?? ?? ?? ?? 84 C0 0F 84 79 F4 FF FF 83 C6 01 81 C3 E0 03 00 00 3B F7 7C A5"};

struct Sites {
  uintptr_t render_entry = 0;
  uintptr_t group_entry = 0;
  uintptr_t normal_groups = 0;
  uintptr_t config_slot = 0;
  uintptr_t manager_slot = 0;
  // The group renderer skips dialogue when *(slot)+0x1fb is nonzero.
  // Its UI meaning is intentionally unnamed; this is a necessary reject gate.
  uintptr_t render_block_slot = 0;
};

// Call with independently resolved glyph/input sites. Static scopes and the
// shared hidden/auxiliary slots tie the families together, but do not prove
// an actual glyph's owner. The live membership transaction below closes that
// identity edge. Neither function proves menu visibility or an input lease.
inline bool Resolve(const exact_lookup::LoadedPeImage& image,
                    const LegacyGlyphSites& glyphs, const input::Sites& inputs,
                    Sites* out) {
  if (!out) return false;
  *out = {};
  if (!image.base || image.size < 4 || image.section_count > image.sections.size() ||
      image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32 ||
      !inputs.config_slot || !inputs.owner_slot || !inputs.hidden_slot ||
      !inputs.auxiliary_visibility_slot || !glyphs.owner_render_rva) return false;
  uintptr_t render = 0, exit = 0, group = 0, normal = 0;
  if (!siglus_family::Unique(image, kRenderEntry.pattern(), &render) ||
      !siglus_family::Unique(image, kRenderExit.pattern(), &exit) ||
      !siglus_family::Unique(image, kGroupRender.pattern(), &group) ||
      !siglus_family::Unique(image, kNormalGroups.pattern(), &normal) ||
      glyphs.owner_render_rva != render + 0x4f2 ||
      exit != render + 0xcd3 ||
      !siglus_family::ExecutableSpan(image, render,
                                    exit + kRenderExit.bytes.size() - render) ||
      !glyph::Calls(image, group + 353, render) ||
      !glyph::Calls(image, normal + 114, group) ||
      !glyph::SameCall(image, group + 103, group + 154) ||
      !glyph::SameCall(image, group + 103, group + 329) ||
      !glyph::SameCall(image, group + 329, normal + 90) ||
      input::Slot(image, group + 191) != inputs.hidden_slot ||
      input::Slot(image, group + 225) != inputs.auxiliary_visibility_slot ||
      !input::Slot(image, group + 207)) return false;
  uintptr_t unused = 0;
  if (!glyph::CallTarget(image, render + 18, &unused) ||
      !glyph::CallTarget(image, group + 171, &unused)) return false;
  for (const auto slot : {inputs.config_slot, inputs.owner_slot}) {
    if ((slot & 3u) || !input::Span(image, slot, 4, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,
                     IMAGE_SCN_MEM_EXECUTE)) return false;
  }
  *out = {render, group, normal, inputs.config_slot, inputs.owner_slot,
          input::Slot(image, group + 207)};
  return true;
}

// Metadata only: no characters, strings or game assets. Reader(address, dst,
// bytes) must copy a bounded readable span and return false on a read fault.
struct Vector {
  uint32_t begin = 0, end = 0, capacity = 0;
};
inline bool Same(const Vector& a, const Vector& b) {
  return a.begin == b.begin && a.end == b.end && a.capacity == b.capacity;
}
inline bool Valid(const Vector& v, uint32_t stride, size_t max_count) {
  if (!v.begin) return !v.end && !v.capacity;
  return v.begin >= 0x10000 && !(v.begin & 3) && v.begin <= v.end &&
      v.end <= v.capacity && (v.end - v.begin) % stride == 0 &&
      (v.capacity - v.begin) % stride == 0 &&
      (v.end - v.begin) / stride <= max_count;
}
inline bool Contains(const Vector& v, uint32_t value, uint32_t stride) {
  return value >= v.begin && value < v.end && (value - v.begin) % stride == 0;
}
struct Path {
  uint32_t group = 0, owner = 0, entry = 0;
  Vector owners, entries, glyphs;
};
inline constexpr size_t kMaxPaths = 64;
inline constexpr size_t kMaxWalkNodes = 128;
inline constexpr size_t kMaxGlyphs = 1024;
struct Snapshot {
  uint32_t config_slot = 0, manager_slot = 0, config = 0, manager = 0;
  Vector groups;
  std::array<Path, kMaxPaths> paths{};
  size_t count = 0;
};

template <typename Reader, typename T>
inline bool Read(Reader& reader, uint32_t base, uint32_t offset, T* out) {
  const uint64_t address = uint64_t{base} + offset;
  return address >= 0x10000 && address + sizeof(T) <= 0x100000000ull &&
      reader(static_cast<uint32_t>(address), out, sizeof(T));
}
template <typename Reader>
inline bool RenderAllowed(uint32_t slot, Reader& reader) {
  uint32_t object = 0, after = 0;
  uint8_t blocked = 0;
  return slot != 0 && (slot & 3u) == 0 &&
      Read(reader, slot, 0, &object) && object >= 0x10000 && (object & 3u) == 0 &&
      Read(reader, object, 0x1fb, &blocked) && blocked == 0 &&
      Read(reader, slot, 0, &after) && object == after;
}

template <typename Reader>
inline bool RootCurrent(const Snapshot& snapshot, Reader& reader) {
  uint32_t config = 0, manager = 0;
  return Read(reader, snapshot.config_slot, 0, &config) &&
      Read(reader, snapshot.manager_slot, 0, &manager) &&
      config >= 0x10000 && config == snapshot.config && manager == snapshot.manager &&
      uint64_t{config} + input::kConfigOwner == manager;
}

// Worker-only bounded enumeration. On budget exhaustion or an invalid read,
// publish no snapshot; never truncate the set of possible owners. A callback
// subsequently validates just its matching path against the current vectors.
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
      uint64_t{next.config} + input::kConfigOwner != next.manager ||
      !Read(reader, next.manager, kManagerGroups, &next.groups) ||
      !Valid(next.groups, kGroupStride, kMaxPaths)) return false;
  size_t visited = 0;
  for (uint32_t group = next.groups.begin; group < next.groups.end;
       group += kGroupStride) {
    if (++visited > kMaxWalkNodes) return false;
    Vector owners;
    if (!Read(reader, group, kGroupOwners, &owners) ||
        !Valid(owners, kOwnerStride, kMaxPaths)) return false;
    for (uint32_t owner = owners.begin; owner < owners.end; owner += kOwnerStride) {
      if (++visited > kMaxWalkNodes) return false;
      Vector entries;
      if (!Read(reader, owner, kOwnerEntries, &entries) ||
          !Valid(entries, kEntryStride, kMaxPaths)) return false;
      for (uint32_t entry = entries.begin; entry < entries.end; entry += kEntryStride) {
        if (++visited > kMaxWalkNodes) return false;
        Vector glyphs;
        if (!Read(reader, entry, kEntryGlyphs, &glyphs) ||
            !Valid(glyphs, kGlyphStride, kMaxGlyphs)) return false;
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
  if (!next.count || !RootCurrent(next, reader) ||
      !Read(reader, next.manager, kManagerGroups, &groups) ||
      !Same(groups, next.groups)) return false;
  *out = next;
  return true;
}

// Callback cost: at most 64 scalar interval checks, then 8 bounded reads for
// the one path. This checks ownership only. The caller still owns visibility,
// capture epoch and safe snapshot publication; no snapshot grants an input lease.
template <typename Reader>
inline bool ContainsCurrentGlyph(const Snapshot& snapshot, uint32_t self,
                                 Reader& reader) {
  if (!self || !snapshot.count || snapshot.count > kMaxPaths) return false;
  const Path* found = nullptr;
  for (size_t i = 0; i < snapshot.count; ++i) {
    if (!Contains(snapshot.paths[i].glyphs, self, kGlyphStride)) continue;
    if (found) return false;
    found = &snapshot.paths[i];
  }
  if (!found || !Contains(snapshot.groups, found->group, kGroupStride) ||
      !Contains(found->owners, found->owner, kOwnerStride) ||
      !Contains(found->entries, found->entry, kEntryStride) ||
      !RootCurrent(snapshot, reader)) return false;
  Vector groups, owners, entries, glyphs;
  return Read(reader, snapshot.manager, kManagerGroups, &groups) &&
      Same(groups, snapshot.groups) &&
      Read(reader, found->group, kGroupOwners, &owners) && Same(owners, found->owners) &&
      Read(reader, found->owner, kOwnerEntries, &entries) && Same(entries, found->entries) &&
      Read(reader, found->entry, kEntryGlyphs, &glyphs) && Same(glyphs, found->glyphs) &&
      RootCurrent(snapshot, reader);
}
}  // namespace fushi_voice_hook::siglus_legacy_owner
