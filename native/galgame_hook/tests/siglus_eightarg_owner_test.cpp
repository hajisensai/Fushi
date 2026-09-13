#undef NDEBUG
#include "siglus_eightarg_owner.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>

namespace {
namespace owner = fushi_voice_hook::siglus_eightarg_owner;
namespace message = fushi_voice_hook::siglus_eightarg_message;
unsigned checks = 0;
void Check(bool value) {
  ++checks;
  if (!value) { std::fprintf(stderr, "check %u failed\n", checks); std::exit(91); }
}
struct Memory {
  std::map<uint32_t, uint8_t> bytes;
  size_t reads = 0, fail = 0, mutate_at = 0;
  uint32_t mutate_address = 0, mutate_value = 0;
  template <typename T> void Put(uint32_t address, T value) {
    const auto* p = reinterpret_cast<const uint8_t*>(&value);
    for (size_t i = 0; i < sizeof(T); ++i) bytes[address + static_cast<uint32_t>(i)] = p[i];
  }
  static bool Read(void* context, uint32_t address, void* out, size_t size) {
    auto& m = *static_cast<Memory*>(context);
    ++m.reads;
    if (m.mutate_at == m.reads) m.Put(m.mutate_address, m.mutate_value);
    if (m.fail == m.reads) return false;
    for (size_t i = 0; i < size; ++i) {
      auto item = m.bytes.find(address + static_cast<uint32_t>(i));
      if (item == m.bytes.end()) return false;
      static_cast<uint8_t*>(out)[i] = item->second;
    }
    return true;
  }
};
constexpr uint32_t engine = 0x10000000, container = 0x20000000;
constexpr uint32_t group = container + 0x734, objects = 0x30000000;
constexpr uint32_t body = objects + 0x1630, surfaces = 0x40000000;
constexpr uint32_t surface = surfaces + 0x124, glyphs = 0x50000000;
const message::Owner frozen{body, 1, surfaces, surfaces + 2 * 0x124, surface};
Memory Seed() {
  Memory m;
  m.Put(engine + 0x4293c, container);
  m.Put(group + 0x3b8, objects);
  m.Put(group + 0x3bc, objects + 2u * 0x1630);
  m.Put(group + 0x3c0, objects + 3u * 0x1630);
  m.Put(body + 0x160, 1u);
  m.Put(body + 0x1a8, surfaces);
  m.Put(body + 0x1ac, surfaces + 2u * 0x124);
  m.Put(body + 0x156, uint8_t{1});
  m.Put(body + 0x18c, int32_t{-1});
  m.Put(surface + 0x118, glyphs);
  m.Put(surface + 0x11c, glyphs + 3u * 0x3b4);
  m.Put(surface + 0x120, glyphs + 4u * 0x3b4);
  return m;
}
bool Read(Memory& m, owner::Path* out) {
  return owner::ReadPath(engine, frozen, Memory::Read, &m, out);
}
}
int main() {
  auto m = Seed(); owner::Path p;
  Check(Read(m, &p));
  const size_t reads = m.reads;
  Check(reads > 0 && reads < 64);
  for (uint32_t i = 0; i < 3; ++i)
    Check(owner::ContainsCurrentGlyph(p, glyphs + i * 0x3b4, Memory::Read, &m));
  for (uint32_t bad : {0u, glyphs - 1, glyphs + 1, glyphs + 3u * 0x3b4})
    Check(!owner::ContainsCurrentGlyph(p, bad, Memory::Read, &m));
  for (size_t fail = 1; fail <= reads; ++fail) {
    m = Seed(); m.fail = fail; p = {}; p.engine_owner = 123;
    Check(!Read(m, &p)); Check(p.engine_owner == 0 && p.body.address == 0);
    Check(m.reads == fail);
  }
  const uint32_t changes[][2] = {
      {engine + 0x4293c, 0}, {engine + 0x4293c, UINT32_MAX - 4},
      {engine + 0x4293c, UINT32_MAX - 3},
      {group + 0x3b8, objects + 4}, {group + 0x3bc, objects + 1},
      {group + 0x3c0, objects}, {group + 0x3c0, objects + 257u * 0x1630},
      {body + 0x160, 0}, {body + 0x160, UINT32_MAX},
      {body + 0x1a8, surfaces + 4}, {body + 0x1ac, surfaces + 0x124},
      {surface + 0x118, glyphs + 4}, {surface + 0x11c, glyphs},
      {surface + 0x120, glyphs + 1025u * 0x3b4}};
  for (const auto& c : changes) {
    m = Seed(); m.Put(c[0], c[1]); Check(!Read(m, &p));
  }
  m = Seed(); m.Put(body + 0x156, uint8_t{0}); Check(!Read(m, &p));
  m.Put(body + 0x18c, int32_t{0}); Check(Read(m, &p)); // Exit animation still draws.
  m.Put(body + 0x18c, int32_t{1}); Check(Read(m, &p));
  m.Put(body + 0x18c, INT32_MIN); Check(!Read(m, &p));
  m.Put(body + 0x157, uint8_t{0xff}); Check(!Read(m, &p));
  m.Put(body + 0x156, uint8_t{1}); Check(Read(m, &p));
  m = Seed(); Check(Read(m, &p));
  m.Put(body + 0x160, 0u);
  Check(!owner::ContainsCurrentGlyph(p, glyphs, Memory::Read, &m));
  m = Seed(); m.mutate_at = reads / 2 + 1;
  m.mutate_address = surface + 0x120; m.mutate_value = glyphs + 5u * 0x3b4;
  Check(!Read(m, &p)); // Individually valid paths still cannot mix generations.
  for (uint32_t changed : {body + 0x156, body + 0x18c}) {
    m = Seed(); m.mutate_at = reads / 2 + 1;
    m.mutate_address = changed; m.mutate_value = 2;
    Check(!Read(m, &p));
  }
  m = Seed(); auto other = frozen; other.address = objects + 2 * 0x1630;
  Check(!owner::ReadPath(engine, other, Memory::Read, &m, &p));
  Check(!owner::ReadPath(engine, frozen, nullptr, &m, &p));
  Check(!owner::ReadPath(engine, frozen, Memory::Read, &m, nullptr));
  Check(!owner::ReadPath(UINT32_MAX - 3, frozen, Memory::Read, &m, &p));
  m = Seed();
  m.Put(surface + 0x11c, glyphs);
  m.Put(body + 0x156, uint8_t{0});
  Check(owner::ReadSelectedBody(engine, frozen, Memory::Read, &m, &p));
  Check(!Read(m, &p)); // A committed text need not have rendered yet.
  m.Put(body + 0x160, 0u);
  Check(!owner::ReadSelectedBody(engine, frozen, Memory::Read, &m, &p));
  std::printf("siglus_eightarg_owner: %u checks passed\n", checks);
}
