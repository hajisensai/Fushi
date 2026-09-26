// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "loader_init_gate.h"

namespace {

using fushi_voice_hook::ParsePeLaunchLayout;
using fushi_voice_hook::PeLaunchLayout;
using fushi_voice_hook::ShouldUseLoaderInitGate;

void Put16(std::vector<uint8_t>& b, size_t off, uint16_t v) { std::memcpy(&b[off], &v, 2); }
void Put32(std::vector<uint8_t>& b, size_t off, uint32_t v) { std::memcpy(&b[off], &v, 4); }
void Put64(std::vector<uint8_t>& b, size_t off, uint64_t v) { std::memcpy(&b[off], &v, 8); }

struct PeSpec {
  bool is64 = false;
  uint32_t entry_rva = 0x1010;
  // 0 = no TLS directory. Otherwise number of non-null callbacks in the array.
  int tls_callbacks = -1;
  // Callback array placed in a section with VirtualSize but no raw data (packer-filled).
  bool callbacks_in_bss = false;
};

// Minimal on-disk PE: headers at 0, one .text section (RVA 0x1000, raw 0x400, 0x400 bytes)
// holding the TLS directory at RVA 0x1100 and the callback array at RVA 0x1200, plus an
// optional .bss section (RVA 0x2000, no raw data).
std::vector<uint8_t> BuildPe(const PeSpec& spec) {
  std::vector<uint8_t> b(0x800, 0);
  const uint64_t image_base = spec.is64 ? 0x140000000ull : 0x400000ull;
  b[0] = 'M';
  b[1] = 'Z';
  const uint32_t pe = 0x80;
  Put32(b, 0x3C, pe);
  Put32(b, pe, 0x00004550);
  const size_t fh = pe + 4;
  Put16(b, fh + 0, spec.is64 ? 0x8664 : 0x14C);
  Put16(b, fh + 2, 2);  // sections
  const uint16_t opt_size = spec.is64 ? 240 : 224;
  Put16(b, fh + 16, opt_size);
  const size_t opt = fh + 20;
  Put16(b, opt, spec.is64 ? 0x20B : 0x10B);
  Put32(b, opt + 16, spec.entry_rva);
  if (spec.is64) {
    Put64(b, opt + 24, image_base);
  } else {
    Put32(b, opt + 28, static_cast<uint32_t>(image_base));
  }
  const size_t dirs = opt + (spec.is64 ? 112 : 96);
  Put32(b, dirs - 4, 16);  // NumberOfRvaAndSizes
  const size_t sections = opt + opt_size;
  // .text
  std::memcpy(&b[sections], ".text", 5);
  Put32(b, sections + 8, 0x400);
  Put32(b, sections + 12, 0x1000);
  Put32(b, sections + 16, 0x400);
  Put32(b, sections + 20, 0x400);
  // .bss (virtual only)
  std::memcpy(&b[sections + 40], ".bss", 4);
  Put32(b, sections + 40 + 8, 0x200);
  Put32(b, sections + 40 + 12, 0x2000);
  Put32(b, sections + 40 + 16, 0);
  Put32(b, sections + 40 + 20, 0);

  if (spec.tls_callbacks >= 0) {
    const uint32_t tls_rva = 0x1100;
    Put32(b, dirs + 9 * 8, tls_rva);
    Put32(b, dirs + 9 * 8 + 4, spec.is64 ? 40 : 24);
    const size_t tls_off = 0x400 + (tls_rva - 0x1000);
    const uint32_t cb_rva = spec.callbacks_in_bss ? 0x2000 : 0x1200;
    const uint64_t cb_va = image_base + cb_rva;
    if (spec.is64) {
      Put64(b, tls_off + 24, cb_va);
    } else {
      Put32(b, tls_off + 12, static_cast<uint32_t>(cb_va));
    }
    if (!spec.callbacks_in_bss) {
      const size_t cb_off = 0x400 + (cb_rva - 0x1000);
      const size_t step = spec.is64 ? 8 : 4;
      for (int i = 0; i < spec.tls_callbacks; ++i) {
        const uint64_t fn = image_base + 0x1300 + static_cast<uint64_t>(i) * 0x10;
        if (spec.is64) {
          Put64(b, cb_off + i * step, fn);
        } else {
          Put32(b, cb_off + i * step, static_cast<uint32_t>(fn));
        }
      }
      // array is terminated by the zero-initialised slot that follows
    }
  }
  return b;
}

PeLaunchLayout Parse(const std::vector<uint8_t>& b) {
  return ParsePeLaunchLayout(b.data(), b.size());
}

}  // namespace

int main() {
  // 普通 exe（CafeStella.exe / PARQUET.exe 形态）：无 TLS 目录 → 不过门，行为不变。
  for (bool is64 : {false, true}) {
    PeSpec plain;
    plain.is64 = is64;
    const PeLaunchLayout layout = Parse(BuildPe(plain));
    assert(layout.valid);
    assert(layout.is_64bit == is64);
    assert(layout.entry_point_rva == 0x1010);
    assert(layout.tls_callback_count == 0);
    assert(!ShouldUseLoaderInitGate(layout, true));
  }

  // 有 TLS 目录但回调数组为空（夏空カナタ.exe：BCB 的 .tls 数据段）→ 不过门。
  {
    PeSpec empty_tls;
    empty_tls.tls_callbacks = 0;
    const PeLaunchLayout layout = Parse(BuildPe(empty_tls));
    assert(layout.valid);
    assert(layout.tls_callback_count == 0);
    assert(!ShouldUseLoaderInitGate(layout, true));
  }

  // 有 TLS 回调（Enigma 加壳的汉化 exe：1 个回调）→ 过门；32/64 位都数得对。
  for (bool is64 : {false, true}) {
    for (int count : {1, 3}) {
      PeSpec packed;
      packed.is64 = is64;
      packed.tls_callbacks = count;
      const PeLaunchLayout layout = Parse(BuildPe(packed));
      assert(layout.valid);
      assert(layout.tls_callback_count == static_cast<uint32_t>(count));
      assert(ShouldUseLoaderInitGate(layout, true));
      // 进程不归注入器恢复（延迟附着 / 跟随子进程 / 已提前恢复）时门没有意义。
      assert(!ShouldUseLoaderInitGate(layout, false));
    }
  }

  // 回调数组落在只有虚拟尺寸的节里（壳运行期才填）：静态读不到条目，但声明了数组 → 过门。
  {
    PeSpec runtime_filled;
    runtime_filled.tls_callbacks = 1;
    runtime_filled.callbacks_in_bss = true;
    const PeLaunchLayout layout = Parse(BuildPe(runtime_filled));
    assert(layout.valid);
    assert(layout.tls_callback_count == 1);
    assert(ShouldUseLoaderInitGate(layout, true));
  }

  // SteamStub（`.bind` 节）只作诊断分型：识别出来，但不影响是否过门。
  {
    PeSpec plain;
    std::vector<uint8_t> steam = BuildPe(plain);
    const size_t second_section = 0x80 + 4 + 20 + 224 + 40;
    std::memset(&steam[second_section], 0, 8);
    std::memcpy(&steam[second_section], ".bind", 5);
    const PeLaunchLayout layout = Parse(steam);
    assert(layout.valid);
    assert(layout.steam_stub);
    assert(!ShouldUseLoaderInitGate(layout, true));
    assert(!Parse(BuildPe(plain)).steam_stub);
    // `.binder` 之类前缀相同的节名不算。
    std::memcpy(&steam[second_section], ".binder", 7);
    assert(!Parse(steam).steam_stub);
  }

  // 入口点为 0（DLL 形态 / 损坏）→ 不过门：没有可以停靠的位置。
  {
    PeSpec no_entry;
    no_entry.tls_callbacks = 1;
    no_entry.entry_rva = 0;
    assert(!ShouldUseLoaderInitGate(Parse(BuildPe(no_entry)), true));
  }

  // 损坏 / 截断输入一律判无效、不过门、不越界。
  {
    PeSpec packed;
    packed.tls_callbacks = 2;
    const std::vector<uint8_t> good = BuildPe(packed);
    for (size_t cut : {size_t{0}, size_t{2}, size_t{0x40}, size_t{0x84}, size_t{0x100},
                       size_t{0x1F0}, size_t{0x410}, size_t{0x503}, size_t{0x601}}) {
      const PeLaunchLayout layout = ParsePeLaunchLayout(good.data(), cut);
      assert(layout.tls_callback_count <= 2);
      if (!layout.valid) assert(!ShouldUseLoaderInitGate(layout, true));
    }
    std::vector<uint8_t> bad_mz = good;
    bad_mz[0] = 'X';
    assert(!Parse(bad_mz).valid);
    std::vector<uint8_t> bad_sig = good;
    Put32(bad_sig, 0x80, 0x12345678);
    assert(!Parse(bad_sig).valid);
    std::vector<uint8_t> bad_lfanew = good;
    Put32(bad_lfanew, 0x3C, 0xFFFFFFF0u);
    assert(!Parse(bad_lfanew).valid);
    std::vector<uint8_t> bad_magic = good;
    Put16(bad_magic, 0x80 + 4 + 20, 0x0107);
    assert(!Parse(bad_magic).valid);
    assert(!ParsePeLaunchLayout(nullptr, 0).valid);
  }
  return 0;
}
