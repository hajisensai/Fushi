// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

// BGI / CatSystem2 / elf AI6 三个引擎的磁盘结构身份判据（BUG-2153）；Malie 只留负向一档。
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
#include "../include/launcher_layout.h"
#include "../injector/launch_engine_signature.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

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

}  // namespace

int main() {
  // ── 1. BGI / Ethornell：`*.arc` 是自洽的 BURIKO ARC20 或 PackFile 索引 ───────
  // 两代格式各一份：1 条目、成员 8 字节、首条目 offset 0。
  const auto bgi_archive = [](bool arc20) {
    namespace bgi = ::fushi_voice_hook::bgi;
    const size_t entry = arc20 ? bgi::kArc20EntryBytes : bgi::kPackFileEntryBytes;
    const size_t name = arc20 ? bgi::kArc20NameBytes : bgi::kPackFileNameBytes;
    std::vector<uint8_t> a(bgi::kArcHeaderBytes + entry + 8, 0);
    std::memcpy(a.data(), arc20 ? bgi::kArc20Signature : bgi::kPackFileSignature,
                bgi::kArcSignatureBytes);
    WriteLe32(a.data() + 12, 1);
    std::memcpy(a.data() + bgi::kArcHeaderBytes, "00010", 5);
    WriteLe32(a.data() + bgi::kArcHeaderBytes + name + 4, 8);
    return a;
  };
  for (const bool arc20 : {true, false}) {
    const std::wstring root = MakeTempRoot(arc20 ? L"bgi_arc20" : L"bgi_packfile");
    // 目录里刻意**没有** BGI.exe，exe 名不是必要条件；同目录另放一个非 BGI 的 .arc
    // （旧版样本里就有 MPEG-PS 视频包），不影响认领。
    const uint8_t mpeg[16] = {0, 0, 1, 0xBA, 0x21, 0, 1, 0, 1, 0x80, 0xA2, 0x61};
    WriteBytes(root + L"\\data06010.arc", mpeg, sizeof(mpeg));
    const std::vector<uint8_t> archive = bgi_archive(arc20);
    WriteBytes(root + L"\\data04001.arc", archive.data(), archive.size());
    assert(fushi_voice_hook::MatchesBgiEthornellLayout(root));
    RemoveTree(root);
  }
  {
    const std::wstring root = MakeTempRoot(L"bgi_name_only");
    // 只有一个叫 BGI.exe 的空文件、归档只有魔数没有自洽索引 → 名字与魔数都不是充分条件。
    const char stub[8] = {'M', 'Z', 0, 0, 0, 0, 0, 0};
    WriteBytes(root + L"\\BGI.exe", stub, sizeof(stub));
    const char magic_only[16] = "PackFile    \0\0\0";
    WriteBytes(root + L"\\data03100.arc", magic_only, sizeof(magic_only));
    char arc20_magic_only[16] = {0};
    std::memcpy(arc20_magic_only, ::fushi_voice_hook::bgi::kArc20Signature,
                ::fushi_voice_hook::bgi::kArc20SignatureBytes);
    arc20_magic_only[12] = 1;
    WriteBytes(root + L"\\data03110.arc", arc20_magic_only,
               sizeof(arc20_magic_only));
    assert(!fushi_voice_hook::MatchesBgiEthornellLayout(root));
    RemoveTree(root);
  }
  {
    const std::wstring root = MakeTempRoot(L"bgi_foreign_arc");
    // 别家引擎的 .arc：相近词根（QLiE 的 FilePackVer / PackFileVer）与 elf AI6 的
    // 「首 u32 = 条目数」形状，都不能被 BGI 认领。
    const char qlie_like[32] = "PackFileVer3.1";
    WriteBytes(root + L"\\data.arc", qlie_like, sizeof(qlie_like));
    std::vector<uint8_t> ai6(256, 0);
    WriteLe32(ai6.data(), 1);
    WriteBytes(root + L"\\voice.arc", ai6.data(), ai6.size());
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
  // BUG-2930：体验版「根目录 WCBOOTMENU 启动器 + data\cs2.exe」。注入器的启动器判据
  // （LooksLikeLauncherLayout + DirectoryHasEngineSignature）必须靠同一份 CatSystem2
  // 判据在 data\ 认出真游戏；根目录本身就是 CatSystem2（Grisaia 形态）时不算启动器。
  {
    const std::wstring root = MakeTempRoot(L"cs2_bootmenu");
    const std::wstring data = root + L"\\data";
    assert(CreateDirectoryW(data.c_str(), nullptr));
    assert(CreateDirectoryW((data + L"\\config").c_str(), nullptr));
    const char xml[] = "<?xml version=\"1.0\"?><startup/>";
    WriteBytes(data + L"\\config\\startup.xml", xml, sizeof(xml) - 1);
    char kif[32] = {0};
    std::memcpy(kif, ::fushi_voice_hook::catsystem2::kIntSignature,
                ::fushi_voice_hook::catsystem2::kIntSignatureBytes);
    WriteBytes(data + L"\\scene.int", kif, sizeof(kif));
    const char stub[] = "MZ";
    WriteBytes(root + L"\\bootmenu.exe", stub, sizeof(stub) - 1);
    assert(CreateDirectoryW((root + L"\\manual").c_str(), nullptr));

    // 注入器实际调用的那一个函数，不是 MatchesCatSystem2Layout 本身：注入器漏接
    // CatSystem2 这一条时这里必须变红。
    auto is_game_dir = [](const std::wstring& dir) {
      return fushi_voice_hook::DirectoryHasEngineSignature(dir);
    };
    auto list_dirs = [](const std::wstring& dir) {
      std::vector<std::wstring> out;
      WIN32_FIND_DATAW found = {};
      HANDLE search = FindFirstFileW((dir + L"\\*").c_str(), &found);
      if (search == INVALID_HANDLE_VALUE) return out;
      do {
        const std::wstring name = found.cFileName;
        if (name == L"." || name == L"..") continue;
        if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) continue;
        out.push_back(dir + L"\\" + name);
      } while (FindNextFileW(search, &found));
      FindClose(search);
      return out;
    };
    assert(fushi_voice_hook::LooksLikeLauncherLayout(
        root, fushi_voice_hook::kLauncherLayoutMaxDepth, is_game_dir,
        list_dirs));
    // 子目录只有 startup.xml、没有 KIF 归档：不是 CatSystem2，启动器判据随之失效。
    DeleteFileW((data + L"\\scene.int").c_str());
    assert(!fushi_voice_hook::LooksLikeLauncherLayout(
        root, fushi_voice_hook::kLauncherLayoutMaxDepth, is_game_dir,
        list_dirs));
    WriteBytes(data + L"\\scene.int", kif, sizeof(kif));
    // 根目录自己就带签名（cs2.exe 与 KIF 同级）：被启动的就是游戏，不是启动器。
    assert(CreateDirectoryW((root + L"\\config").c_str(), nullptr));
    WriteBytes(root + L"\\config\\startup.xml", xml, sizeof(xml) - 1);
    WriteBytes(root + L"\\scene.int", kif, sizeof(kif));
    assert(!fushi_voice_hook::LooksLikeLauncherLayout(
        root, fushi_voice_hook::kLauncherLayoutMaxDepth, is_game_dir,
        list_dirs));
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

  // ── 4. Malie：身份不看磁盘，看主模块里能否从结构解析出 "CFI" I/O scheme 表
  //（hook/adapters/malie_engine_io_core.h；正反夹具在 tests/malie_engine_io_test.cpp）。
  // 测试进程自己的映像没有这张表 → 不得误认领。
  assert(!fushi_voice_hook::MatchesMalieProfile(nullptr));

  std::printf("engine_identity_layout_test: ok\n");
  return 0;
}
