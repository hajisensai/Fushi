#pragma once

#include "siglus_eight_arg_glyph.h"
#include "siglus_eightarg_input_viewport.h"

namespace fushi_voice_hook::siglus_eightarg_owner_profile {
namespace glyph = siglus_eight_arg_glyph;
namespace input = siglus_eightarg_input_viewport;
using siglus_family::Signature;

struct Sites {
  uintptr_t engine_owner_slot = 0;
  uintptr_t scene_slot = 0;
  uintptr_t manager_slot = 0;
  uintptr_t normal_render_return_rva = 0;
  uintptr_t normal_case_rva = 0;
  uintptr_t group_selection_rva = 0;
  uintptr_t index_selection_rva = 0;
  uintptr_t render_group_entry_rva = 0;
};
inline constexpr uint32_t kSceneOwnerOffset = 0x42898;
inline constexpr uint32_t kSceneContainerOffset = 0xa4;
inline constexpr uint32_t kEngineOwnerContainerOffset = 0x4293c;
inline constexpr uint32_t kNormalGroupOffset = 0x734;
inline constexpr uint32_t kGroupOwnerBegin = 0x3b8;
inline constexpr uint32_t kGroupOwnerEnd = 0x3bc;
inline constexpr uint32_t kOwnerStride = 0x1630;
static_assert(kSceneOwnerOffset + kSceneContainerOffset == kEngineOwnerContainerOffset);
static_assert(0x314 + 4 + 0xa0 == kGroupOwnerBegin);
static_assert(0x314 + 4 + 0xa4 == kGroupOwnerEnd);
static_assert(kSceneOwnerOffset == input::kOwnerScene);

// These are compiler instructions, not a VM implementation. The known normal
// branch selects a member of the same vector the normal rendering group walks.
// Other expressions can return other object kinds; runtime must still intersect
// the actual message ECX with this normal group and selected surface. Never call
// the engine evaluator, infer an owner from a timestamp, or admit the auxiliary
// +e68 group / alternate engine-owner+48d10 root.
inline constexpr Signature kEvaluator{
    "55 8B EC 83 E4 F8 83 EC 20 8B 45 08 0F 57 C0 88 44 24 1C 8D 44 24 04 50 F3 0F 7F 44 24 08 C7 44 24 18 00 00 00 00 C7 44 24 1C 00 00 00 00 E8 ?? ?? ?? ?? 8B 44 24 1C 83 C4 04 8B E5 5D C3"};

inline constexpr Signature kVmEntry{
    "55 8B EC 83 E4 F8 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 00 03 00 00 A1 ?? ?? ?? ?? 33 C4 89 84 24 F8 02 00 00 53 56 57 A1 ?? ?? ?? ?? 33 C4 50 8D 84 24 10 03 00 00 64 A3 00 00 00 00 8B DA 8B F9 89 7C 24 1C 8B 75 08"};

inline constexpr Signature kVmDispatch{
    "8B 0F 81 F9 A3 00 00 00 0F 87 9E 18 00 00 FF 24 8D ?? ?? ?? ??"};

inline constexpr Signature kNormalCase{
    "56 8D 47 04 8B D7 53 50 A1 ?? ?? ?? ?? 8B 88 A4 00 00 00 81 C1 34 07 00 00 E8 ?? ?? ?? ?? 83 C4 0C E9 C4 16 00 00"};

inline constexpr Signature kGroupSelection{
    "55 8B EC 83 E4 F8 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 38 A1 ?? ?? ?? ?? 33 C4 89 44 24 30 53 56 57 A1 ?? ?? ?? ?? 33 C4 50 8D 44 24 48 64 A3 00 00 00 00 8B DA 8B 75 08 8B 7D 0C 8B 55 10 3B F7 75 08 89 4A 14 E9 35 01 00 00 8B 06 83 F8 02 75 1B 52 8D 46 04 81 C1 A0 00 00 00 57 50 8B D3 E8 ?? ?? ?? ?? 83 C4 0C E9 13 01 00 00 83 F8 03 75 1B 52 8D 46 04 81 C1 14 03 00 00 57 50 8B D3 E8 ?? ?? ?? ?? 83 C4 0C E9 F3 00 00 00"};

inline constexpr Signature kElementSelection{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 40 A1 ?? ?? ?? ?? 33 C5 89 45 EC 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 89 55 B8 8B 75 08 8B 5D 0C 8B 7D 10 3B F3 75 19 85 C9 74 0B 83 C1 04 89 4F 14 E9 A1 00 00 00 33 C9 89 4F 14 E9 97 00 00 00 8B 06 83 F8 FF 75 29 0F B6 47 18 83 C1 04 50 FF 76 04 E8 ?? ?? ?? ?? 85 C0 74 7C 8B 55 B8 8D 4E 08 57 53 51 8B C8 E8 ?? ?? ?? ?? 83 C4 0C EB 67"};

inline constexpr Signature kIndexSelection{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 98 00 00 00 A1 ?? ?? ?? ?? 33 C5 89 45 F0 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B F9 8B 75 08 85 F6 78 32 8B 8F A4 00 00 00 B8 B7 E1 4D 5C 2B 8F A0 00 00 00 F7 E9 C1 FA 0B 8B C2 C1 E8 1F 03 C2 3B C6 7E 11 69 C6 30 16 00 00 03 87 A0 00 00 00 E9 6F 01 00 00"};

inline constexpr Signature kIndexReturn{
    "8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 8B 4D F0 33 CD E8 ?? ?? ?? ?? 8B E5 5D C2 08 00"};

inline constexpr Signature kOwnerIdentity{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 80 02 00 00 A1 ?? ?? ?? ?? 33 C5 89 45 EC 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B FA 8B D9 89 9D 80 FD FF FF 8B 55 08 8B 4D 0C 8B 75 10 89 95 78 FD FF FF 85 DB 0F 84 49 0C 00 00 3B D1 75 08 89 5E 14 E9 3D 0C 00 00"};

inline constexpr Signature kNormalRender{
    "8D 8E 30 83 04 00 E8 ?? ?? ?? ?? 8B BD CC FD FF FF 83 F8 02 74 42 83 F8 03 74 3D 8B 8E 3C 29 04 00 6A 00 FF B5 C4 FD FF FF 81 C1 34 07 00 00 57 E8 ?? ?? ?? ?? 83 BE D4 D9 03 00 00 7C 1A 8B 8E 3C 29 04 00 6A 00 FF B5 C4 FD FF FF 81 C1 68 0E 00 00 57 E8 ?? ?? ?? ??"};

inline bool ReadOnlyTable(const exact_lookup::LoadedPeImage& image,
                          uintptr_t operand, uintptr_t* table) {
  const uintptr_t base = image.absolute_base != 0 ? image.absolute_base
      : reinterpret_cast<uintptr_t>(image.base);
  const uint32_t va = glyph::Word(image, operand);
  if (base > UINT32_MAX || va <= base || va - base >= image.size) return false;
  const uintptr_t rva = va - base;
  constexpr size_t size = 0xa4u * sizeof(uint32_t);
  if (size > image.size - rva || !exact_lookup::SectionHasRole(
      exact_lookup::FindSectionForRva(image, rva, size),
      IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_WRITE) ||
      !exact_lookup::IsReadableSpan(image.base + rva, size)) return false;
  *table = rva;
  return true;
}

// Both supplied lanes must already be admitted. Recheck the full glyph proof
// and the publications this join uses, so copied/mixed slot metadata cannot
// substitute a different engine root, configuration or manager.
inline bool Resolve(const exact_lookup::LoadedPeImage& image,
                    const SiglusEightArgGlyphSites& admitted_glyph,
                    const input::Sites& admitted_input, Sites* out) {
  if (out == nullptr) return false;
  *out = {};
  SiglusEightArgGlyphSites proved;
  if (!glyph::Resolve(image, &proved) ||
      proved.glyph_entry_rva != admitted_glyph.glyph_entry_rva ||
      proved.glyph_return_rva != admitted_glyph.glyph_return_rva ||
      proved.wrapper_entry_rva != admitted_glyph.wrapper_entry_rva ||
      proved.wrapper_glyph_return_rva != admitted_glyph.wrapper_glyph_return_rva ||
      proved.scenario_entry_rva != admitted_glyph.scenario_entry_rva ||
      proved.message_entry_rva != admitted_glyph.message_entry_rva ||
      proved.message_scenario_return_rva != admitted_glyph.message_scenario_return_rva ||
      proved.message_dispatch_rva != admitted_glyph.message_dispatch_rva ||
      proved.message_caller_return_rva != admitted_glyph.message_caller_return_rva ||
      proved.render_entry_rva != admitted_glyph.render_entry_rva ||
      proved.render_wrapper_returns[0] != admitted_glyph.render_wrapper_returns[0] ||
      proved.render_wrapper_returns[1] != admitted_glyph.render_wrapper_returns[1] ||
      proved.render_group_entry_rva != admitted_glyph.render_group_entry_rva ||
      proved.group_render_return_rva != admitted_glyph.group_render_return_rva ||
      proved.font_entry_rva != admitted_glyph.font_entry_rva ||
      proved.coordinate_writer_rva != admitted_glyph.coordinate_writer_rva ||
      proved.transform_entry_rva != admitted_glyph.transform_entry_rva ||
      proved.owner_selector_rva != admitted_glyph.owner_selector_rva ||
      proved.config_slot_rva != admitted_glyph.config_slot_rva ||
      proved.manager_slot_rva != admitted_glyph.manager_slot_rva ||
      proved.config_slot_rva != admitted_input.config_slot ||
      proved.manager_slot_rva != admitted_input.manager_slot) return false;
  uintptr_t root = 0, aliases = 0;
  if (!glyph::Unique(image, input::kRoot.pattern(), &root) ||
      !glyph::Unique(image, input::kAliases.pattern(), &aliases) ||
      !input::Relocations(image, root, input::kRootRelocations) ||
      !input::Relocations(image, aliases, input::kAliasesRelocations) ||
      glyph::Address(image, root + 5, false) != admitted_input.root_slot ||
      glyph::Address(image, root + 25, false) != admitted_input.owner_slot ||
      glyph::Address(image, root + 30, false) != proved.config_slot_rva ||
      glyph::Address(image, aliases + 149, false) != proved.manager_slot_rva ||
      glyph::Address(image, aliases + 586, false) != admitted_input.scene_slot)
    return false;
  // An unused publication must not overwrite a joined role later in the same
  // constructor. Preserve the input resolver's alias-uniqueness contract.
  for (size_t a = 0; a < std::size(input::kAliasesRelocations); ++a) {
    const auto value = glyph::Address(image, aliases + input::kAliasesRelocations[a].offset, false);
    for (size_t b = 0; b < a; ++b)
      if (value == glyph::Address(image, aliases + input::kAliasesRelocations[b].offset, false)) return false;
    for (const auto& p : input::kRootRelocations)
      if (value == glyph::Address(image, root + p.offset, false)) return false;
  }
  for (size_t a = 0; a < std::size(input::kRootRelocations); ++a)
    for (size_t b = 0; b < a; ++b)
      if (glyph::Address(image, root + input::kRootRelocations[a].offset, false) ==
          glyph::Address(image, root + input::kRootRelocations[b].offset, false)) return false;
  const uintptr_t joined_slots[] = {admitted_input.root_slot,
      admitted_input.owner_slot, admitted_input.scene_slot,
      proved.config_slot_rva, proved.manager_slot_rva};
  for (size_t a = 0; a < std::size(joined_slots); ++a) {
    if (joined_slots[a] == 0) return false;
    for (size_t b = 0; b < a; ++b)
      if (joined_slots[a] == joined_slots[b]) return false;
  }
  uintptr_t evaluator = 0, vm = 0, normal = 0, group = 0;
  uintptr_t element = 0, index = 0, identity = 0, render = 0;
  if (!glyph::Unique(image, kEvaluator.pattern(), &evaluator) ||
      !glyph::Unique(image, kVmEntry.pattern(), &vm) ||
      !glyph::Unique(image, kNormalCase.pattern(), &normal) ||
      !glyph::Unique(image, kGroupSelection.pattern(), &group) ||
      !glyph::Unique(image, kElementSelection.pattern(), &element) ||
      !glyph::Unique(image, kIndexSelection.pattern(), &index) ||
      !glyph::Unique(image, kOwnerIdentity.pattern(), &identity) ||
      !glyph::Unique(image, kNormalRender.pattern(), &render) ||
      !glyph::At(image, vm, 0x98, kVmDispatch.pattern()) ||
      normal < vm || normal - vm != 0x2d1 ||
      !glyph::At(image, index, 0x1d7, kIndexReturn.pattern())) return false;
  if (glyph::Call(image, proved.owner_selector_rva + 20) != evaluator ||
      glyph::Call(image, evaluator + 46) != vm ||
      glyph::Call(image, normal + 25) != group ||
      glyph::Call(image, group + 131) != element ||
      glyph::Call(image, element + 102) != index ||
      glyph::Call(image, element + 122) != identity ||
      glyph::Call(image, render + 48) != proved.render_group_entry_rva ||
      glyph::Call(image, render + 83) != proved.render_group_entry_rva ||
      glyph::Address(image, normal + 9, false) != admitted_input.scene_slot)
    return false;
  uintptr_t table = 0;
  if (!ReadOnlyTable(image, vm + 0x98 + 17, &table) ||
      glyph::Address(image, table + 0x26 * 4, true) != normal) return false;
  const uintptr_t cookie = glyph::Address(image, proved.glyph_entry_rva + 27, false);
  for (auto at : {vm + 27, vm + 44, group + 24, group + 38,
                  element + 21, index + 24, identity + 24})
    if (glyph::Address(image, at, false) != cookie) return false;
  for (auto at : {vm + 9, group + 9, element + 6, index + 6, identity + 6})
    if (glyph::Address(image, at, true) == 0) return false;
  for (auto at : {group + 99, render + 6, index + 0x1d7 + 18})
    if (glyph::Call(image, at) == 0) return false;
  *out = {admitted_input.owner_slot, admitted_input.scene_slot,
      proved.manager_slot_rva, render + 53, normal, group, index,
      proved.render_group_entry_rva};
  return true;
}
}  // namespace fushi_voice_hook::siglus_eightarg_owner_profile
