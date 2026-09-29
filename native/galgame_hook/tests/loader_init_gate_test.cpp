// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "kirikiri_launch_signature.h"
#include "loader_init_gate.h"

namespace {

using fushi_voice_hook::ParsePeLaunchLayout;
using fushi_voice_hook::PeLaunchLayout;
using fushi_voice_hook::ShouldUseLoaderInitGate;

// 下面 PE 结构断言都在「引擎 profile 已声明需要门」（KiriKiri）的前提下验 PE 判据本身；
// 引擎 profile 这一维的正负向单独在 TestEngineProfileAdmission 里验。
constexpr bool kKirikiri = true;

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

// 假目录：文件全路径 → 文件头字节。
using FakeDir = std::map<std::wstring, std::vector<uint8_t>>;

bool FakeDirLooksLikeKirikiri(const FakeDir& files, const std::wstring& dir) {
  return fushi_voice_hook::DirectoryLooksLikeKirikiri(
      dir,
      [&](const std::wstring& d, auto visit) {
        for (const auto& entry : files) {
          const std::wstring& path = entry.first;
          if (path.size() <= d.size() + 1 || path.compare(0, d.size(), d) != 0 ||
              path[d.size()] != L'\\') {
            continue;
          }
          const std::wstring name = path.substr(d.size() + 1);
          if (name.find(L'\\') != std::wstring::npos) continue;  // 只看直接子文件
          if (name.size() < 4 || name.compare(name.size() - 4, 4, L".xp3") != 0) continue;
          if (!visit(path)) break;
        }
      },
      [&](const std::wstring& path, uint8_t* out, size_t capacity) -> size_t {
        const auto it = files.find(path);
        if (it == files.end()) return 0;
        const size_t n = it->second.size() < capacity ? it->second.size() : capacity;
        if (n != 0) std::memcpy(out, it->second.data(), n);
        return n;
      });
}

std::vector<uint8_t> Xp3Header() {
  std::vector<uint8_t> header(fushi_voice_hook::kKirikiriXp3Magic,
                              fushi_voice_hook::kKirikiriXp3Magic +
                                  fushi_voice_hook::kKirikiriXp3MagicBytes);
  header.push_back(0x00);  // 后面跟索引偏移，内容无关
  return header;
}

// 从目录（假文件表）+ exe 的 PE 布局一路算到「是否启用门」，与 RunLaunch 的判定链同形。
bool GateAdmitted(const FakeDir& files, const std::wstring& dir,
                  const PeLaunchLayout& layout) {
  const fushi_voice_hook::KirikiriLaunchProfile profile =
      fushi_voice_hook::SelectKirikiriLaunchProfile(FakeDirLooksLikeKirikiri(files, dir));
  return ShouldUseLoaderInitGate(layout, true, profile.loader_init_gate);
}

void TestKirikiriSignature() {
  const std::wstring game = L"C:\\Games\\Title";
  // 原版 exe 与 Enigma 加壳汉化 exe 同目录：data.xp3 带 XP3 魔数 → KiriKiri。
  {
    const FakeDir files = {{game + L"\\data.xp3", Xp3Header()},
                           {game + L"\\voice.xp3", Xp3Header()}};
    assert(FakeDirLooksLikeKirikiri(files, game));
    const auto profile = fushi_voice_hook::SelectKirikiriLaunchProfile(true);
    assert(profile.recognised && profile.loader_init_gate);
  }
  // 只有扩展名、没有魔数（别家用同后缀的文件 / 空文件 / 截断文件）→ 不认（fail closed）。
  {
    const FakeDir files = {{game + L"\\data.xp3", {'P', 'K', 0x03, 0x04}},
                           {game + L"\\empty.xp3", {}}};
    assert(!FakeDirLooksLikeKirikiri(files, game));
    std::vector<uint8_t> truncated = Xp3Header();
    truncated.resize(fushi_voice_hook::kKirikiriXp3MagicBytes - 1);
    const FakeDir short_file = {{game + L"\\data.xp3", truncated}};
    assert(!FakeDirLooksLikeKirikiri(short_file, game));
  }
  // 魔数只在子目录里（不在 exe 同目录）→ 不认。
  {
    const FakeDir files = {{game + L"\\sub\\data.xp3", Xp3Header()}};
    assert(!FakeDirLooksLikeKirikiri(files, game));
  }
  // 空目录 / 空目录名 → 不认。
  assert(!FakeDirLooksLikeKirikiri(FakeDir{}, game));
  assert(!FakeDirLooksLikeKirikiri(FakeDir{{L"\\data.xp3", Xp3Header()}}, L""));
  // 扫描有上限：前 kKirikiriXp3ScanLimit 个都不是 XP3 时不再往后读。
  {
    FakeDir files;
    for (size_t i = 0; i < fushi_voice_hook::kKirikiriXp3ScanLimit; ++i) {
      files[game + L"\\a" + std::to_wstring(100 + i) + L".xp3"] = {'n', 'o'};
    }
    files[game + L"\\z.xp3"] = Xp3Header();
    assert(!FakeDirLooksLikeKirikiri(files, game));
  }
  const std::vector<uint8_t> header = Xp3Header();
  assert(fushi_voice_hook::IsKirikiriXp3ArchiveHeader(header.data(), header.size()));
  assert(!fushi_voice_hook::IsKirikiriXp3ArchiveHeader(nullptr, 0));
  const auto none = fushi_voice_hook::SelectKirikiriLaunchProfile(false);
  assert(!none.recognised && !none.loader_init_gate);
}

void TestEngineProfileAdmission() {
  for (bool is64 : {false, true}) {
    PeSpec packed;
    packed.is64 = is64;
    packed.tls_callbacks = 1;
    const PeLaunchLayout tls = Parse(BuildPe(packed));
    PeSpec plain_spec;
    plain_spec.is64 = is64;
    const PeLaunchLayout plain = Parse(BuildPe(plain_spec));
    assert(tls.tls_callback_count == 1 && plain.tls_callback_count == 0);

    // 正向：KiriKiri 结构特征（exe 同目录 XP3 归档）+ TLS 回调（Enigma 加壳汉化 exe）→ 过门。
    const std::wstring krkr = L"C:\\Games\\Krkr";
    const FakeDir krkr_files = {{krkr + L"\\data.xp3", Xp3Header()},
                                {krkr + L"\\patch.xp3", Xp3Header()}};
    assert(GateAdmitted(krkr_files, krkr, tls));
    // KiriKiri 但 exe 没有 TLS 回调（原版 CafeStella.exe / SenrenBanka.exe 形态）→ 不过门。
    assert(!GateAdmitted(krkr_files, krkr, plain));

    // 跨引擎负向：带 TLS 回调、但 exe 目录没有 KiriKiri 签名的一律不过门，启动时序不变。
    //   Siglus（Enigma 加壳；Gameexe.dat + Scene.pck）
    const std::wstring siglus = L"C:\\Games\\Siglus";
    assert(!GateAdmitted(FakeDir{{siglus + L"\\Gameexe.dat", {0x00}},
                                 {siglus + L"\\Scene.pck", {0x00}}},
                         siglus, tls));
    //   NW.js 版 TyranoScript（package.nw / nw.dll）
    const std::wstring nwjs = L"C:\\Games\\Tyrano";
    assert(!GateAdmitted(FakeDir{{nwjs + L"\\package.nw", {'P', 'K', 0x03, 0x04}},
                                 {nwjs + L"\\nw.dll", {'M', 'Z'}}},
                         nwjs, tls));
    //   MinGW 运行时 / Themida、VMProtect 加壳 / 用 thread_local 的 MSVC exe：目录里只有 exe 与 DLL
    const std::wstring other = L"C:\\Games\\Other";
    assert(!GateAdmitted(FakeDir{{other + L"\\libgcc_s_dw2-1.dll", {'M', 'Z'}}}, other, tls));
    assert(!GateAdmitted(FakeDir{}, other, tls));
    //   同后缀但不是 XP3 的归档 → 不过门
    assert(!GateAdmitted(FakeDir{{other + L"\\data.xp3", {'P', 'K', 0x03, 0x04}}}, other, tls));
  }
}

void TestGateOutcomeDisposition() {
  using fushi_voice_hook::LoaderInitGateLeftProcessRunning;
  using fushi_voice_hook::LoaderInitGateOutcome;
  // 只有「主线程已在跑初始化却没停到入口」（入口被壳改写 / 超时）才改按已运行进程附着；
  // 停到入口或门根本没开始时照旧早注入、注入后恢复。
  assert(LoaderInitGateLeftProcessRunning(LoaderInitGateOutcome::kLeftRunning));
  assert(!LoaderInitGateLeftProcessRunning(LoaderInitGateOutcome::kParkedAtEntry));
  assert(!LoaderInitGateLeftProcessRunning(LoaderInitGateOutcome::kNotStarted));
}

}  // namespace

int main() {
  TestKirikiriSignature();
  TestEngineProfileAdmission();
  TestGateOutcomeDisposition();

  // 普通 exe（CafeStella.exe / PARQUET.exe 形态）：无 TLS 目录 → 不过门，行为不变。
  for (bool is64 : {false, true}) {
    PeSpec plain;
    plain.is64 = is64;
    const PeLaunchLayout layout = Parse(BuildPe(plain));
    assert(layout.valid);
    assert(layout.is_64bit == is64);
    assert(layout.entry_point_rva == 0x1010);
    assert(layout.tls_callback_count == 0);
    assert(!ShouldUseLoaderInitGate(layout, true, kKirikiri));
  }

  // 有 TLS 目录但回调数组为空（夏空カナタ.exe：BCB 的 .tls 数据段）→ 不过门。
  {
    PeSpec empty_tls;
    empty_tls.tls_callbacks = 0;
    const PeLaunchLayout layout = Parse(BuildPe(empty_tls));
    assert(layout.valid);
    assert(layout.tls_callback_count == 0);
    assert(!ShouldUseLoaderInitGate(layout, true, kKirikiri));
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
      assert(ShouldUseLoaderInitGate(layout, true, kKirikiri));
      // 进程不归注入器恢复（延迟附着 / 跟随子进程 / 已提前恢复）时门没有意义。
      assert(!ShouldUseLoaderInitGate(layout, false, kKirikiri));
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
    assert(ShouldUseLoaderInitGate(layout, true, kKirikiri));
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
    assert(!ShouldUseLoaderInitGate(layout, true, kKirikiri));
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
    assert(!ShouldUseLoaderInitGate(Parse(BuildPe(no_entry)), true, kKirikiri));
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
      if (!layout.valid) assert(!ShouldUseLoaderInitGate(layout, true, kKirikiri));
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
