#ifdef NDEBUG
#undef NDEBUG
#endif
#include "siglus_eightarg_input_viewport.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <vector>
namespace v = fushi_voice_hook::siglus_eightarg_input_viewport;
namespace ex = fushi_voice_hook::exact_lookup;
namespace {
size_t checks = 0;
void CheckAt(bool value, int line) {
  ++checks;
  if (!value) {
    std::fprintf(stderr, "check %zu failed at line %d\n", checks, line);
    std::exit(1);
  }
}
#define Check(value) CheckAt((value), __LINE__)
struct Fixture {
  std::vector<uint8_t> bytes = std::vector<uint8_t>(0x8000);
  ex::LoadedPeImage image{};
  v::Imports imports{};
  Fixture(uint32_t base = 0x400000) {
    image.base = bytes.data();
    image.absolute_base = base;
    image.size = bytes.size();
    image.machine = IMAGE_FILE_MACHINE_I386;
    image.pointer_bits = 32;
    image.section_count = 3;
    image.sections[0] = {bytes.data() + 0x400, 0x5c00, 0x400,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {bytes.data() + 0x6000, 0x1000, 0x6000,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
    image.sections[2] = {bytes.data() + 0x7000, 0x1000, 0x7000,
                         IMAGE_SCN_MEM_READ};
    Put(0x400, v::kRoot.pattern());
    Abs(0x405, 0x6000);
    Abs(0x40a, 0x6004);
    Abs(0x419, 0x6008);
    Abs(0x41e, 0x600c);
    Abs(0x429, 0x6010);
    Put(0x800, v::kRootCtor.pattern());
    Abs(0x806, 0x5800);
    Abs(0x814, 0x6014);
    Rel(0x82a, 0x5804);
    Rel(0x874, 0x5808);
    Rel(0x87f, 0x580c);
    Rel(0x88e, 0x1000);
    Put(0x1000, v::kOwnerCtor.pattern());
    Abs(0x1006, 0x5810);
    Abs(0x1018, 0x6014);
    Rel(0x1053, 0x5814);
    Rel(0x1087, 0x5818);
    Rel(0x10c5, 0x5818);
    Rel(0x10d6, 0x5814);
    Rel(0x10ff, 0x2000);
    Put(0x1895, v::kAliases.pattern());
    Abs(0x18a6, 0x6018);
    Abs(0x18b1, 0x601c);
    Abs(0x18bc, 0x6020);
    Abs(0x18c7, 0x6024);
    Abs(0x18d2, 0x6028);
    Abs(0x18dd, 0x602c);
    Abs(0x18e8, 0x6030);
    Abs(0x18f3, 0x6034);
    Abs(0x18fe, 0x6038);
    Abs(0x1909, 0x603c);
    Abs(0x1914, 0x6040);
    Abs(0x191f, 0x6044);
    Abs(0x192a, 0x6048);
    Abs(0x1932, 0x604c);
    Abs(0x193d, 0x6050);
    Abs(0x1948, 0x6054);
    Abs(0x1953, 0x6058);
    Abs(0x195e, 0x605c);
    Abs(0x1969, 0x6060);
    Abs(0x1974, 0x6064);
    Abs(0x197f, 0x6068);
    Abs(0x198a, 0x606c);
    Abs(0x1995, 0x6070);
    Abs(0x19a0, 0x6074);
    Abs(0x19ab, 0x6078);
    Abs(0x19b6, 0x607c);
    Abs(0x19c1, 0x6080);
    Abs(0x19cc, 0x6084);
    Abs(0x19d7, 0x6088);
    Abs(0x19e2, 0x608c);
    Abs(0x19ed, 0x6090);
    Abs(0x19f8, 0x6094);
    Abs(0x1a03, 0x6098);
    Abs(0x1a0e, 0x609c);
    Abs(0x1a19, 0x60a0);
    Abs(0x1a24, 0x60a4);
    Abs(0x1a2f, 0x60a8);
    Abs(0x1a3a, 0x60ac);
    Abs(0x1a45, 0x60b0);
    Abs(0x1a50, 0x60b4);
    Abs(0x1a5b, 0x60b8);
    Abs(0x1a66, 0x60bc);
    Abs(0x1a71, 0x60c0);
    Abs(0x1a7c, 0x60c4);
    Abs(0x1a87, 0x60c8);
    Abs(0x1a92, 0x60cc);
    Abs(0x1a9d, 0x60d0);
    Abs(0x1aa8, 0x60d4);
    Abs(0x1ab3, 0x60d8);
    Abs(0x1abe, 0x60dc);
    Abs(0x1ac9, 0x60e0);
    Abs(0x1ad4, 0x60e4);
    Abs(0x1adf, 0x60e8);
    Abs(0x1aea, 0x60ec);
    Abs(0x1af5, 0x60f0);
    Abs(0x1b00, 0x60f4);
    Abs(0x1b0b, 0x60f8);
    Put(0x2000, v::kWindowCtor.pattern());
    Rel(0x2004, 0x581c);
    Abs(0x202a, 0x7000);
    Put(0x2400, v::kSampler.pattern());
    Abs(0x240a, 0x6014);
    Abs(0x2417, 0x6024);
    Abs(0x2451, 0x7004);
    Rel(0x2483, 0x5820);
    Abs(0x248c, 0x7008);
    Abs(0x2496, 0x700c);
    Rel(0x271b, 0x5824);
    Rel(0x277c, 0x5828);
    Put(0x3000, v::kMain.pattern());
    Abs(0x3006, 0x582c);
    Abs(0x3018, 0x6014);
    Rel(0x3037, 0x5830);
    Abs(0x3095, 0x7008);
    Abs(0x309b, 0x6018);
    Abs(0x30ad, 0x7010);
    Abs(0x30bd, 0x6018);
    Rel(0x30e9, 0x5820);
    Abs(0x30ff, 0x7014);
    Rel(0x3111, 0x5834);
    Abs(0x3116, 0x7018);
    Rel(0x3124, 0x5838);
    Rel(0x3141, 0x583c);
    Abs(0x317a, 0x6038);
    Rel(0x318e, 0x5840);
    Abs(0x31ba, 0x60fc);
    Abs(0x31df, 0x6024);
    Rel(0x31eb, 0x5844);
    Rel(0x3207, 0x2400);
    Abs(0x320c, 0x6024);
    Rel(0x3253, 0x5848);
    Abs(0x325e, 0x6024);
    Rel(0x3264, 0x5844);
    Rel(0x326e, 0x584c);
    Abs(0x3274, 0x6028);
    Abs(0x3291, 0x6018);
    Abs(0x329a, 0x701c);
    Abs(0x32a0, 0x6028);
    Abs(0x32ac, 0x6024);
    Abs(0x334b, 0x6038);
    Abs(0x3351, 0x60ec);
    Abs(0x3370, 0x6044);
    Put(0x40b9, v::kMainEnd.pattern());
    Rel(0x40cf, 0x5828);
    Put(0x4400, v::kMessage.pattern());
    Abs(0x4409, 0x6024);
    Abs(0x442b, 0x4544);
    Rel(0x443c, 0x5850);
    Rel(0x4453, 0x5854);
    Abs(0x44c7, 0x455c);
    Rel(0x44d5, 0x5858);
    Rel(0x44e9, 0x585c);
    Rel(0x44fd, 0x5858);
    Rel(0x4511, 0x585c);
    Rel(0x4525, 0x5858);
    Rel(0x453a, 0x5860);
    Put(0x4800, v::kHandler.pattern());
    Rel(0x4818, 0x4400);
    Abs(0x4835, 0x49ac);
    Abs(0x483c, 0x4998);
    Rel(0x4843, 0x5864);
    Rel(0x485d, 0x5868);
    Rel(0x4877, 0x586c);
    Abs(0x48bd, 0x6038);
    Rel(0x48da, 0x5870);
    Rel(0x48e3, 0x5874);
    Rel(0x48fe, 0x5878);
    Rel(0x4920, 0x587c);
    Abs(0x492f, 0x6038);
    Abs(0x495e, 0x6100);
    Abs(0x4965, 0x7020);
    Rel(0x4988, 0x5880);
    Put(0x4c00, v::kDesign.pattern());
    Abs(0x4c02, 0x600c);
    Abs(0x4c08, 0x6010);
    Put(0x5000, v::kScale.pattern());
    Put(0x5400, v::kGate.pattern());
    Abs(0x5404, 0x6038);
    Abs(0x541b, 0x60ec);
    Abs(0x542d, 0x6044);
    Abs(0x4544, 0x442f);
    Abs(0x4548, 0x4446);
    Abs(0x454c, 0x453e);
    Abs(0x4550, 0x453e);
    Abs(0x4554, 0x442f);
    Abs(0x4558, 0x4446);
    Abs(0x455c, 0x44cb);
    Abs(0x4560, 0x453e);
    Abs(0x4564, 0x44df);
    Abs(0x4568, 0x44f3);
    Abs(0x456c, 0x453e);
    Abs(0x4570, 0x4507);
    Abs(0x4574, 0x451b);
    Abs(0x4578, 0x453e);
    Abs(0x457c, 0x452f);
    Abs(0x4998, 0x4840);
    Abs(0x499c, 0x4874);
    Abs(0x49a0, 0x485a);
    Abs(0x49a4, 0x4943);
    Abs(0x49a8, 0x4943);
    bytes[0x49ac] = 0;
    bytes[0x49ad] = 4;
    bytes[0x49ae] = 4;
    bytes[0x49af] = 4;
    bytes[0x49b0] = 4;
    bytes[0x49b1] = 4;
    bytes[0x49b2] = 4;
    bytes[0x49b3] = 4;
    bytes[0x49b4] = 4;
    bytes[0x49b5] = 4;
    bytes[0x49b6] = 4;
    bytes[0x49b7] = 4;
    bytes[0x49b8] = 4;
    bytes[0x49b9] = 4;
    bytes[0x49ba] = 1;
    bytes[0x49bb] = 2;
    bytes[0x49bc] = 4;
    bytes[0x49bd] = 4;
    bytes[0x49be] = 4;
    bytes[0x49bf] = 4;
    bytes[0x49c0] = 4;
    bytes[0x49c1] = 4;
    bytes[0x49c2] = 4;
    bytes[0x49c3] = 4;
    bytes[0x49c4] = 4;
    bytes[0x49c5] = 4;
    bytes[0x49c6] = 4;
    bytes[0x49c7] = 4;
    bytes[0x49c8] = 4;
    bytes[0x49c9] = 4;
    bytes[0x49ca] = 4;
    bytes[0x49cb] = 3;
    Abs(0x7004, 0x4800);
    imports = {0x700c, 0x7004, 0x7008, 0x701c};
  }
  void Put(size_t at, const ex::MaskedPattern& p) {
    std::memcpy(bytes.data() + at, p.bytes, p.size);
  }
  void Abs(size_t at, uint32_t target) {
    const auto value = static_cast<uint32_t>(image.absolute_base) + target;
    std::memcpy(bytes.data() + at, &value, 4);
  }
  void Rel(size_t at, uint32_t target) {
    const int32_t value = static_cast<int32_t>(target - at - 4);
    std::memcpy(bytes.data() + at, &value, 4);
  }
  bool Resolve(v::Sites* out = nullptr) {
    v::Sites local;
    return v::Resolve(image, imports, out ? out : &local);
  }
};
void Tests() {
  Fixture good;
  v::Sites out{};
  Check(good.Resolve(&out));
  Check(out.sampler == 0x2400 && out.key_state_return == 0x24a3);
  Check(out.main_input == 0x3000 && out.main_sampler_return == 0x320b);
  Check(out.message == 0x4400 && out.window_handler == 0x4800 &&
        out.window_message_return == 0x481c);
  Check(out.root_slot == 0x6000);
  Check(out.owner_slot == 0x6008);
  Check(out.config_slot == 0x600c);
  Check(out.window_slot == 0x6018);
  Check(out.input_slot == 0x6024);
  Check(out.current_input_slot == 0x6028);
  Check(out.prior_input_slot == 0x602c);
  Check(out.viewport_slot == 0x6038);
  Check(out.gate2_slot == 0x6044);
  Check(out.gate3_slot == 0x60ec);
  Check(out.manager_slot == 0x6048);
  Check(out.scene_slot == 0x60e8);
  // A relocated scene publication remains valid only as a distinct owner alias.
  {
    Fixture f;
    f.Abs(0x1adf, 0x6f00);
    Check(f.Resolve(&out));
    Check(out.scene_slot == 0x6f00);
  }
  Fixture relocated(0x900000);
  Check(relocated.Resolve());
  // Non-required aliases cannot overwrite required ones in the constructor.
  for (const auto& alias : v::kAliasesRelocations) {
    if (alias.offset == 17) continue;
    Fixture f;
    f.Abs(0x1895 + alias.offset, static_cast<uint32_t>(out.window_slot));
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x40a, static_cast<uint32_t>(out.owner_slot));
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3095, static_cast<uint32_t>(f.imports.cursor_position));
    Check(!f.Resolve());
  }
  Check(!v::Resolve(good.image, good.imports, nullptr));
  const std::pair<size_t, ex::MaskedPattern> patterns[] = {
      {0x400, v::kRoot.pattern()},        {0x800, v::kRootCtor.pattern()},
      {0x1000, v::kOwnerCtor.pattern()},  {0x1895, v::kAliases.pattern()},
      {0x2000, v::kWindowCtor.pattern()}, {0x2400, v::kSampler.pattern()},
      {0x3000, v::kMain.pattern()},       {0x40b9, v::kMainEnd.pattern()},
      {0x4400, v::kMessage.pattern()},    {0x4800, v::kHandler.pattern()},
      {0x4c00, v::kDesign.pattern()},     {0x5000, v::kScale.pattern()},
      {0x5400, v::kGate.pattern()},
  };
  // Every non-relocated byte is an executable behavior contract, including
  // branches, stack arguments/cleanup, key stride and both coordinate
  // divisions.
  for (const auto& pair : patterns) {
    for (size_t i = 0; i < pair.second.size; ++i) {
      if (!pair.second.mask[i]) continue;
      Fixture f;
      f.bytes[pair.first + i] ^= 1;
      Check(!f.Resolve());
    }
    Fixture duplicate;
    duplicate.Put(0x5a00, pair.second);
    if (pair.first == 0x40b9)
      Check(duplicate.Resolve());
    else if (pair.second.size <= 0x600)
      Check(!duplicate.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x405, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x40a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x419, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x41e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x429, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x806, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x814, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x82a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x874, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x87f, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x88e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1006, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1018, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x1053, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x1087, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x10c5, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x10d6, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x10ff, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18a6, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18b1, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18bc, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18c7, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18d2, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18dd, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18e8, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18f3, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18fe, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1909, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1914, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x191f, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x192a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1932, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x193d, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1948, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1953, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x195e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1969, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1974, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x197f, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x198a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1995, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19a0, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19ab, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19b6, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19c1, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19cc, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19d7, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19e2, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19ed, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x19f8, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a03, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a0e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a19, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a24, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a2f, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a3a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a45, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a50, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a5b, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a66, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a71, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a7c, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a87, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a92, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1a9d, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1aa8, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1ab3, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1abe, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1ac9, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1ad4, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1adf, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1aea, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1af5, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1b00, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x1b0b, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x2004, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x202a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x240a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x2417, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x2451, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x2483, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x248c, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x2496, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x271b, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x277c, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3006, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3018, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3037, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3095, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x309b, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x30ad, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x30bd, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x30e9, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x30ff, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3111, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3116, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3124, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3141, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x317a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x318e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x31ba, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x31df, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x31eb, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3207, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x320c, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3253, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x325e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3264, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x326e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3274, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3291, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x329a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x32a0, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x32ac, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x334b, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3351, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3370, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x40cf, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4409, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x442b, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x443c, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4453, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x44c7, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x44d5, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x44e9, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x44fd, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4511, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4525, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x453a, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4818, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4835, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x483c, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4843, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x485d, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4877, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x48bd, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x48da, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x48e3, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x48fe, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4920, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x492f, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x495e, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4965, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4988, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4c02, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4c08, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x5404, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x541b, 0);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x542d, 0);
    Check(!f.Resolve());
  }
  // A sole publication operand may relocate within writable data; runtime
  // validates the pointed-to object. It cannot alias another published role.
  {
    Fixture f;
    f.Abs(0x405, 0x6f00);
    Check(f.Resolve(&out));
    Check(out.root_slot == 0x6f00);
  }
  {
    Fixture f;
    f.Abs(0x419, 0x6f00);
    Check(f.Resolve(&out));
    Check(out.owner_slot == 0x6f00);
  }
  {
    Fixture f;
    f.Abs(0x41e, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x88e, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x10ff, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18a6, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18c7, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18d2, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x18dd, 0x6f00);
    Check(f.Resolve(&out));
    Check(out.prior_input_slot == 0x6f00);
  }
  {
    Fixture f;
    f.Abs(0x18fe, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x191f, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x192a, 0x6f00);
    Check(f.Resolve(&out));
    Check(out.manager_slot == 0x6f00);
  }
  {
    Fixture f;
    f.Abs(0x1aea, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x2417, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x309b, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x30bd, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x317a, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x31df, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x3207, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x320c, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x325e, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3274, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3291, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x32a0, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x32ac, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x334b, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3351, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x3370, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4409, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Rel(0x4818, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x48bd, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x492f, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4c02, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x5404, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x541b, 0x6f00);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x542d, 0x6f00);
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
    f.image.base = nullptr;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.section_count = f.image.sections.size() + 1;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.absolute_base = UINT32_MAX - 0x100;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.sections[0].characteristics = IMAGE_SCN_MEM_READ;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.sections[1].characteristics = IMAGE_SCN_MEM_READ;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.image.sections[2].characteristics |= IMAGE_SCN_MEM_WRITE;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.imports.key_state = 0;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.imports.key_state = f.imports.cursor_position;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.imports.cursor_position = 0;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.imports.active_window = 0;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.imports.screen_to_client = 0;
    Check(!f.Resolve());
  }
  {
    Fixture f;
    out.sampler = 99;
    f.bytes[0x2400] = 0xe9;
    Check(!f.Resolve(&out));
    Check(out.sampler == 0 && out.root_slot == 0);
  }
  {
    Fixture f;
    f.Abs(0x4544, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4548, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x454c, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4550, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4554, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4558, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x455c, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4560, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4564, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4568, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x456c, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4570, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4574, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4578, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x457c, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x4998, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x499c, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x49a0, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x49a4, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x49a8, 0x5900);
    Check(!f.Resolve());
  }
  {
    Fixture f;
    f.Abs(0x7004, 0x5900);
    Check(!f.Resolve());
  }
}
}  // namespace
int main() {
  Tests();
  std::printf("siglus_eightarg_input_viewport: %zu checks passed\n", checks);
  return 0;
}
