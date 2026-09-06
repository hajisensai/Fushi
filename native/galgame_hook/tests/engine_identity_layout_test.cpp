// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// BGI / CatSystem2 / elf AI6 / Malie 四个引擎的身份判据（BUG-2153）。
//
// 本测试要钉住的不变式只有一条：**身份由磁盘结构决定，与 exe 叫什么名字无关**。
// 这四个引擎原来都把 exe 名当先决条件（`BGI.exe` / `cs2_open.exe` / `AI6WIN.exe` /
// `malie.exe`），名字不符时后面的结构判据一行都不跑——改名的发行版因此整个 adapter
// 不被认领。仓库在 Siglus 上真机踩过同一脚（`iroseka_HD.exe`，见 siglus_launch_test.cpp）。
//
// 所以每个引擎都测三档：
//   * 正确结构 + **一个绝不叫历史 exe 名的目录** → 必须匹配（名字不是必要条件）；
//   * 结构缺一半 / 魔数不对 → 必须不匹配（结构是真判据，不是摆设）；
//   * 测试进程自己的目录 → 必须不匹配（不会误认领）。
// 「名字不是充分条件」由第二档覆盖：只放一个空的同名 exe 而没有归档时不匹配。

#include "../hook/adapters/bgi_ethornell_profile.h"
#include "../hook/adapters/catsystem2_profile.h"
#include "../hook/adapters/elf_ai6_profile.h"
#include "../hook/adapters/malie_profile.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

namespace mal = ::fushi_voice_hook::malie;
namespace ai6 = ::fushi_voice_hook::elf_ai6;

std::wstring MakeTempRoot(const wchar_t* tag) {
  wchar_t temp[MAX_PATH] = {0};
  assert(GetTempPathW(MAX_PATH, temp) != 0);
  std::wstring root = std::wstring(temp) + L"fushi_engine_identity_" + tag +
                      L"_" + std::to_wstring(GetCurrentProcessId());
  RemoveDirectoryW(root.c_str());
  assert(CreateDirectoryW(root.c_str(), nullptr) ||
         GetLastError() == ERROR_ALREADY_EXISTS);
  return root;
}

void WriteBytes(const std::wstring& path, const void* bytes, size_t length) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  assert(WriteFile(file, bytes, static_cast<DWORD>(length), &written, nullptr));
  assert(written == length);
  CloseHandle(file);
}

// 递归删干净：留下临时目录会让下一次同 pid 运行读到上一轮的文件。
void RemoveTree(const std::wstring& root) {
  WIN32_FIND_DATAW found = {};
  HANDLE search = FindFirstFileW((root + L"\\*").c_str(), &found);
  if (search != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = found.cFileName;
      if (name == L"." || name == L"..") continue;
      const std::wstring path = root + L"\\" + name;
      if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        RemoveTree(path);
      } else {
        DeleteFileW(path.c_str());
      }
    } while (FindNextFileW(search, &found));
    FindClose(search);
  }
  RemoveDirectoryW(root.c_str());
}

void WriteLe32(uint8_t* out, uint32_t value) {
  out[0] = static_cast<uint8_t>(value);
  out[1] = static_cast<uint8_t>(value >> 8);
  out[2] = static_cast<uint8_t>(value >> 16);
  out[3] = static_cast<uint8_t>(value >> 24);
}

void WriteBe32(uint8_t* out, uint32_t value) {
  out[0] = static_cast<uint8_t>(value >> 24);
  out[1] = static_cast<uint8_t>(value >> 16);
  out[2] = static_cast<uint8_t>(value >> 8);
  out[3] = static_cast<uint8_t>(value);
}

// DecryptCfiBlock 的逆。测试自己实现逆变换有「测的是我的逆而不是真解密」的风险，
// 所以下面 main 里第一件事就是 round-trip 自校验：Decrypt(Encrypt(x)) == x。
// 逆推自 hook/malie_cfi.h:52-91，两步各自取逆并倒序：
//   解密 = 先 pivot-XOR 再字变换；所以加密 = 先字逆变换再 pivot-XOR。
void EncryptCfiBlockAtZero(const uint8_t* plain, uint8_t* encrypted) {
  uint32_t words[4] = {};
  std::memcpy(words, plain, sizeof(words));
  const uint32_t block_index = 0;
  words[0] = mal::RotateLeft(words[0],
                             mal::kDiesAmantesCfiKey[(block_index + 12) & 0x1F] ^ 0xA5) ^
             mal::RotateRight(mal::kDiesAmantesCfiRotateKey[0],
                              mal::kDiesAmantesCfiKey[block_index & 0x1F] ^ 0xA5);
  words[1] = mal::RotateRight(words[1],
                              mal::kDiesAmantesCfiKey[(block_index + 15) & 0x1F] ^ 0xA5) ^
             mal::RotateLeft(mal::kDiesAmantesCfiRotateKey[1],
                             mal::kDiesAmantesCfiKey[(block_index + 3) & 0x1F] ^ 0xA5);
  words[2] = mal::RotateLeft(words[2],
                             mal::kDiesAmantesCfiKey[(block_index + 18) & 0x1F] ^ 0xA5) ^
             mal::RotateRight(mal::kDiesAmantesCfiRotateKey[2],
                              mal::kDiesAmantesCfiKey[(block_index + 6) & 0x1F] ^ 0xA5);
  words[3] = mal::RotateRight(words[3],
                              mal::kDiesAmantesCfiKey[(block_index + 21) & 0x1F] ^ 0xA5) ^
             mal::RotateLeft(mal::kDiesAmantesCfiRotateKey[3],
                             mal::kDiesAmantesCfiKey[(block_index + 9) & 0x1F] ^ 0xA5);
  uint8_t pivoted[16] = {};
  std::memcpy(pivoted, words, sizeof(words));
  // block_offset 0 ⇒ pivot_index 0，pivot 值在两步之间保持不变。
  const uint8_t pivot = pivoted[0];
  encrypted[0] = pivoted[0];
  for (uint32_t i = 1; i < 16; ++i) encrypted[i] = pivoted[i] ^ pivot;
}

}  // namespace

int main() {
  // ── 0. 先自校验 Malie CFI 逆变换，后面所有 Malie 正向夹具都建在它之上 ──────────
  {
    uint8_t plain[16] = {'L', 'I', 'B', 'P', 1, 2, 3, 4,
                         5,   6,   7,   8,   9, 10, 11, 12};
    uint8_t encrypted[16] = {};
    uint8_t roundtrip[16] = {};
    EncryptCfiBlockAtZero(plain, encrypted);
    mal::DecryptCfiBlock(0, encrypted, roundtrip);
    assert(std::memcmp(plain, roundtrip, sizeof(plain)) == 0);
  }

  // ── 1. BGI / Ethornell：`*.arc` 的 BURIKO ARC20 魔数 ─────────────────────────
  {
    const std::wstring root = MakeTempRoot(L"bgi_ok");
    // 目录里刻意**没有** BGI.exe，exe 名不是必要条件。
    char archive[64] = {0};
    std::memcpy(archive, ::fushi_voice_hook::bgi::kArc20Signature,
                ::fushi_voice_hook::bgi::kArc20SignatureBytes);
    WriteBytes(root + L"\\data03100.arc", archive, sizeof(archive));
    assert(fushi_voice_hook::MatchesBgiEthornellLayout(root));
    RemoveTree(root);
  }
  {
    const std::wstring root = MakeTempRoot(L"bgi_name_only");
    // 只有一个叫 BGI.exe 的空文件、没有 ARC20 归档 → 名字不是充分条件。
    const char stub[8] = {'M', 'Z', 0, 0, 0, 0, 0, 0};
    WriteBytes(root + L"\\BGI.exe", stub, sizeof(stub));
    const char not_arc20[16] = "PackFile    \0\0\0";
    WriteBytes(root + L"\\data03100.arc", not_arc20, sizeof(not_arc20));
    assert(!fushi_voice_hook::MatchesBgiEthornellLayout(root));
    RemoveTree(root);
  }
  assert(!fushi_voice_hook::MatchesBgiEthornellProfile(nullptr));

  // ── 2. CatSystem2：config\startup.xml + `*.int` 的 KIF\0 魔数（两者缺一不可）──
  {
    const std::wstring root = MakeTempRoot(L"cs2_ok");
    assert(CreateDirectoryW((root + L"\\config").c_str(), nullptr));
    const char xml[] = "<?xml version=\"1.0\"?><startup/>";
    WriteBytes(root + L"\\config\\startup.xml", xml, sizeof(xml) - 1);
    char kif[32] = {0};
    std::memcpy(kif, ::fushi_voice_hook::catsystem2::kIntSignature,
                ::fushi_voice_hook::catsystem2::kIntSignatureBytes);
    WriteBytes(root + L"\\voice.int", kif, sizeof(kif));
    assert(fushi_voice_hook::MatchesCatSystem2Layout(root));
    // 抽掉 startup.xml 后不再匹配：证明它是真判据而非装饰。
    DeleteFileW((root + L"\\config\\startup.xml").c_str());
    assert(!fushi_voice_hook::MatchesCatSystem2Layout(root));
    RemoveTree(root);
  }
  {
    const std::wstring root = MakeTempRoot(L"cs2_bad_magic");
    assert(CreateDirectoryW((root + L"\\config").c_str(), nullptr));
    const char xml[] = "<?xml version=\"1.0\"?><startup/>";
    WriteBytes(root + L"\\config\\startup.xml", xml, sizeof(xml) - 1);
    const char not_kif[8] = {'R', 'I', 'F', 'F', 0, 0, 0, 0};
    WriteBytes(root + L"\\voice.int", not_kif, sizeof(not_kif));
    assert(!fushi_voice_hook::MatchesCatSystem2Layout(root));
    RemoveTree(root);
  }
  assert(!fushi_voice_hook::MatchesCatSystem2Profile(nullptr));

  // ── 3. elf AI6：voice.arc 索引自洽（首条目 packed==unpacked 且 offset==索引末尾）─
  {
    const std::wstring root = MakeTempRoot(L"ai6_ok");
    constexpr uint32_t count = 1;
    const uint32_t index_bytes =
        static_cast<uint32_t>(ai6::kHeaderBytes + count * ai6::kEntryBytes);
    constexpr uint32_t payload = 8;
    std::vector<uint8_t> archive(index_bytes + payload, 0);
    WriteLe32(archive.data(), count);
    uint8_t* record = archive.data() + ai6::kHeaderBytes;
    std::memcpy(record, "voice00001.ogg", 14);
    WriteBe32(record + ai6::kNameBytes + 4, payload);   // packed
    WriteBe32(record + ai6::kNameBytes + 8, payload);   // unpacked
    WriteBe32(record + ai6::kNameBytes + 12, index_bytes);  // offset
    WriteBytes(root + L"\\voice.arc", archive.data(), archive.size());
    // 目录里没有 AI6WIN.exe，照样认得出来。
    assert(fushi_voice_hook::ProbeElfAi6Layout(root, nullptr));

    // packed != unpacked → 索引不自洽 → 不匹配。
    WriteBe32(record + ai6::kNameBytes + 8, payload + 1);
    WriteBytes(root + L"\\voice.arc", archive.data(), archive.size());
    assert(!fushi_voice_hook::ProbeElfAi6Layout(root, nullptr));
    RemoveTree(root);
  }
  assert(!fushi_voice_hook::MatchesElfAi6Profile(nullptr));

  // ── 4. Malie：data2.dat 头 16 字节 CFI 解块后是自洽 LIBP 头 ──────────────────
  {
    const std::wstring root = MakeTempRoot(L"malie_ok");
    uint8_t plain[16] = {0};
    std::memcpy(plain, "LIBP", 4);
    WriteLe32(plain + 4, 2);  // entry_count
    WriteLe32(plain + 8, 1);  // offset_count（必须 <= entry_count）
    uint8_t header[16] = {};
    EncryptCfiBlockAtZero(plain, header);
    // index_bytes = 16 + 2*32 + 1*4 = 84；data_base = AlignUp(84, 4096) = 4096，
    // 两者都必须 <= 文件大小，所以夹具至少 4096 字节。
    std::vector<uint8_t> archive(8192, 0);
    std::memcpy(archive.data(), header, sizeof(header));
    WriteBytes(root + L"\\data2.dat", archive.data(), archive.size());
    // 目录里没有 malie.exe，照样认得出来。
    assert(fushi_voice_hook::MatchesMalieLayout(root));

    // 文件太小 → data_base 越界 → 不匹配（头字节完全相同，只有大小变了）。
    WriteBytes(root + L"\\data2.dat", archive.data(), 1024);
    assert(!fushi_voice_hook::MatchesMalieLayout(root));
    RemoveTree(root);
  }
  {
    const std::wstring root = MakeTempRoot(L"malie_name_only");
    // 只有 malie.exe 和一个解不出 LIBP 的 data2.dat → 名字不是充分条件。
    const char stub[8] = {'M', 'Z', 0, 0, 0, 0, 0, 0};
    WriteBytes(root + L"\\malie.exe", stub, sizeof(stub));
    std::vector<uint8_t> junk(8192, 0x5A);
    WriteBytes(root + L"\\data2.dat", junk.data(), junk.size());
    assert(!fushi_voice_hook::MatchesMalieLayout(root));
    RemoveTree(root);
  }
  assert(!fushi_voice_hook::MatchesMalieProfile(nullptr));

  std::printf("engine_identity_layout_test: ok\n");
  return 0;
}
