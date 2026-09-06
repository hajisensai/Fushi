// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// Unreal IoStore 身份判据用真临时目录验：判据读的是磁盘布局（Binaries\Win64 目录形状 +
// Content\Paks\*.utoc 的 IoStore 魔数），只有文件系统自己能作证。
// 覆盖：完整布局、目录形状对但没有归档、有 .utoc 但魔数不对、归档对但目录形状不对、
// 以及路径拆分本身的边界（尾部分隔符、无父目录）。
#include "../hook/adapters/unreal_iostore_profile.h"

#include <cassert>
#include <cstdio>
#include <string>

namespace {

std::wstring MakeTempRoot(const wchar_t* tag) {
  wchar_t temp[MAX_PATH] = {0};
  assert(GetTempPathW(MAX_PATH, temp) != 0);
  std::wstring root = std::wstring(temp) + L"fushi_unreal_test_" + tag + L"_" +
                      std::to_wstring(GetCurrentProcessId());
  assert(CreateDirectoryW(root.c_str(), nullptr) ||
         GetLastError() == ERROR_ALREADY_EXISTS);
  return root;
}

void WriteBytes(const std::wstring& path, const char* bytes, size_t length) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  assert(file != INVALID_HANDLE_VALUE);
  DWORD written = 0;
  assert(WriteFile(file, bytes, static_cast<DWORD>(length), &written, nullptr));
  assert(written == length);
  CloseHandle(file);
}

// <root>\Game\Binaries\Win64 与 <root>\Game\Content\Paks，即真实样本的形状。
std::wstring MakeGameTree(const std::wstring& root) {
  CreateDirectoryW((root + L"\\Game").c_str(), nullptr);
  CreateDirectoryW((root + L"\\Game\\Binaries").c_str(), nullptr);
  CreateDirectoryW((root + L"\\Game\\Binaries\\Win64").c_str(), nullptr);
  CreateDirectoryW((root + L"\\Game\\Content").c_str(), nullptr);
  CreateDirectoryW((root + L"\\Game\\Content\\Paks").c_str(), nullptr);
  return root + L"\\Game\\Binaries\\Win64";
}

void RemoveTree(const std::wstring& root) {
  DeleteFileW((root + L"\\Game\\Content\\Paks\\global.utoc").c_str());
  DeleteFileW((root + L"\\Game\\Content\\Paks\\other.utoc").c_str());
  DeleteFileW((root + L"\\Game\\Content\\Paks\\aaa_broken.utoc").c_str());
  RemoveDirectoryW((root + L"\\Game\\Content\\Paks").c_str());
  RemoveDirectoryW((root + L"\\Game\\Content").c_str());
  RemoveDirectoryW((root + L"\\Game\\Binaries\\Win64").c_str());
  RemoveDirectoryW((root + L"\\Game\\Binaries").c_str());
  RemoveDirectoryW((root + L"\\Game").c_str());
  RemoveDirectoryW(root.c_str());
}

// 真实样本 global.utoc 的前 20 字节形状：16 字节魔数 + 版本 6。
const char kToc[] = "-==--==--==--==-\x06\x00\x00\x00";
// 后缀相同但不是 IoStore 的东西（这里借 Ogg 头当反例）。
const char kNotToc[] = "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

}  // namespace

int main() {
  // 1. 完整布局 → 匹配。判据是「至少一个」，所以先枚举到的 .utoc 魔数不对时必须继续扫。
  //    坏的那个叫 aaa_broken 而不是 other：NTFS 按名字序枚举，other.utoc 会排在
  //    global.utoc 之后，第一轮就命中好的并 break，续扫循环根本走不到
  //    （把续扫退化成「只看第一个文件」，旧用例全部照样变绿）。
  {
    const std::wstring root = MakeTempRoot(L"full");
    const std::wstring bin = MakeGameTree(root);
    WriteBytes(root + L"\\Game\\Content\\Paks\\aaa_broken.utoc", kNotToc, sizeof(kNotToc) - 1);
    WriteBytes(root + L"\\Game\\Content\\Paks\\global.utoc", kToc, sizeof(kToc) - 1);
    assert(fushi_voice_hook::UnrealShippingBinaryLayout(bin));
    assert(fushi_voice_hook::UnrealIoStoreArchivePresent(root + L"\\Game"));
    assert(fushi_voice_hook::MatchesUnrealIostoreLayout(bin));
    // 尾部带分隔符也必须判成同一件事。
    assert(fushi_voice_hook::MatchesUnrealIostoreLayout(bin + L"\\"));
    RemoveTree(root);
  }
  // 2. 目录形状对但 Paks 下没有归档 → 不匹配（fail closed）。
  {
    const std::wstring root = MakeTempRoot(L"no_archive");
    const std::wstring bin = MakeGameTree(root);
    assert(fushi_voice_hook::UnrealShippingBinaryLayout(bin));
    assert(!fushi_voice_hook::MatchesUnrealIostoreLayout(bin));
    RemoveTree(root);
  }
  // 3. 有 .utoc 但魔数不对 → 不匹配（只看后缀会误判）。
  {
    const std::wstring root = MakeTempRoot(L"bad_magic");
    const std::wstring bin = MakeGameTree(root);
    WriteBytes(root + L"\\Game\\Content\\Paks\\global.utoc", kNotToc, sizeof(kNotToc) - 1);
    assert(!fushi_voice_hook::UnrealIoStoreArchivePresent(root + L"\\Game"));
    assert(!fushi_voice_hook::MatchesUnrealIostoreLayout(bin));
    RemoveTree(root);
  }
  // 4. 归档没问题，但二进制目录不是 Binaries\Win64 → 不匹配
  //    （任何把 exe 放在别处的程序都不该因为同目录树里有个 utoc 而被认成 Unreal）。
  {
    const std::wstring root = MakeTempRoot(L"bad_layout");
    MakeGameTree(root);
    WriteBytes(root + L"\\Game\\Content\\Paks\\global.utoc", kToc, sizeof(kToc) - 1);
    assert(!fushi_voice_hook::UnrealShippingBinaryLayout(root + L"\\Game"));
    assert(!fushi_voice_hook::MatchesUnrealIostoreLayout(root + L"\\Game"));
    // Win64 在位、但父目录不叫 Binaries：同样不认。
    CreateDirectoryW((root + L"\\Game\\Content\\Win64").c_str(), nullptr);
    assert(!fushi_voice_hook::UnrealShippingBinaryLayout(root + L"\\Game\\Content\\Win64"));
    RemoveDirectoryW((root + L"\\Game\\Content\\Win64").c_str());
    RemoveTree(root);
  }
  // 5. 路径拆分的边界：空串、纯分隔符、无父目录，都不能崩也不能误判成匹配。
  {
    assert(fushi_voice_hook::UnrealLastSegment(L"").empty());
    assert(fushi_voice_hook::UnrealLastSegment(L"\\\\").empty());
    assert(fushi_voice_hook::UnrealLastSegment(L"Win64") == L"Win64");
    assert(fushi_voice_hook::UnrealLastSegment(L"a\\b\\Win64\\") == L"Win64");
    assert(fushi_voice_hook::UnrealParentDirectory(L"Win64").empty());
    assert(fushi_voice_hook::UnrealParentDirectory(L"a\\b\\Win64") == L"a\\b");
    assert(!fushi_voice_hook::UnrealShippingBinaryLayout(L""));
    assert(!fushi_voice_hook::UnrealShippingBinaryLayout(L"Win64"));
    assert(!fushi_voice_hook::MatchesUnrealIostoreLayout(L""));
  }
  // 6. 测试进程自己的目录不是 Unreal 游戏 → 进程级探测为假。
  assert(!fushi_voice_hook::MatchesUnrealIostoreProfile(nullptr));
  // 7. 目录级引擎签名（DirectoryLooksLikeUnrealIostore）。injector 的启动器识别与子进程
  //    身份判定共用它，两种形态都得认，而且启动器自己那层必须为假：
  //    LooksLikeLauncherLayout 的定义就是「自己这层没签名、子目录有」，外层 stub
  //    目录一旦也判真，跟随子进程就不会被自动打开，真游戏进程永远拿不到 hook。
  {
    const std::wstring root = MakeTempRoot(L"dirsig");
    const std::wstring bin = MakeGameTree(root);
    // 先不放归档：两种形态都不能成立（fail closed）。
    assert(!fushi_voice_hook::DirectoryLooksLikeUnrealIostore(root + L"\\Game"));
    assert(!fushi_voice_hook::DirectoryLooksLikeUnrealIostore(bin));
    WriteBytes(root + L"\\Game\\Content\\Paks\\global.utoc", kToc, sizeof(kToc) - 1);
    // 形态一：<Game> 根本身（启动器扫子目录时看到的）。
    assert(fushi_voice_hook::DirectoryLooksLikeUnrealIostore(root + L"\\Game"));
    // 形态二：shipping 二进制目录（从子进程镜像路径反推时看到的）。
    assert(fushi_voice_hook::DirectoryLooksLikeUnrealIostore(bin));
    // 启动器自己那层（归档在子目录里）必须为假。
    assert(!fushi_voice_hook::DirectoryLooksLikeUnrealIostore(root));
    // 空串不崩也不误判。
    assert(!fushi_voice_hook::DirectoryLooksLikeUnrealIostore(L""));
    RemoveTree(root);
  }
  std::printf("unreal_iostore_adapter_test: ok\n");
  return 0;
}
