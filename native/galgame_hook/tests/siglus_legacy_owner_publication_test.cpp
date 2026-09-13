#undef NDEBUG
#include "siglus_legacy_owner.h"

#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

namespace own = fushi_voice_hook::siglus_legacy_owner;
namespace {
void Check(bool value) {
  if (!value) { std::fputs("Owner publication regression failed\n", stderr); std::exit(1); }
}

struct Tree {
  std::map<uint32_t, std::vector<uint8_t>> memory;
  static constexpr uint32_t config_slot = 0x10000, manager_slot = 0x10004;
  static constexpr uint32_t config = 0x100000;
  static constexpr uint32_t manager = config + own::input::kConfigOwner;
  static constexpr uint32_t group = 0x200000, owner = 0x300000;
  static constexpr uint32_t entry = 0x400000, glyph = 0x500000;
  uint32_t fault = 0;
  template <typename T> void Put(uint32_t at, T value) {
    auto& bytes = memory[at]; bytes.resize(sizeof(value));
    std::memcpy(bytes.data(), &value, sizeof(value));
  }
  Tree() {
    Put(config_slot, config); Put(manager_slot, manager);
    Put(manager + own::kManagerGroups,
        own::Vector{group, group + own::kGroupStride, group + own::kGroupStride});
    Put(group + own::kGroupOwners,
        own::Vector{owner, owner + own::kOwnerStride, owner + own::kOwnerStride});
    Put(owner + own::kOwnerEntries,
        own::Vector{entry, entry + own::kEntryStride, entry + own::kEntryStride});
    Put(entry + own::kEntryGlyphs,
        own::Vector{glyph, glyph + own::kGlyphStride, glyph + own::kGlyphStride});
  }
  bool operator()(uint32_t at, void* output, size_t bytes) {
    const auto it = memory.find(at);
    if (at == fault || it == memory.end() || it->second.size() != bytes) return false;
    std::memcpy(output, it->second.data(), bytes); return true;
  }
  bool Build(own::Snapshot* out) {
    return own::BuildSnapshot(config_slot, manager_slot, *this, out);
  }
};

struct Publication {
  SRWLOCK lock = SRWLOCK_INIT;
  unsigned attempts = 0, releases = 0;
  own::Snapshot published;
  bool Apply(const own::Snapshot& next, bool valid) {
    return own::PublishSnapshot(next, valid, &published,
        [&] { ++attempts; return TryAcquireSRWLockExclusive(&lock) != FALSE; },
        [&] { ++releases; ReleaseSRWLockExclusive(&lock); });
  }
};

void TestActualSharedLock() {
  Tree tree; own::Snapshot next; Check(tree.Build(&next));
  Publication p; Check(p.Apply(next, true));
  Check(p.attempts == 1 && p.releases == 1);
  AcquireSRWLockShared(&p.lock);
  // Prove the real Windows lock cannot be acquired exclusively now. The
  // production same-snapshot path must succeed without attempting that lock.
  Check(TryAcquireSRWLockExclusive(&p.lock) == FALSE);
  Check(p.Apply(next, true)); Check(p.attempts == 1 && p.releases == 1);
  auto changed = next; changed.paths[0].glyphs.capacity += own::kGlyphStride;
  Check(!p.Apply(changed, true)); Check(own::Same(p.published, next));
  Check(p.attempts == 2 && p.releases == 1);
  Check(!p.Apply({}, false)); Check(own::Same(p.published, next));
  Check(p.attempts == 3 && p.releases == 1);
  ReleaseSRWLockShared(&p.lock);
  Check(p.Apply(changed, true)); Check(own::Same(p.published, changed));
  Check(p.attempts == 4 && p.releases == 2);
  Check(!p.Apply(next, false)); Check(p.published.count == 0);
  Check(p.published.manager == 0 && p.published.paths[0].group == 0);
  Check(p.attempts == 5 && p.releases == 3);
}

void TestEveryIdentityField() {
  Tree tree; own::Snapshot base; Check(tree.Build(&base));
  uint32_t own::Snapshot::* const roots[] = {
      &own::Snapshot::config_slot, &own::Snapshot::manager_slot,
      &own::Snapshot::config, &own::Snapshot::manager};
  for (auto member : roots) {
    auto changed = base; ++(changed.*member); Check(!own::Same(base, changed));
  }
  uint32_t own::Vector::* const scalars[] = {
      &own::Vector::begin, &own::Vector::end, &own::Vector::capacity};
  for (auto member : scalars) {
    auto changed = base; ++(changed.groups.*member); Check(!own::Same(base, changed));
  }
  uint32_t own::Path::* const identities[] = {
      &own::Path::group, &own::Path::owner, &own::Path::entry};
  own::Vector own::Path::* const vectors[] = {
      &own::Path::owners, &own::Path::entries, &own::Path::glyphs};
  // Both first and later active paths must participate; unused array capacity
  // must not create a false metadata change.
  base.count = 2; base.paths[1] = base.paths[0];
  for (size_t i = 0; i < base.count; ++i) {
    for (auto member : identities) {
      auto changed = base; ++(changed.paths[i].*member); Check(!own::Same(base, changed));
    }
    for (auto vector : vectors) for (auto scalar : scalars) {
      auto changed = base; ++((changed.paths[i].*vector).*scalar);
      Check(!own::Same(base, changed));
    }
  }
  auto unused = base; unused.paths.back().group = 0x1234;
  Check(own::Same(base, unused));
  auto changed = base; changed.count = 1; Check(!own::Same(base, changed));
  changed.count = 0; Check(!own::Same(changed, changed));
  changed.count = own::kMaxPaths + 1; Check(!own::Same(changed, changed));
  unsigned attempts = 0;
  Check(!own::PublishSnapshot(base, true, nullptr,
      [&] { ++attempts; return true; }, [] {}));
  Check(attempts == 0);
}

void TestFailedLiveBuildRetiresSnapshot() {
  for (unsigned scenario = 0; scenario < 4; ++scenario) {
    Tree tree; own::Snapshot next; Check(tree.Build(&next));
    Publication p; Check(p.Apply(next, true));
    switch (scenario) {
      case 0: tree.fault = Tree::entry + own::kEntryGlyphs; break;
      case 1: tree.Put(Tree::entry + own::kEntryGlyphs,
          own::Vector{0xfffffff0, 0xffffffff, 0xffffffff}); break;
      case 2: tree.Put(Tree::manager + own::kManagerGroups,
          own::Vector{Tree::group, Tree::group + 65 * own::kGroupStride,
                      Tree::group + 65 * own::kGroupStride}); break;
      case 3: tree.Put(Tree::entry + own::kEntryGlyphs, own::Vector{}); break;
    }
    const bool valid = tree.Build(&next); Check(!valid && next.count == 0);
    Check(!p.Apply(next, valid));
    Check(p.published.count == 0 && p.published.manager == 0);
    Check(p.attempts == 2 && p.releases == 2);
  }
}
}  // namespace

int main() {
  TestActualSharedLock(); TestEveryIdentityField(); TestFailedLiveBuildRetiresSnapshot();
  std::puts("Siglus owner publication: real SRW contention, field identity and invalid live builds passed");
}
