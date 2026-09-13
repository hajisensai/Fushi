#ifdef NDEBUG
#undef NDEBUG
#endif
#include "siglus_legacy_input_viewport.h"

#include <cassert>
#include <cstdio>
#include <fstream>
#include <vector>
namespace v = fushi_voice_hook::siglus_legacy_input_viewport;
namespace ex = fushi_voice_hook::exact_lookup;
namespace {
size_t checks = 0;
void Check(bool ok) {
  ++checks;
  assert(ok);
}
struct Fixture {
  std::vector<uint8_t> data = std::vector<uint8_t>(0x8000);
  ex::LoadedPeImage image{};
  v::Imports imports{0x6200, 0x6204, 0x6208, 0x620c};
  static constexpr uint32_t kBase = 0x400000;
  Fixture() {
    image.base = data.data();
    image.absolute_base = kBase;
    image.size = data.size();
    image.machine = IMAGE_FILE_MACHINE_I386;
    image.pointer_bits = 32;
    image.section_count = 3;
    image.sections[0] = {data.data() + 0x400, 0x4c00, 0x400,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {data.data() + 0x5000, 0x1000, 0x5000,
                         IMAGE_SCN_MEM_READ};
    image.sections[2] = {data.data() + 0x6000, 0x2000, 0x6000,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
    Put(0x400, v::kSampler.pattern());
    Put(0x800, v::kMessage.pattern());
    Put(0xa00, v::kMainCall.pattern());
    Put(0xc00, v::kNormalize.pattern());
    Put(0x1000, v::kDesign.pattern());
    Put(0x1400, v::kOwner.pattern());
    Put(0x1800, v::kVisibility.pattern());
    Abs(0x407, 0x6210);
    Abs(0x418, 0x6000);
    Abs(0x42e, 0x6204);
    Rel(0x456, 0x4000);
    Abs(0x45f, 0x6208);
    Abs(0x46e, 0x6200);
    Rel(0x573, 0x4000);
    Rel(0x5cb, 0x4000);
    Abs(0x803, 0x6000);
    Abs(0x828, 0x5100);
    Rel(0x833, 0x4000);
    Rel(0x843, 0x4000);
    Abs(0x888, 0x5118);
    Rel(0x893, 0x4000);
    Rel(0x8a3, 0x4000);
    Rel(0x8b3, 0x4000);
    Rel(0x8c5, 0x4000);
    Rel(0xa16, 0x800);
    Abs(0xc01, 0x6000);
    Rel(0xc13, 0x4000);
    Rel(0xc1b, 0x400);
    Rel(0xc22, 0x4000);
    Rel(0xc29, 0x4000);
    Abs(0xc2e, 0x6000);
    Abs(0xc3d, 0x6004);
    Abs(0xc50, 0x620c);
    Abs(0xc5a, 0x6000);
    Abs(0x1001, 0x6010);
    Abs(0x141a, 0x6010);
    Abs(0x1420, 0x6014);
    Abs(0x1426, 0x6018);
    Abs(0x142c, 0x601c);
    Abs(0x1801, 0x6020);
    Abs(0x1813, 0x6024);
    Abs(0x181f, 0x6028);
    Rel(0x182a, 0x4000);
    Put(0x2000, v::kAliases.pattern());
    Put(0x2800, v::kInputGate.pattern());
    Rel(0x2056, 0x4000);
    Rel(0x2067, 0x4000);
    Rel(0x2078, 0x4000);
    Rel(0x2089, 0x4000);
    Rel(0x20eb, 0x4000);
    Rel(0x211d, 0x4000);
    Rel(0x2135, 0x4000);
    Abs(0x213f, 0x5300);
    Rel(0x2150, 0x4000);
    Rel(0x2161, 0x4000);
    Abs(0x216b, 0x5300);
    Rel(0x2175, 0x4000);
    Rel(0x21c2, 0x4000);
    Rel(0x224a, 0x4000);
    Rel(0x2255, 0x4000);
    Rel(0x2260, 0x4000);
    Rel(0x226c, 0x4000);
    Rel(0x22bf, 0x4000);
    Rel(0x22d0, 0x4000);
    Abs(0x22da, 0x5300);
    Rel(0x22eb, 0x4000);
    Abs(0x22f5, 0x5300);
    Rel(0x2306, 0x4000);
    Abs(0x2310, 0x5300);
    Rel(0x2321, 0x4000);
    Rel(0x2332, 0x4000);
    Abs(0x233c, 0x5300);
    Rel(0x2353, 0x4000);
    Abs(0x235d, 0x5300);
    Rel(0x236e, 0x4000);
    Abs(0x2378, 0x5300);
    Rel(0x2389, 0x4000);
    Abs(0x2393, 0x5300);
    Rel(0x23bb, 0x4000);
    Rel(0x23cc, 0x4000);
    Rel(0x23f4, 0x4000);
    Rel(0x2405, 0x4000);
    Abs(0x240f, 0x5300);
    Rel(0x2420, 0x4000);
    Abs(0x242a, 0x5300);
    Rel(0x243b, 0x4000);
    Abs(0x2445, 0x5300);
    Rel(0x2456, 0x4000);
    Abs(0x2461, 0x6004);
    Abs(0x246c, 0x65b0);
    Abs(0x2477, 0x65b4);
    Abs(0x2482, 0x6000);
    Abs(0x248d, 0x65bc);
    Abs(0x2498, 0x65c0);
    Abs(0x24a3, 0x65c4);
    Abs(0x24ae, 0x65c8);
    Abs(0x24b9, 0x6030);
    Abs(0x24c4, 0x65d0);
    Abs(0x24cf, 0x65d4);
    Abs(0x24da, 0x65d8);
    Abs(0x24e5, 0x65dc);
    Abs(0x24f0, 0x65e0);
    Abs(0x24fb, 0x65e4);
    Abs(0x2506, 0x65e8);
    Abs(0x2511, 0x65ec);
    Abs(0x251c, 0x65f0);
    Abs(0x2527, 0x65f4);
    Abs(0x2532, 0x65f8);
    Abs(0x253d, 0x65fc);
    Abs(0x2548, 0x6600);
    Abs(0x2553, 0x6604);
    Abs(0x255e, 0x6608);
    Abs(0x2569, 0x660c);
    Abs(0x2574, 0x6610);
    Abs(0x257f, 0x6614);
    Abs(0x258a, 0x6618);
    Abs(0x2595, 0x661c);
    Abs(0x25a0, 0x6620);
    Abs(0x25ab, 0x6624);
    Abs(0x25b6, 0x6628);
    Abs(0x25c1, 0x662c);
    Abs(0x25cc, 0x6630);
    Abs(0x25e3, 0x6634);
    Abs(0x25ef, 0x6638);
    Abs(0x25f5, 0x6020);
    Abs(0x25fb, 0x6028);
    Rel(0x2825, 0x4000);
    Abs(0x283d, 0x6028);
    Abs(0x284d, 0x6030);
    constexpr uint32_t off[] = {0x2c, 0x3c, 0xc9, 0xc9, 0x2c, 0x3c, 0x8c, 0xc9,
                                0x9c, 0xac, 0xc9, 0xc9, 0xc9, 0xc9, 0xbc};
    for (size_t i = 0; i < std::size(off); ++i)
      Abs(0x5100 + i * 4, 0x800 + off[i]);
  }
  void Put(size_t at, const ex::MaskedPattern& p) {
    std::memcpy(data.data() + at, p.bytes, p.size);
  }
  void Abs(size_t at, uint32_t rva) {
    const uint32_t a = static_cast<uint32_t>(image.absolute_base) + rva;
    std::memcpy(data.data() + at, &a, 4);
  }
  void Rel(size_t at, uint32_t rva) {
    const auto d = static_cast<int32_t>(rva - at - 4);
    std::memcpy(data.data() + at, &d, 4);
  }
  bool Resolve(v::Sites* out = nullptr) {
    v::Sites local;
    return v::Resolve(image, imports, out ? out : &local);
  }
};
void Tests() {
  Fixture good;
  v::Sites sites;
  Check(good.Resolve(&sites));
  Check(sites.sampler == 0x400 && sites.keyboard_state_return == 0x472);
  Check(sites.message == 0x800 && sites.main_message_return == 0xa1a);
  Check(sites.main_sampler_return == 0xc1f && sites.config_slot == 0x6010);
  Check(sites.input_slot == 0x6000 && sites.window_slot == 0x6004);
  Check(sites.owner_slot == 0x601c && sites.modal_slot == 0x6020 &&
        sites.hidden_slot == 0x6028);
  // Mutate every non-relocated instruction byte, including stack sizes,
  // message cleanup, keyboard stride/index and both coordinate divisions.
  const std::pair<size_t, ex::MaskedPattern> patterns[] = {
      {0x400, v::kSampler.pattern()},     {0x800, v::kMessage.pattern()},
      {0xa00, v::kMainCall.pattern()},    {0xc00, v::kNormalize.pattern()},
      {0x1000, v::kDesign.pattern()},     {0x1400, v::kOwner.pattern()},
      {0x1800, v::kVisibility.pattern()}, {0x2000, v::kAliases.pattern()},
      {0x2800, v::kInputGate.pattern()},
  };
  for (const auto& item : patterns) {
    for (size_t j = 0; j < item.second.size; ++j) {
      if (!item.second.mask[j]) continue;
      Fixture f;
      f.data[item.first + j] ^= 1;
      Check(!f.Resolve());
    }
    Fixture f;
    f.Put(0x3000, item.second);
    Check(!f.Resolve());
    Fixture missing;
    std::memset(missing.data.data() + item.first, 0, item.second.size);
    Check(!missing.Resolve());
  }
  // Correct shapes at unrelated addresses must not be stitched together.
  for (const auto op : {0x803u, 0xc01u, 0xc2eu, 0xc5au, 0x141au}) {
    Fixture f;
    f.Abs(op, 0x6030);
    Check(!f.Resolve());
  }
  for (const auto op : {0xa16u, 0xc1bu}) {
    Fixture f;
    f.Rel(op, 0x4000);
    Check(!f.Resolve());
  }
  for (const auto op : {0x46eu, 0x42eu, 0x45fu, 0xc50u}) {
    Fixture f;
    f.Abs(op, 0x6214);
    Check(!f.Resolve());
  }
  // Table entries must identify the exact dispatch boundaries, not merely code.
  for (size_t i = 0; i < 15; ++i) {
    Fixture f;
    f.Abs(0x5100 + i * 4, 0x4000);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x828, 0x5200);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x888, 0x5200);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x8b3, 0x4010);
    Check(!f.Resolve());
  }
  for (const auto bad : {0x200u, 0x420u, 0x5000u, 0x6001u, 0x8000u}) {
    Fixture f;
    for (const auto op : {0x418u, 0x803u, 0xc01u, 0xc2eu, 0xc5au})
      f.Abs(op, bad);
    Check(!f.Resolve());
  }
  constexpr uint32_t bad_roles[] = {
      IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_WRITE,
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE};
  for (const uint32_t role : bad_roles) {
    Fixture f;
    f.image.sections[2].characteristics = role;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.sections[0].characteristics = IMAGE_SCN_MEM_READ;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.machine = IMAGE_FILE_MACHINE_AMD64;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.pointer_bits = 64;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.section_count = f.image.sections.size() + 1;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.base = nullptr;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.imports.keyboard_state = 0;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x456, 0x6000);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x828, 0x7ff0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.imports = {};
    sites.sampler = 1;
    Check(!f.Resolve(&sites));
    Check(sites.sampler == 0);
  }
  Check(!v::Resolve(good.image, good.imports, nullptr));
  // Complete image rebasing and a separate code movement preserve actual edges.
  {
    Fixture f;
    constexpr size_t absolute_operands[] = {
        0x407,  0x418,  0x42e,  0x45f,  0x46e,  0x803,  0x828,  0x888,  0xc01,
        0xc2e,  0xc3d,  0xc50,  0xc5a,  0x1001, 0x141a, 0x1420, 0x1426, 0x142c,
        0x1801, 0x1813, 0x181f, 0x213f, 0x216b, 0x22da, 0x22f5, 0x2310, 0x233c,
        0x235d, 0x2378, 0x2393, 0x240f, 0x242a, 0x2445, 0x2461, 0x246c, 0x2477,
        0x2482, 0x248d, 0x2498, 0x24a3, 0x24ae, 0x24b9, 0x24c4, 0x24cf, 0x24da,
        0x24e5, 0x24f0, 0x24fb, 0x2506, 0x2511, 0x251c, 0x2527, 0x2532, 0x253d,
        0x2548, 0x2553, 0x255e, 0x2569, 0x2574, 0x257f, 0x258a, 0x2595, 0x25a0,
        0x25ab, 0x25b6, 0x25c1, 0x25cc, 0x25e3, 0x25ef, 0x25f5, 0x25fb, 0x283d,
        0x284d, 0x5100, 0x5104, 0x5108, 0x510c, 0x5110, 0x5114, 0x5118, 0x511c,
        0x5120, 0x5124, 0x5128, 0x512c, 0x5130, 0x5134, 0x5138};
    for (const auto at : absolute_operands) {
      uint32_t value = 0;
      std::memcpy(&value, f.data.data() + at, 4);
      value += 0x200000;
      std::memcpy(f.data.data() + at, &value, 4);
    }
    f.image.absolute_base += 0x200000;
    Check(f.Resolve(&sites));
  }
  {
    Fixture f;
    std::memmove(f.data.data() + 0x500, f.data.data() + 0x400, 0x4c00);
    std::memset(f.data.data() + 0x400, 0, 0x100);
    for (size_t i = 0; i < 15; ++i) {
      uint32_t value = 0;
      std::memcpy(&value, f.data.data() + 0x5100 + i * 4, 4);
      value += 0x100;
      std::memcpy(f.data.data() + 0x5100 + i * 4, &value, 4);
    }
    Check(f.Resolve(&sites));
    Check(sites.message == 0x900 && sites.sampler == 0x500);
  }
  for (const size_t at :
       {0x2461u, 0x2482u, 0x25f5u, 0x25fbu, 0x283du, 0x284du}) {
    Fixture f;
    f.Abs(at, 0x6700);
    Check(!f.Resolve());
  }
}
}  // namespace
int main() {
  Tests();
  std::printf("legacy input/viewport: %zu checks passed\n", checks);
}
