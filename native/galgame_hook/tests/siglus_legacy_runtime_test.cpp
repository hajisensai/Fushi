#ifdef NDEBUG
#undef NDEBUG
#endif
#include "siglus_legacy_runtime.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <vector>

namespace rt = fushi_voice_hook::siglus_legacy_runtime;
namespace sites = fushi_voice_hook::siglus_legacy_input_viewport;
namespace {
size_t checks = 0;
void Check(bool ok) {
  ++checks;
  assert(ok);
}

struct Memory {
  std::map<uint32_t, uint8_t> bytes;
  std::vector<std::pair<uint32_t, size_t>> requests;
  size_t fail_at = 0;
  size_t mutate_at = 0;
  uint32_t mutate_address = 0;
  uint8_t mutate_value = 0;
  uint32_t base = 0x400000;
  uint32_t config = 0x10000000;
  uint32_t owner = config + sites::kConfigOwner;
  uint32_t auxiliary = 0x12000000;
  sites::Sites resolved{};
  Memory(uint32_t module = 0x400000, uint32_t object = 0x10000000)
      : base(module), config(object), owner(object + sites::kConfigOwner) {
    resolved.config_slot = 0x1000;
    resolved.owner_slot = 0x1004;
    resolved.window_slot = 0x1008;
    resolved.input_slot = 0x100c;
    resolved.modal_slot = 0x1010;
    resolved.hidden_slot = 0x1014;
    resolved.auxiliary_visibility_slot = 0x1018;
    resolved.main_message_handler = 0x3000;
    Put(base + 0x1000, config);
    Put(base + 0x1004, owner);
    Put(base + 0x1008, owner + sites::kOwnerWindow);
    Put(base + 0x100c, owner + sites::kOwnerInput);
    Put(base + 0x1010, owner + sites::kOwnerModal);
    Put(base + 0x1014, owner + sites::kOwnerHidden);
    Put(base + 0x1018, auxiliary);
    Put(owner + sites::kOwnerWindow, base + 0x8000);
    Put(owner + sites::kOwnerWindow + 4, uint32_t{0x12345});
    Put(base + 0x8004, base + 0x3000);
    Design(1280, 720);
    View(0, 0, 1280, 720);
    for (const uint32_t flag : Flags()) Put(flag, uint8_t{0});
  }
  std::array<uint32_t, 4> Flags() const {
    return {owner + sites::kOwnerModal + sites::kModalByte,
            owner + sites::kOwnerHidden + sites::kHiddenByte,
            owner + sites::kOwnerLogByte, auxiliary + 0x5c};
  }
  template <typename T>
  void Put(uint32_t address, T value) {
    const auto* p = reinterpret_cast<const uint8_t*>(&value);
    for (size_t i = 0; i < sizeof(T); ++i)
      bytes[address + static_cast<uint32_t>(i)] = p[i];
  }
  void Design(int32_t width, int32_t height) {
    Put(config + sites::kConfigWidth, width);
    Put(config + sites::kConfigHeight, height);
    Put(owner + sites::kOwnerDesignWidth, width);
    Put(owner + sites::kOwnerDesignHeight, height);
  }
  void View(int32_t x, int32_t y, int32_t width, int32_t height) {
    Put(owner + sites::kOwnerViewportX, x);
    Put(owner + sites::kOwnerViewportY, y);
    Put(owner + sites::kOwnerViewportWidth, width);
    Put(owner + sites::kOwnerViewportHeight, height);
  }
  static bool Read(void* context, uint32_t address, void* output, size_t size) {
    auto& m = *static_cast<Memory*>(context);
    m.requests.emplace_back(address, size);
    if (m.requests.size() == m.mutate_at)
      m.Put(m.mutate_address, m.mutate_value);
    if (m.requests.size() == m.fail_at) {
      std::memset(output, 0xff,
                  size);  // partial/failing callback is not success
      return false;
    }
    auto* p = static_cast<uint8_t*>(output);
    for (size_t i = 0; i < size; ++i) {
      const auto at = m.bytes.find(address + static_cast<uint32_t>(i));
      if (at == m.bytes.end()) return false;
      p[i] = at->second;
    }
    return true;
  }
  bool Snapshot(rt::Snapshot* result) {
    requests.clear();
    return rt::ReadSnapshot(base, resolved, Read, this, result);
  }
};

void Cleared(const rt::Snapshot& s) {
  Check(!s.structure_valid && !s.dialogue_input_allowed && s.owner == 0 &&
        s.window_handle == 0 && s.design_width == 0 && s.viewport.width == 0 &&
        s.blocked_flags == std::array<uint8_t, 4>{});
}

void ValidAndRebased() {
  for (const uint32_t base : {0x400000u, 0x70000000u}) {
    for (const uint32_t object : {0x10000000u, 0x60000000u}) {
      Memory m(base, object);
      rt::Snapshot s;
      Check(m.Snapshot(&s));
      Check(s.structure_valid && s.dialogue_input_allowed);
      Check(s.config == object && s.owner == m.owner &&
            s.window == m.owner + sites::kOwnerWindow &&
            s.window_handle == 0x12345 && s.viewport.width == 1280);
      Check(m.requests.size() == 44);
      for (const auto& request : m.requests)
        Check(request.second == 1 || request.second == 4);
    }
  }
}

void EveryReadFailureAndStateDrift() {
  for (size_t call = 1; call <= 44; ++call) {
    Memory m;
    rt::Snapshot s;
    Check(m.Snapshot(&s));
    m.fail_at = call;
    Check(!m.Snapshot(&s));
    Cleared(s);
    Check(m.requests.size() == call);  // no retry or continuation after failure
  }
  for (size_t flag = 0; flag < 4; ++flag) {
    Memory m;
    rt::Snapshot s;
    m.mutate_at = 23;
    m.mutate_address = m.Flags()[flag];
    m.mutate_value = 1;
    Check(!m.Snapshot(&s));
    Cleared(s);
    Check(m.requests.size() == 44);
  }
  for (const uint32_t field :
       {0x1000u, 0x1004u, 0x1008u, 0x100cu, 0x1010u, 0x1014u, 0x1018u}) {
    Memory m;
    rt::Snapshot s;
    m.mutate_at = 23;
    m.mutate_address = m.base + field;
    m.mutate_value = 3;
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  Memory m;
  rt::Snapshot s;
  m.mutate_at = 23;
  m.mutate_address = m.owner + sites::kOwnerViewportWidth;
  m.mutate_value = 1;  // both values individually valid, but not one snapshot
  Check(!m.Snapshot(&s));
  Cleared(s);
  Memory window;
  rt::Snapshot changed_window;
  window.mutate_at = 23;
  window.mutate_address = window.owner + sites::kOwnerWindow + 4;
  window.mutate_value = 0x46;  // another nonzero opaque HWND
  Check(!window.Snapshot(&changed_window));
  Cleared(changed_window);
}

void FlagsAreCurrentAndSeparateFromValidity() {
  for (size_t flag = 0; flag < 4; ++flag) {
    for (const uint8_t blocked : {uint8_t{1}, uint8_t{0xff}}) {
      Memory m;
      rt::Snapshot s;
      Check(m.Snapshot(&s));
      Check(s.dialogue_input_allowed);
      m.Put(m.Flags()[flag], blocked);
      Check(m.Snapshot(&s));
      Check(s.structure_valid && !s.dialogue_input_allowed &&
            s.blocked_flags[flag] == blocked);
      m.Put(m.Flags()[flag], uint8_t{0});
      Check(m.Snapshot(&s));
      Check(s.dialogue_input_allowed);
    }
  }
}

void BadIdentities() {
  for (const uint32_t offset :
       {0x1000u, 0x1004u, 0x1008u, 0x100cu, 0x1010u, 0x1014u, 0x1018u}) {
    for (const uint32_t pointer : {0u, 3u, 0xfffffffcu, 0x18000000u}) {
      Memory m;
      rt::Snapshot s;
      m.Put(m.base + offset, pointer);
      Check(!m.Snapshot(&s));
      Cleared(s);
    }
  }
  {
    Memory m;
    rt::Snapshot s;
    m.Put(m.base + 0x1000, 0xfff00000u);
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  for (const uint32_t vtable : {0u, 1u, 0xfffffffcu, 0x18000000u}) {
    Memory m;
    rt::Snapshot s;
    m.Put(m.owner + sites::kOwnerWindow, vtable);
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  {
    Memory m;
    rt::Snapshot s;
    m.Put(m.base + 0x8004, m.base + 0x3001);
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  {
    Memory m;
    rt::Snapshot s;
    m.Put(m.owner + sites::kOwnerWindow + 4, uint32_t{0});
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  {
    Memory m;
    rt::Snapshot s;
    m.resolved.config_slot = 0;
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  {
    Memory m;
    rt::Snapshot s;
    m.resolved.config_slot = 0xfffffffcu;
    Check(!m.Snapshot(&s));
    Cleared(s);
    Check(m.requests.empty());
  }
  {
    Memory m;
    rt::Snapshot s;
    m.resolved.main_message_handler = 0xfffffffcu;
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  {
    Memory m;
    rt::Snapshot s;
    m.base = 0x400001;
    Check(!m.Snapshot(&s));
    Cleared(s);
    Check(m.requests.empty());
  }
  {
    Memory m;
    rt::Snapshot s;
    Check(m.Snapshot(&s));
    Check(!rt::ReadSnapshot(m.base, m.resolved, nullptr, &m, &s));
    Cleared(s);
  }
  Check(!rt::ReadSnapshot(0, {}, Memory::Read, nullptr, nullptr));
  if constexpr (sizeof(uintptr_t) > 4) {
    Memory m;
    rt::Snapshot s;
    Check(!rt::ReadSnapshot(static_cast<uintptr_t>(UINT64_C(0x100000000)),
                            m.resolved, Memory::Read, &m, &s));
    Cleared(s);
  }
}

void DimensionsAndViewport() {
  for (const int32_t dimension : {256, 16384}) {
    Memory m;
    rt::Snapshot s;
    m.Design(dimension, dimension);
    Check(m.Snapshot(&s));
    Check(s.design_width == dimension);
  }
  for (const int32_t dimension : {-1, 0, 255, 16385, INT32_MAX}) {
    Memory m;
    rt::Snapshot s;
    m.Design(dimension, 720);
    Check(!m.Snapshot(&s));
    Cleared(s);
    m.Design(1280, dimension);
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  {
    Memory m;
    rt::Snapshot s;
    m.Put(m.owner + sites::kOwnerDesignWidth, 1920);
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  {
    Memory m;
    rt::Snapshot s;
    m.Put(m.owner + sites::kOwnerDesignHeight, 1080);
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
  for (const auto& viewport :
       {rt::Viewport{-120, -80, 1600, 900}, rt::Viewport{200, 100, 1, 1},
        rt::Viewport{INT32_MIN, INT32_MIN, 1, 1},
        rt::Viewport{0, 0, INT32_MAX, INT32_MAX}}) {
    Memory m;
    rt::Snapshot s;
    m.View(viewport.x, viewport.y, viewport.width, viewport.height);
    Check(m.Snapshot(&s));
    Check(s.viewport.x == viewport.x && s.viewport.width == viewport.width);
  }
  for (const auto& viewport :
       {rt::Viewport{0, 0, 0, 1}, rt::Viewport{0, 0, 1, 0},
        rt::Viewport{0, 0, -1, 1}, rt::Viewport{0, 0, 1, -1},
        rt::Viewport{INT32_MAX, 0, 1, 1}, rt::Viewport{0, INT32_MAX, 1, 1}}) {
    Memory m;
    rt::Snapshot s;
    m.View(viewport.x, viewport.y, viewport.width, viewport.height);
    Check(!m.Snapshot(&s));
    Cleared(s);
  }
}
}  // namespace
int main() {
  ValidAndRebased();
  EveryReadFailureAndStateDrift();
  FlagsAreCurrentAndSeparateFromValidity();
  BadIdentities();
  DimensionsAndViewport();
  std::printf("legacy runtime snapshot: %zu checks passed\n", checks);
}
