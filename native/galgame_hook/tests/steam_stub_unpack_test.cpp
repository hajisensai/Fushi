// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "steam_stub_unpack.h"

namespace {

using fushi_voice_hook::ClassifySteamStubCode;
using fushi_voice_hook::SelectSteamStubCodeProbe;
using fushi_voice_hook::SteamStubCodeProbe;
using fushi_voice_hook::SteamStubCodeState;

void Put16(std::vector<uint8_t>& b, size_t off, uint16_t v) { std::memcpy(&b[off], &v, 2); }
void Put32(std::vector<uint8_t>& b, size_t off, uint32_t v) { std::memcpy(&b[off], &v, 4); }
void Put64(std::vector<uint8_t>& b, size_t off, uint64_t v) { std::memcpy(&b[off], &v, 8); }

struct Section {
  const char* name;
  uint32_t vaddr;
  uint32_t raw_size;
  uint32_t raw_ptr;
  uint32_t characteristics;
};

constexpr uint32_t kCode = 0x60000020u;  // CNT_CODE | MEM_EXECUTE | MEM_READ
constexpr uint32_t kData = 0xC0000040u;  // INITIALIZED_DATA | READ | WRITE

std::vector<uint8_t> BuildPe(bool is64, const std::vector<Section>& sections) {
  std::vector<uint8_t> b(0x3000, 0);
  b[0] = 'M';
  b[1] = 'Z';
  const uint32_t pe = 0x80;
  Put32(b, 0x3C, pe);
  Put32(b, pe, 0x00004550);
  const size_t fh = pe + 4;
  Put16(b, fh + 0, is64 ? 0x8664 : 0x14C);
  Put16(b, fh + 2, static_cast<uint16_t>(sections.size()));
  const uint16_t opt_size = is64 ? 240 : 224;
  Put16(b, fh + 16, opt_size);
  const size_t opt = fh + 20;
  Put16(b, opt, is64 ? 0x20B : 0x10B);
  if (is64) {
    Put64(b, opt + 24, 0x140000000ull);
  } else {
    Put32(b, opt + 28, 0x400000u);
  }
  size_t s = opt + opt_size;
  for (const Section& sec : sections) {
    std::memcpy(&b[s], sec.name, std::strlen(sec.name));
    Put32(b, s + 8, sec.raw_size);
    Put32(b, s + 12, sec.vaddr);
    Put32(b, s + 16, sec.raw_size);
    Put32(b, s + 20, sec.raw_ptr);
    Put32(b, s + 36, sec.characteristics);
    s += 40;
  }
  for (size_t i = 0x400; i < b.size(); ++i) b[i] = static_cast<uint8_t>(i * 7 + 3);
  return b;
}

// KiriKiri2 SteamStub 构建的形态：.text 可执行（密文），.bind 是壳（入口点在此）。
std::vector<uint8_t> SteamStubPe(bool is64 = false) {
  return BuildPe(is64, {{".text", 0x1000, 0x1000, 0x400, kCode},
                        {".data", 0x2000, 0x400, 0x1400, kData},
                        {".bind", 0x3000, 0x800, 0x1800, kCode}});
}

void TestProbeSelection() {
  const std::vector<uint8_t> pe = SteamStubPe();
  const SteamStubCodeProbe probe = SelectSteamStubCodeProbe(pe.data(), pe.size());
  assert(probe.valid);
  assert(probe.rva == 0x1000);  // 第一个可执行、非 .bind 的节
  assert(probe.file_offset == 0x400);
  assert(probe.length == 0x1000);
  assert(probe.file_image_base == 0x400000u);

  const std::vector<uint8_t> pe64 = SteamStubPe(true);
  const SteamStubCodeProbe probe64 = SelectSteamStubCodeProbe(pe64.data(), pe64.size());
  assert(probe64.valid);
  assert(probe64.file_image_base == 0x140000000ull);

  // .bind 排在代码段之前也一样跳过它。
  const std::vector<uint8_t> bind_first =
      BuildPe(false, {{".bind", 0x1000, 0x800, 0x400, kCode},
                      {".text", 0x2000, 0x2000, 0xC00, kCode}});
  const SteamStubCodeProbe p2 = SelectSteamStubCodeProbe(bind_first.data(), bind_first.size());
  assert(p2.valid && p2.rva == 0x2000);
  assert(p2.length == fushi_voice_hook::kSteamStubProbeMaxBytes);
}

void TestNegativeShapes() {
  // 没有 .bind：普通 exe（含其它加壳器）不过这道门。
  const std::vector<uint8_t> plain =
      BuildPe(false, {{".text", 0x1000, 0x1000, 0x400, kCode},
                      {".data", 0x2000, 0x400, 0x1400, kData}});
  assert(!SelectSteamStubCodeProbe(plain.data(), plain.size()).valid);

  // 只有 .bind 一个可执行节：没有可比较的密文段。
  const std::vector<uint8_t> only_bind =
      BuildPe(false, {{".data", 0x1000, 0x400, 0x400, kData},
                      {".bind", 0x2000, 0x800, 0x800, kCode}});
  assert(!SelectSteamStubCodeProbe(only_bind.data(), only_bind.size()).valid);

  // 截断 / 坏头一律 invalid、不越界。
  const std::vector<uint8_t> good = SteamStubPe();
  for (size_t cut : {size_t{0}, size_t{2}, size_t{0x40}, size_t{0x84}, size_t{0x100},
                     size_t{0x1A0}, size_t{0x200}, size_t{0x401}}) {
    const SteamStubCodeProbe p = SelectSteamStubCodeProbe(good.data(), cut);
    if (p.valid) assert(p.file_offset + p.length <= cut);
  }
  std::vector<uint8_t> bad_mz = good;
  bad_mz[0] = 'X';
  assert(!SelectSteamStubCodeProbe(bad_mz.data(), bad_mz.size()).valid);
  assert(!SelectSteamStubCodeProbe(nullptr, 0).valid);
}

void TestClassification() {
  const std::vector<uint8_t> pe = SteamStubPe();
  const SteamStubCodeProbe probe = SelectSteamStubCodeProbe(pe.data(), pe.size());
  const uint8_t* file = pe.data() + probe.file_offset;
  std::vector<uint8_t> memory(file, file + probe.length);

  // 刚映射、壳没跑完：与磁盘一致 → 不能注入。
  assert(ClassifySteamStubCode(probe, 0x400000u, file, memory.data(), memory.size()) ==
         SteamStubCodeState::kStillPacked);

  // 壳原地解密后 → 可以注入。
  memory[17] ^= 0x5A;
  assert(ClassifySteamStubCode(probe, 0x400000u, file, memory.data(), memory.size()) ==
         SteamStubCodeState::kUnpacked);

  // 映像被重定位：重定位修补本身会改字节，比较不可信 → kUnknown（调用方退回窗口门）。
  std::vector<uint8_t> same(file, file + probe.length);
  assert(ClassifySteamStubCode(probe, 0x10000000u, file, same.data(), same.size()) ==
         SteamStubCodeState::kUnknown);

  // 读不全 / 无效探针 → kUnknown。
  assert(ClassifySteamStubCode(probe, 0x400000u, file, same.data(), same.size() - 1) ==
         SteamStubCodeState::kUnknown);
  assert(ClassifySteamStubCode(SteamStubCodeProbe{}, 0x400000u, file, same.data(),
                               same.size()) == SteamStubCodeState::kUnknown);
  assert(ClassifySteamStubCode(probe, 0x400000u, nullptr, same.data(), same.size()) ==
         SteamStubCodeState::kUnknown);
}

}  // namespace

int main() {
  TestProbeSelection();
  TestNegativeShapes();
  TestClassification();
  return 0;
}
