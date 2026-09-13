#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../hook/adapters/siglus_legacy_owner.h"
#include <cassert>
#include <cstdio>
#include <map>
#include <vector>

namespace {
using namespace fushi_voice_hook;
namespace own = siglus_legacy_owner;
struct Code {
  uint8_t* bytes = static_cast<uint8_t*>(VirtualAlloc(
      nullptr, 0x9000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
  exact_lookup::LoadedPeImage image;
  LegacyGlyphSites glyphs;
  own::input::Sites inputs;
  uintptr_t render, group, normal;
  explicit Code(uintptr_t shift = 0, uintptr_t base = 0x100000)
      : render(0x1000 + shift), group(0x3000 + shift), normal(0x4000 + shift) {
    assert(bytes);
    memset(bytes, 0xcc, 0x9000);
    image.base = bytes; image.absolute_base = base; image.size = 0x9000;
    image.machine = IMAGE_FILE_MACHINE_I386; image.pointer_bits = 32;
    image.section_count = 2;
    image.sections[0] = {bytes + 0x1000, 0x6000, 0x1000,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {bytes + 0x7000, 0x2000, 0x7000,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
    Put(render, own::kRenderEntry.pattern());
    Put(render + 0xcd3, own::kRenderExit.pattern());
    Put(group, own::kGroupRender.pattern()); Put(normal, own::kNormalGroups.pattern());
    Call(render + 18, 0x6100); Call(group + 171, 0x6200);
    for (auto at : {group + 103, group + 154, group + 329, normal + 90})
      Call(at, 0x6000);
    Call(group + 353, render); Call(normal + 114, group);
    inputs.config_slot = 0x7100; inputs.owner_slot = 0x7104;
    inputs.hidden_slot = 0x7108; inputs.auxiliary_visibility_slot = 0x710c;
    Address(group + 191, inputs.hidden_slot); Address(group + 225, inputs.auxiliary_visibility_slot);
    Address(group + 207, 0x7110);
    glyphs.owner_render_rva = render + 0x4f2;
  }
  ~Code() { VirtualFree(bytes, 0, MEM_RELEASE); }
  Code(const Code&) = delete;
  void Put(uintptr_t at, exact_lookup::MaskedPattern pattern) {
    memcpy(bytes + at, pattern.bytes, pattern.size);
  }
  void Word(uintptr_t at, uint32_t value) { memcpy(bytes + at, &value, 4); }
  void Address(uintptr_t at, uintptr_t target) {
    Word(at, static_cast<uint32_t>(image.absolute_base + target));
  }
  void Call(uintptr_t at, uintptr_t target) {
    bytes[at] = 0xe8; Word(at + 1, static_cast<uint32_t>(target - at - 5));
  }
  void Check() {
    own::Sites sites;
    assert(own::Resolve(image, glyphs, inputs, &sites));
    assert(sites.render_entry == render && sites.group_entry == group &&
           sites.normal_groups == normal && sites.manager_slot == inputs.owner_slot &&
           sites.config_slot == inputs.config_slot && sites.render_block_slot == 0x7110);
  }
  void Reject() {
    own::Sites sites{1, 2, 3, 4, 5, 6};
    assert(!own::Resolve(image, glyphs, inputs, &sites));
    assert(!sites.render_entry && !sites.group_entry && !sites.normal_groups &&
           !sites.config_slot && !sites.manager_slot && !sites.render_block_slot);
  }
};

void TestStructure() {
  Code{}.Check(); Code{0x75, 0x65000000}.Check();
  for (unsigned n = 0; n < 16; ++n) {
    Code c;
    switch (n) {
      case 0: c.Call(c.group + 353, 0x6000); break;
      case 1: c.Call(c.normal + 114, 0x6000); break;
      case 2: c.Call(c.normal + 90, 0x6100); break;
      case 3: c.Address(c.group + 191, c.inputs.auxiliary_visibility_slot); break;
      case 4: c.Address(c.group + 225, c.inputs.hidden_slot); break;
      case 5: c.Address(c.group + 207, 0x6100); break;
      case 6: c.glyphs.owner_render_rva++; break;
      case 7: c.image.machine = IMAGE_FILE_MACHINE_AMD64; break;
      case 8: c.image.pointer_bits = 64; break;
      case 9: c.inputs.config_slot = 0x6100; break;
      case 10: c.Call(c.render + 18, 0x7100); break;
      case 11: c.image.base = nullptr; break;
      case 12: c.image.section_count = c.image.sections.size() + 1; break;
      case 13: c.inputs.owner_slot++; break;
      case 14: c.Address(c.group + 207, 0x7111); break;
      case 15: c.Address(c.group + 207, 0x9000); break;
    }
    c.Reject();
  }
  for (auto pattern : {own::kRenderEntry.pattern(), own::kRenderExit.pattern(),
                        own::kGroupRender.pattern(), own::kNormalGroups.pattern()}) {
    Code c; c.Put(0x7500, pattern); c.Check(); c.Put(0x6500, pattern); c.Reject();
  }
  for (unsigned n = 0; n < 6; ++n) {
    Code c;
    const uintptr_t fields[] = {c.render + 11, c.render + 0xcd3 + 13,
        c.group + 350, c.group + 364, c.normal + 2, c.normal + 131};
    c.bytes[fields[n]] ^= 1; c.Reject();
  }
}

struct Memory {
  std::map<uint32_t, std::vector<uint8_t>> blocks;
  size_t reads = 0;
  uint32_t fault = 0;
  template <typename T> void Put(uint32_t at, T value) {
    auto& bytes = blocks[at]; bytes.resize(sizeof(T)); memcpy(bytes.data(), &value, sizeof(T));
  }
  bool operator()(uint32_t at, void* out, size_t size) {
    ++reads;
    const auto it = blocks.find(at);
    if (at == fault || it == blocks.end() || it->second.size() != size) return false;
    memcpy(out, it->second.data(), size); return true;
  }
};
void TestRenderGate() {
  Memory memory;
  constexpr uint32_t slot = 0x10000, object = 0x20000;
  memory.Put(slot, object);
  memory.Put(object + 0x1fb, uint8_t{0});
  assert(own::RenderAllowed(slot, memory) && memory.reads == 3);
  for (const uint8_t flag : {uint8_t{1}, uint8_t{2}, uint8_t{0xff}}) {
    memory.Put(object + 0x1fb, flag);
    assert(!own::RenderAllowed(slot, memory));
  }
  memory.Put(object + 0x1fb, uint8_t{0});
  for (uint32_t pointer : {0u, 1u, object + 1, 0xffffff00u}) {
    memory.Put(slot, pointer);
    assert(!own::RenderAllowed(slot, memory));
  }
  memory.Put(slot, object);
  memory.fault = object + 0x1fb;
  assert(!own::RenderAllowed(slot, memory));
  memory.fault = 0;
  size_t calls = 0;
  auto drift = [&](uint32_t at, void* out, size_t size) {
    if (++calls == 3) memory.Put(slot, object + 4);
    return memory(at, out, size);
  };
  assert(!own::RenderAllowed(slot, drift));
  assert(!own::RenderAllowed(slot + 1, memory));
}
struct Tree {
  Memory memory;
  static constexpr uint32_t config_slot = 0x10000, manager_slot = 0x10004;
  static constexpr uint32_t config = 0x100000;
  static constexpr uint32_t manager = config + own::input::kConfigOwner;
  static constexpr uint32_t group_base = 0x200000, owner_base = 0x300000;
  static constexpr uint32_t entry_base = 0x500000, glyph_base = 0x700000;
  Tree(unsigned groups = 1, unsigned owners = 1, unsigned entries = 1) {
    memory.Put(config_slot, config); memory.Put(manager_slot, manager);
    PutVector(manager + own::kManagerGroups, group_base, groups, own::kGroupStride);
    for (unsigned g = 0; g < groups; ++g) {
      const auto owner_start = owner_base + g * 0x10000;
      PutVector(group_base + g * own::kGroupStride + own::kGroupOwners,
                owner_start, owners, own::kOwnerStride);
      for (unsigned o = 0; o < owners; ++o) {
        const auto entry_start = entry_base + g * 0x10000 + o * 0x4000;
        PutVector(owner_start + o * own::kOwnerStride + own::kOwnerEntries,
                  entry_start, entries, own::kEntryStride);
        for (unsigned e = 0; e < entries; ++e) {
          const auto glyph_start = glyph_base + g * 0x400000 + o * 0x100000 + e * 0x4000;
          PutVector(entry_start + e * own::kEntryStride + own::kEntryGlyphs,
                    glyph_start, 5, own::kGlyphStride);
        }
      }
    }
  }
  void PutVector(uint32_t at, uint32_t begin, uint32_t count, uint32_t stride) {
    memory.Put(at, own::Vector{begin, begin + count * stride, begin + count * stride});
  }
  own::Snapshot Build() {
    own::Snapshot out;
    assert(own::BuildSnapshot(config_slot, manager_slot, memory, &out)); return out;
  }
  void Reject() {
    own::Snapshot out; out.count = 1;
    assert(!own::BuildSnapshot(config_slot, manager_slot, memory, &out));
    assert(!out.count && !out.manager && !out.config && !out.paths[0].group);
  }
};

void TestLiveMembership() {
  Tree t(2, 2, 2); auto snapshot = t.Build(); assert(snapshot.count == 8);
  for (const auto& path : snapshot.paths) {
    if (!path.group) continue;
    t.memory.reads = 0;
    assert(own::ContainsCurrentGlyph(snapshot, path.glyphs.begin, t.memory));
    assert(t.memory.reads == 8);
    assert(own::ContainsCurrentGlyph(snapshot, path.glyphs.end - own::kGlyphStride, t.memory));
    assert(!own::ContainsCurrentGlyph(snapshot, path.glyphs.begin + 1, t.memory));
    assert(!own::ContainsCurrentGlyph(snapshot, path.glyphs.end, t.memory));
  }
  t.memory.reads = 0;
  assert(!own::ContainsCurrentGlyph(snapshot, 0x123400, t.memory) && t.memory.reads == 0);
  // Overlapping cached identities are not resolved by choosing the first.
  snapshot.paths[1] = snapshot.paths[0];
  assert(!own::ContainsCurrentGlyph(snapshot, Tree::glyph_base, t.memory));
}
void TestStalePathsAndFaults() {
  for (unsigned n = 0; n < 6; ++n) {
    Tree t; const auto snapshot = t.Build();
    const uint32_t fields[] = {Tree::config_slot, Tree::manager_slot,
        Tree::manager + own::kManagerGroups, Tree::group_base + own::kGroupOwners,
        Tree::owner_base + own::kOwnerEntries, Tree::entry_base + own::kEntryGlyphs};
    t.memory.blocks[fields[n]][0] ^= 4;
    assert(!own::ContainsCurrentGlyph(snapshot, Tree::glyph_base, t.memory));
  }
  Tree t; const auto snapshot = t.Build();
  for (const auto& item : t.memory.blocks) {
    t.memory.fault = item.first;
    assert(!own::ContainsCurrentGlyph(snapshot, Tree::glyph_base, t.memory));
    t.Reject();
  }
}
void TestBudgetsAndInvalidVectors() {
  Tree limit(2, 2, 16); assert(limit.Build().count == own::kMaxPaths);
  Tree{65, 0, 0}.Reject(); Tree{43, 2, 0}.Reject(); Tree{2, 2, 17}.Reject();
  Tree empty(1, 1, 0); empty.Reject();
  for (unsigned n = 0; n < 6; ++n) {
    Tree t;
    own::Vector vector{Tree::glyph_base, Tree::glyph_base + own::kGlyphStride,
                       Tree::glyph_base + own::kGlyphStride};
    switch (n) {
      case 0: vector.begin = 0; break;
      case 1: vector.begin = vector.end + 4; break;
      case 2: vector.end++; break;
      case 3: vector.capacity--; break;
      case 4: vector.begin = 0xfffffff0; vector.end = 0xffffffff; vector.capacity = 0xffffffff; break;
      case 5: vector.end = vector.begin + 1025 * own::kGlyphStride; vector.capacity = vector.end; break;
    }
    t.memory.Put(Tree::entry_base + own::kEntryGlyphs, vector); t.Reject();
  }
  Tree duplicate(1, 1, 2);
  duplicate.PutVector(Tree::entry_base + own::kEntryStride + own::kEntryGlyphs,
                      Tree::glyph_base, 5, own::kGlyphStride);
  duplicate.Reject();
  Tree alias; alias.memory.Put(Tree::manager_slot, Tree::manager + 4); alias.Reject();
}
}  // namespace
int main() {
  TestStructure(); TestLiveMembership(); TestStalePathsAndFaults();
  TestBudgetsAndInvalidVectors();
  TestRenderGate();
  std::puts("Legacy Siglus ownership: structural bridge, bounded traversal and live path checks passed");
}
