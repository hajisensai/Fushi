#include "siglus_eightarg_runtime.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <vector>

namespace {
namespace runtime = fushi_voice_hook::siglus_eightarg_runtime;
unsigned checks = 0;
void Check(bool condition, const char* why) {
  ++checks;
  if (!condition) { std::fprintf(stderr, "FAIL: %s (%u)\n", why, checks); std::exit(91); }
}
// Synthetic independently admitted sites. No game addresses or payloads.
struct Sites {
  uintptr_t root_slot = 0x1000, config_slot = 0x1004, owner_slot = 0x1008;
  uintptr_t window_slot = 0x100c, input_slot = 0x1010;
  uintptr_t current_input_slot = 0x1014, prior_input_slot = 0x1018;
  uintptr_t viewport_slot = 0x101c, gate2_slot = 0x1020;
  uintptr_t gate3_slot = 0x1024, manager_slot = 0x1028, scene_slot = 0x102c;
  uintptr_t window_vtable = 0x9000, window_handler = 0xa000;
};
constexpr uintptr_t Sites::* kSiteMembers[] = {
    &Sites::root_slot, &Sites::config_slot, &Sites::owner_slot,
    &Sites::window_slot, &Sites::input_slot, &Sites::current_input_slot,
    &Sites::prior_input_slot, &Sites::viewport_slot, &Sites::gate2_slot,
    &Sites::gate3_slot, &Sites::manager_slot, &Sites::scene_slot};
struct Access { uint32_t address; size_t size; };
struct Memory {
  std::map<uint32_t, uint8_t> bytes;
  std::vector<Access> reads;
  size_t fail_on = 0, change_on = 0;
  std::function<void()> change;
  template <typename T> void Put(uint32_t address, T value) {
    uint8_t data[sizeof(T)]; std::memcpy(data, &value, sizeof(T));
    for (size_t i = 0; i < sizeof(T); ++i) bytes[address + static_cast<uint32_t>(i)] = data[i];
  }
  static bool Read(void* context, uint32_t address, void* out, size_t size) {
    auto& m = *static_cast<Memory*>(context);
    m.reads.push_back({address, size});
    if (m.change_on == m.reads.size()) m.change();
    if (m.fail_on == m.reads.size()) return false;
    for (size_t i = 0; i < size; ++i) {
      const auto found = m.bytes.find(address + static_cast<uint32_t>(i));
      if (found == m.bytes.end()) return false;
      static_cast<uint8_t*>(out)[i] = found->second;
    }
    return true;
  }
};
struct Fixture {
  uint32_t base = 0x400000, root = 0x2000000;
  Sites sites;
  Memory memory;
  uint32_t owner() const { return root + 0xa476b0; }
  uint32_t config() const { return root + 0x54; }
  uint32_t window() const { return owner() + 0x178; }
  uint32_t Gate(size_t n) const {
    const uint32_t offsets[] = {0x3cca0 + 0xb4, 0x3d124 + 2, 0x4296c + 0x138};
    return owner() + offsets[n];
  }
  Fixture() { Populate(); }
  void Populate() {
    const uint32_t pointers[] = {root, config(), owner(), window(),
        owner() + 0x35ad4, owner() + 0x3939c, owner() + 0x3b000,
        owner() + 0x3cca0, owner() + 0x3d124, owner() + 0x4296c,
        owner() + 0x3d174, owner() + 0x42898};
    for (size_t n = 0; n < 12; ++n)
      memory.Put(base + static_cast<uint32_t>(sites.*kSiteMembers[n]), pointers[n]);
    memory.Put(window(), base + static_cast<uint32_t>(sites.window_vtable));
    memory.Put(base + static_cast<uint32_t>(sites.window_vtable) + 4,
               base + static_cast<uint32_t>(sites.window_handler));
    memory.Put(window() + 4, uint32_t{0x550012});
    memory.Put(config() + 0x64, int32_t{1280});
    memory.Put(config() + 0x68, int32_t{720});
    memory.Put(owner() + 0x3cca8, int32_t{1280});
    memory.Put(owner() + 0x3ccac, int32_t{720});
    memory.Put(owner() + 0x3ccb0, int32_t{37});
    memory.Put(owner() + 0x3ccb4, int32_t{-19});
    memory.Put(owner() + 0x3ccc0, int32_t{1537});
    memory.Put(owner() + 0x3ccc4, int32_t{913});
    for (size_t n = 0; n < 3; ++n) {
      // Only the proved byte is a gate: nonzero adjacent bytes are unrelated.
      memory.Put(Gate(n), uint32_t{0xffffff00});
    }
  }
  bool Read(runtime::Snapshot* out) {
    return runtime::ReadSnapshot(base, sites, &Memory::Read, &memory, out);
  }
  void Reject() {
    runtime::Snapshot out;
    out.input_allowed = true; out.root = 1; out.design_width = 1; out.blocked[2] = 9;
    Check(!Read(&out), "snapshot rejects invalid/drifting memory");
    const runtime::Snapshot empty;
    Check(!out.input_allowed && runtime::Identity(out) == runtime::Identity(empty),
          "failure clears every output field");
  }
};

void TestStableAndGates() {
  Fixture f; runtime::Snapshot out;
  Check(f.Read(&out) && out.input_allowed, "complete stable runtime");
  Check(out.root == f.root && out.config == f.config() && out.owner == f.owner(), "root aliases");
  Check(out.scene == f.owner() + 0x42898, "scene aliases the admitted engine owner member");
  Check(out.window_handle == 0x550012 && out.design_width == 1280 && out.design_height == 720,
        "design dimensions and HWND preserved");
  Check(out.viewport_x == 37 && out.viewport_y == -19 && out.viewport_width == 1537 &&
        out.viewport_height == 913, "actual offset viewport, not synthetic centering/scaling");
  for (size_t gate = 0; gate < 3; ++gate) {
    for (uint8_t blocked : {uint8_t{1}, uint8_t{0x80}, uint8_t{0xff}}) {
      Fixture b; b.memory.Put(b.Gate(gate), blocked);
      Check(b.Read(&out) && !out.input_allowed && out.blocked[gate] == blocked,
            "each stable byte gate blocks input without losing valid snapshot");
    }
  }
  for (size_t n = 0; n < 12; ++n) {
    Check(f.memory.reads[n].address == f.base + f.sites.*kSiteMembers[n] && f.memory.reads[n].size == 4,
          "all twelve resolved slots read at actual module base");
  }
}

void TestRelationsAndBounds() {
  for (const auto member : kSiteMembers) {
    for (uint32_t bad : {uint32_t{0}, uint32_t{0xfffc}, uint32_t{0x10001}, uint32_t{0xfffffffc}}) {
      Fixture f; f.memory.Put(f.base + static_cast<uint32_t>(f.sites.*member), bad); f.Reject();
    }
    { Fixture f; f.sites.*member = 0; f.Reject(); }
    { Fixture f; f.sites.*member = UINTPTR_MAX; f.Reject(); }
    // Aligned/readable but wrong member is still not the admitted root graph.
    Fixture f; const auto address = f.base + static_cast<uint32_t>(f.sites.*member);
    uint32_t original = 0; Check(Memory::Read(&f.memory, address, &original, 4), "fixture pointer");
    f.memory.Put(address, original + 4); f.Reject();
  }
  { Fixture f; f.memory.Put(f.window(), uint32_t{0x10000}); f.Reject(); }
  { Fixture f; f.memory.Put(f.base + 0x9004, uint32_t{0x10000}); f.Reject(); }
  { Fixture f; f.memory.Put(f.window() + 4, uint32_t{0}); f.Reject(); }
  for (const auto member : {&Sites::window_vtable, &Sites::window_handler}) {
    { Fixture f; f.sites.*member = 0; f.Reject(); }
    { Fixture f; f.sites.*member = UINTPTR_MAX; f.Reject(); }
  }
  for (uint32_t offset : {0x3cca8u, 0x3ccacu}) {
    Fixture f; f.memory.Put(f.owner() + offset, int32_t{721}); f.Reject();
  }
  for (int32_t size : {255, 16385, -1, 0}) {
    for (uint32_t offset : {0x64u, 0x68u}) {
      Fixture f; f.memory.Put(f.config() + offset, size); f.Reject();
    }
  }
  for (uint32_t offset : {0x3ccc0u, 0x3ccc4u}) {
    for (int32_t size : {0, -1}) {
      Fixture f; f.memory.Put(f.owner() + offset, size); f.Reject();
    }
  }
  for (uint32_t offset : {0x3ccb0u, 0x3ccb4u}) {
    Fixture f; f.memory.Put(f.owner() + offset, int32_t{INT32_MAX}); f.Reject();
  }
  for (int32_t size : {256, 16384}) {
    Fixture f; runtime::Snapshot out;
    f.memory.Put(f.config() + 0x64, size); f.memory.Put(f.config() + 0x68, size);
    f.memory.Put(f.owner() + 0x3cca8, size); f.memory.Put(f.owner() + 0x3ccac, size);
    Check(f.Read(&out) && out.design_width == size, "inclusive design bounds");
  }
}

void TestSecondPassAndFailures() {
  Fixture baseline; runtime::Snapshot out;
  Check(baseline.Read(&out), "baseline read trace");
  const auto trace = baseline.memory.reads;
  Check(trace.size() == 52, "two bounded passes, twenty-six scalars each");
  const size_t pass = trace.size() / 2;
  for (size_t n = 0; n < trace.size(); ++n) {
    Fixture f; f.memory.fail_on = n + 1; f.Reject();
    Check(f.memory.reads.size() == n + 1, "read failure is final, no retry");
  }
  for (size_t n = 0; n < pass; ++n) {
    Fixture f; f.memory.change_on = pass + 1;
    f.memory.change = [&] { f.memory.bytes[trace[n].address] ^= 4; };
    f.Reject();
  }
  // All individual fields remain valid after relocation; rejection therefore
  // requires comparing complete snapshots rather than just validating pass 2.
  { Fixture f; f.memory.change_on = pass + 1;
    f.memory.change = [&] { f.root += 0x100000; f.Populate(); }; f.Reject(); }
  // Scene is an independently resolved slot, not a recomputed address that
  // can silently ignore disagreement with the engine's live pointer table.
  { Fixture f; f.memory.Put(f.base + static_cast<uint32_t>(f.sites.scene_slot),
                            f.owner() + 0x4289c); f.Reject(); }
  { Fixture f; f.memory.change_on = pass + 1;
    f.memory.change = [&] {
      f.memory.Put(f.base + static_cast<uint32_t>(f.sites.scene_slot),
                   f.owner() + 0x4289c);
    }; f.Reject(); }
  // Both design sources agree in each pass, but a resize is not stable.
  { Fixture f; f.memory.change_on = pass + 1;
    f.memory.change = [&] { f.memory.Put(f.config() + 0x64, int32_t{1920});
                            f.memory.Put(f.owner() + 0x3cca8, int32_t{1920}); }; f.Reject(); }
  for (size_t n = 0; n < 3; ++n) {
    Fixture f; f.memory.Put(f.Gate(n), uint8_t{1}); f.memory.change_on = pass + 1;
    f.memory.change = [&] { f.memory.Put(f.Gate(n), uint8_t{0}); }; f.Reject();
  }
}

void TestAddressArithmetic() {
  uint32_t address = 0;
  Check(runtime::Add(UINT32_MAX, 0, &address) && address == UINT32_MAX, "last byte address");
  Check(!runtime::Add(UINT32_MAX, 1, &address), "32-bit addition overflow");
  Check(!runtime::Add(0, 0, &address) && !runtime::Add(1, 0, nullptr), "missing address inputs");
  Memory m; m.Put(UINT32_MAX, uint8_t{0x80}); m.Put(UINT32_MAX - 3, uint32_t{0x80000001});
  uint32_t word = 0; uint8_t byte = 0;
  Check(runtime::Scalar(&Memory::Read, &m, UINT32_MAX - 3, 0, &word) && word == 0x80000001,
        "DWORD exact fit at address limit");
  Check(runtime::Scalar(&Memory::Read, &m, UINT32_MAX, 0, &byte) && byte == 0x80,
        "byte exact fit at address limit");
  const auto reads = m.reads.size();
  Check(!runtime::Scalar(&Memory::Read, &m, UINT32_MAX - 2, 0, &word), "DWORD overflow");
  Check(!runtime::Scalar(&Memory::Read, &m, 0x10001, 0, &word), "unaligned DWORD");
  Check(m.reads.size() == reads, "invalid addresses never reach memory reader");
  for (uintptr_t base : {uintptr_t{0}, uintptr_t{3}, uintptr_t{UINT32_MAX}}) {
    Fixture f; f.base = static_cast<uint32_t>(base); f.Reject();
  }
  Fixture f; runtime::Snapshot out; out.root = 7;
  Check(!runtime::ReadSnapshot(f.base, f.sites, nullptr, &f.memory, &out) && out.root == 0,
        "missing reader clears output");
  Check(!runtime::ReadSnapshot(f.base, f.sites, &Memory::Read, &f.memory, nullptr), "null output");
  if constexpr (sizeof(uintptr_t) > 4) {
    const auto high = static_cast<uintptr_t>(UINT32_MAX) + uintptr_t{1};
    Check(!runtime::Add(high, 0, &address), "host pointer cannot exceed target address width");
    Check(!runtime::ReadSnapshot(high, f.sites, &Memory::Read, &f.memory, &out), "64-bit host base rejected");
  }
}
}  // namespace

int main() {
  TestStableAndGates(); TestRelationsAndBounds();
  TestSecondPassAndFailures(); TestAddressArithmetic();
  std::printf("siglus_eightarg_runtime_test: PASS (%u checks)\n", checks);
}
