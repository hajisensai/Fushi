#ifdef NDEBUG
#undef NDEBUG
#endif
#include <windows.h>
#include "siglus_ninearg_runtime.h"
#include "siglus_glyph_record.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <vector>

// Fake address space only: the nine-argument live snapshot, its owner walk and
// the integer glyph decode are checked against the documented aliases.
namespace {
namespace rt = fushi_voice_hook::siglus_ninearg_runtime;
namespace own = fushi_voice_hook::siglus_ninearg_owner;
namespace na = fushi_voice_hook::siglus_ninearg;
using fushi_voice_hook::SiglusGlyphRecord;
size_t checks = 0;
void Check(bool ok) {
  ++checks;
  assert(ok);
}

struct Memory {
  std::map<uint32_t, uint8_t> bytes;
  size_t reads = 0, fail_at = 0, mutate_at = 0;
  uint32_t mutate_address = 0;
  uint8_t mutate_value = 0;
  uint32_t base, config, owner;
  na::Sites sites{};
  explicit Memory(uint32_t module = 0x400000, uint32_t object = 0x10000000)
      : base(module), config(object), owner(object + na::kConfigOwner) {
    sites.config_slot = 0x1000; sites.owner_slot = 0x1004;
    sites.window_slot = 0x1008; sites.input_slot = 0x100c;
    sites.modal_slot = 0x1010; sites.hidden_slot = 0x1014;
    sites.auxiliary_slot = 0x1018; sites.main_message_handler = 0x3000;
    Put(base + 0x1000, config);
    Put(base + 0x1004, owner);
    Put(base + 0x1008, owner + na::kOwnerWindow);
    Put(base + 0x100c, owner + na::kOwnerInput);
    Put(base + 0x1010, owner + na::kOwnerModal);
    Put(base + 0x1014, owner + na::kOwnerHidden);
    Put(base + 0x1018, owner + na::kOwnerAuxiliary);
    Put(owner + na::kOwnerWindow, base + 0x8000);
    Put(owner + na::kOwnerWindow + 4, uint32_t{0x12345});
    Put(base + 0x8004, base + 0x3000);
    Design(1280, 720);
    View(0, 0, 1920, 1080);
    for (const uint32_t flag : Flags()) Put(flag, uint8_t{0});
  }
  std::array<uint32_t, 4> Flags() const {
    return {owner + na::kOwnerModal + na::kModalByte,
            owner + na::kOwnerHidden + na::kHiddenByte,
            owner + na::kOwnerAuxiliary + na::kAuxiliaryByte,
            owner + na::kOwnerGateByte};
  }
  template <typename T>
  void Put(uint32_t address, T value) {
    const auto* p = reinterpret_cast<const uint8_t*>(&value);
    for (size_t i = 0; i < sizeof(T); ++i)
      bytes[address + static_cast<uint32_t>(i)] = p[i];
  }
  void Design(int32_t width, int32_t height) {
    Put(config + na::kConfigWidth, width);
    Put(config + na::kConfigHeight, height);
    Put(owner + na::kOwnerDesignWidth, width);
    Put(owner + na::kOwnerDesignHeight, height);
  }
  void View(int32_t x, int32_t y, int32_t width, int32_t height) {
    Put(owner + na::kOwnerViewportX, x);
    Put(owner + na::kOwnerViewportY, y);
    Put(owner + na::kOwnerViewportWidth, width);
    Put(owner + na::kOwnerViewportHeight, height);
  }
  bool Get(uint32_t address, void* output, size_t size) {
    ++reads;
    if (reads == mutate_at) Put(mutate_address, mutate_value);
    if (reads == fail_at) return false;
    auto* p = static_cast<uint8_t*>(output);
    for (size_t i = 0; i < size; ++i) {
      const auto at = bytes.find(address + static_cast<uint32_t>(i));
      if (at == bytes.end()) return false;
      p[i] = at->second;
    }
    return true;
  }
  static bool Read(void* context, uint32_t address, void* output, size_t size) {
    return static_cast<Memory*>(context)->Get(address, output, size);
  }
  bool Snapshot(rt::Snapshot* result) {
    reads = 0;
    return rt::ReadSnapshot(base, sites, Read, this, result);
  }
  bool operator()(uint32_t address, void* output, size_t size) {
    return Get(address, output, size);
  }
};

void Cleared(const rt::Snapshot& s) {
  Check(!s.structure_valid && !s.dialogue_input_allowed && s.owner == 0 &&
        s.window_handle == 0 && s.design_width == 0 && s.viewport.width == 0);
}

void TestValidAndRebased() {
  for (const uint32_t base : {0x400000u, 0x70000000u}) {
    for (const uint32_t object : {0x10000000u, 0x50000000u}) {
      Memory m(base, object);
      rt::Snapshot s;
      Check(m.Snapshot(&s));
      Check(s.structure_valid && s.dialogue_input_allowed);
      Check(s.config == object && s.owner == m.owner &&
            s.window == m.owner + na::kOwnerWindow &&
            s.auxiliary == m.owner + na::kOwnerAuxiliary &&
            s.window_handle == 0x12345 && s.design_width == 1280 &&
            s.design_height == 720 && s.viewport.width == 1920 &&
            s.viewport.height == 1080);
    }
  }
}

void TestEveryReadFailureAndDrift() {
  Memory probe;
  rt::Snapshot s;
  Check(probe.Snapshot(&s));
  const size_t total = probe.reads;
  Check(total % 2 == 0);  // Two identical complete passes.
  for (size_t call = 1; call <= total; ++call) {
    Memory m;
    m.fail_at = call;
    Check(!m.Snapshot(&s));
    Cleared(s);
    Check(m.reads == call);  // No retry after a failed read.
  }
  // A flag that flips between the two passes rejects the mixed snapshot.
  for (const uint32_t flag : Memory{}.Flags()) {
    Memory m;
    m.mutate_at = total / 2 + 1;
    m.mutate_address = flag;
    m.mutate_value = 1;
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
}

void TestBlockedFlags() {
  for (size_t n = 0; n < 4; ++n) {
    Memory m;
    m.Put(m.Flags()[n], uint8_t{1});
    rt::Snapshot s;
    Check(m.Snapshot(&s));
    Check(s.structure_valid && !s.dialogue_input_allowed && s.blocked_flags[n] == 1);
  }
}

void TestAliasesAndLayout() {
  for (unsigned n = 0; n < 14; ++n) {
    Memory m;
    switch (n) {
      case 0: m.Put(m.base + 0x1004, m.owner + 4); break;
      case 1: m.Put(m.base + 0x1008, m.owner + 4); break;
      case 2: m.Put(m.base + 0x100c, m.owner + na::kOwnerModal); break;
      case 3: m.Put(m.base + 0x1010, m.owner + na::kOwnerHidden); break;
      case 4: m.Put(m.base + 0x1014, m.owner + na::kOwnerModal); break;
      case 5: m.Put(m.base + 0x1018, uint32_t{0x12000000}); break;
      case 6: m.Put(m.base + 0x8004, m.base + 0x3004); break;  // Foreign window class.
      case 7: m.Put(m.owner + na::kOwnerWindow + 4, uint32_t{0}); break;
      case 8: m.Put(m.owner + na::kOwnerDesignWidth, int32_t{1281}); break;
      case 9: m.Design(200, 720); break;
      case 10: m.View(0, 0, 0, 1080); break;
      case 11: m.View(0x7fffff00, 0, 1920, 1080); break;
      case 12: m.Put(m.owner + na::kOwnerWindow, m.base + 0x8001); break;
      case 13: m.sites.main_message_handler = 0; break;
    }
    rt::Snapshot s;
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  Memory m;
  rt::Snapshot s;
  Check(!rt::ReadSnapshot(m.base, m.sites, nullptr, &m, &s));
  Check(!rt::ReadSnapshot(0x400001, m.sites, Memory::Read, &m, &s));
  Check(!rt::ReadSnapshot(m.base, m.sites, Memory::Read, &m, nullptr));
}

// Owner chain: groups -> render owners -> dialogue entries -> glyph vectors.
struct Chain : Memory {
  uint32_t groups = 0x20000000, owners = 0x21000000, entries = 0x22000000;
  uint32_t glyphs = 0x23000000;
  Chain() {
    Vec(owner + na::kOwnerGroups, groups, 3, na::kGroupStride);
    for (uint32_t g = 0; g < 3; ++g)
      Vec(groups + g * na::kGroupStride + na::kGroupOwners,
          g == 1 ? owners : 0, g == 1 ? 1 : 0, na::kOwnerStride);
    Vec(owners + na::kOwnerEntries, entries, 2, na::kEntryStride);
    Vec(entries + na::kEntryGlyphs, glyphs, 8, na::kGlyphStride);
    Vec(entries + na::kEntryStride + na::kEntryGlyphs, 0, 0, na::kGlyphStride);
  }
  void Vec(uint32_t at, uint32_t begin, uint32_t count, uint32_t stride) {
    Put(at, begin);
    Put(at + 4, begin + count * stride);
    Put(at + 8, begin + count * stride);
  }
  uint32_t Slot(uintptr_t rva) const { return base + static_cast<uint32_t>(rva); }
  bool Build(own::Snapshot* out) {
    return own::BuildSnapshot(Slot(sites.config_slot), Slot(sites.owner_slot),
                              *this, out);
  }
};

void TestOwnerWalk() {
  Chain c;
  own::Snapshot s;
  Check(c.Build(&s) && s.count == 1 && s.paths[0].owner == c.owners &&
        s.paths[0].entry == c.entries);
  for (uint32_t i = 0; i < 8; ++i)
    Check(own::ContainsCurrentGlyph(s, c.glyphs + i * na::kGlyphStride, c));
  Check(!own::ContainsCurrentGlyph(s, c.glyphs + 4, c));            // Misaligned.
  Check(!own::ContainsCurrentGlyph(s, c.glyphs + 8 * na::kGlyphStride, c));
  Check(!own::ContainsCurrentGlyph(s, 0, c));
  // A vector replaced after the snapshot no longer owns its glyphs.
  c.Vec(c.entries + na::kEntryGlyphs, c.glyphs, 7, na::kGlyphStride);
  Check(!own::ContainsCurrentGlyph(s, c.glyphs, c));
  {Chain d; own::Snapshot t; Check(d.Build(&t));
    d.Put(d.Slot(d.sites.owner_slot), d.owner + 4);   // Root changed.
    Check(!own::ContainsCurrentGlyph(t, d.glyphs, d));}
  {Chain d; own::Snapshot t;
    d.Vec(d.owner + na::kOwnerGroups, d.groups + 1, 3, na::kGroupStride);
    Check(!d.Build(&t) && t.count == 0);}                 // Misaligned vector.
  {Chain d; own::Snapshot t;
    d.Vec(d.owners + na::kOwnerEntries, d.entries, 2, na::kEntryStride + 4);
    Check(!d.Build(&t));}                                 // Wrong entry stride.
  {Chain d; own::Snapshot t;
    // Two entries sharing one glyph range are an ambiguous owner, not two.
    d.Vec(d.entries + na::kEntryStride + na::kEntryGlyphs, d.glyphs, 2, na::kGlyphStride);
    Check(!d.Build(&t));}
  {Chain d; own::Snapshot t;
    d.Vec(d.entries + na::kEntryGlyphs, 0, 0, na::kGlyphStride);
    Check(!d.Build(&t));}                                 // No glyphs: no snapshot.
  {Chain d; own::Snapshot t; d.fail_at = 9; Check(!d.Build(&t) && t.count == 0);}
  {Chain d; own::Snapshot t;
    d.Put(d.Slot(d.sites.owner_slot), d.owner + 4); Check(!d.Build(&t));}
}

void TestNineArgDecode() {
  uint8_t record[na::kGlyphRecordBytes] = {};
  const auto put = [&](size_t at, auto value) { std::memcpy(record + at, &value, sizeof(value)); };
  put(4, uint32_t{0x3042}); put(8, int32_t{30}); put(0x14, int32_t{60}); put(0x18, int32_t{0});
  SiglusGlyphRecord g;
  using fushi_voice_hook::DecodeSiglusNineArgGlyphRecord;
  Check(DecodeSiglusNineArgGlyphRecord(record, sizeof(record), 180, 520, 1280, 720, &g) &&
        g.code_unit == 0x3042 && g.x == 240 && g.y == 520 && g.extent == 30);
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record) - 1, 180, 520, 1280, 720, &g));
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record), 1220, 520, 1280, 720, &g));
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record), -61, 520, 1280, 720, &g));
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record), 0x7fffffff, 520, 1280, 720, &g));
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record), 180, 720, 1280, 720, &g));
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record), 180, 520, 0, 720, &g));
  Check(!DecodeSiglusNineArgGlyphRecord(nullptr, sizeof(record), 180, 520, 1280, 720, &g));
  put(4, uint32_t{0x10000});
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record), 180, 520, 1280, 720, &g));
  put(4, uint32_t{0x3042}); put(8, int32_t{0});
  Check(!DecodeSiglusNineArgGlyphRecord(record, sizeof(record), 180, 520, 1280, 720, &g));
  // The generic decoder never guesses an origin for this ABI.
  put(8, int32_t{30});
  Check(!fushi_voice_hook::DecodeSiglusGlyphRecord(
      fushi_voice_hook::SiglusGlyphLayoutAbi::kStackNineArguments, record,
      sizeof(record), 1280, 720, &g));
}
}  // namespace

int main() {
  TestValidAndRebased();
  TestEveryReadFailureAndDrift();
  TestBlockedFlags();
  TestAliasesAndLayout();
  TestOwnerWalk();
  TestNineArgDecode();
  std::printf("Siglus nine-argument runtime: %zu checks passed\n", checks);
  return 0;
}
