// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// AOS/SFA 身份判据用真临时目录验：判据读的是磁盘字节（*.aos 头部是否写着自身文件名），
// 只有文件系统自己能作证。覆盖：真实头形状、名字对不上、后缀对但前 4 字节非零、
// 名字没写完（截断）、大小写不同、非 ASCII 名、空目录。
#include "../hook/adapters/aos_sfa_profile.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>

namespace {

std::wstring MakeTempRoot(const wchar_t* tag) {
  wchar_t temp[MAX_PATH] = {0};
  assert(GetTempPathW(MAX_PATH, temp) != 0);
  std::wstring root = std::wstring(temp) + L"fushi_aos_test_" + tag + L"_" +
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

// 真实样本 scr.aos 的头形状：4 字节零 + 两个小端 u32 + 自身文件名 + NUL 填充。
std::string MakeHeader(const char* stored_name, bool zero_prefix = true) {
  std::string h(64, '\0');
  if (!zero_prefix) h[0] = '\x01';
  h[4] = '\x31'; h[5] = '\x2c';
  h[8] = '\x20'; h[9] = '\x2b';
  const size_t n = std::strlen(stored_name);
  assert(12 + n < h.size());
  std::memcpy(&h[12], stored_name, n);
  return h;
}

void Remove(const std::wstring& root, const wchar_t* file) {
  DeleteFileW((root + L"\\" + file).c_str());
}

}  // namespace

int main() {
  // 1. 真实形状 → 匹配。同目录里先放一个不合规的 .aos，证明判据是「至少一个」而不是「第一个」。
  {
    const std::wstring root = MakeTempRoot(L"real");
    const std::string bad = MakeHeader("someone_else.aos");
    const std::string good = MakeHeader("scr.aos");
    WriteBytes(root + L"\\aaa.aos", bad.data(), bad.size());
    WriteBytes(root + L"\\scr.aos", good.data(), good.size());
    assert(fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"aaa.aos");
    Remove(root, L"scr.aos");
    RemoveDirectoryW(root.c_str());
  }
  // 2. 头里写的名字不是自己 → 不匹配（这条挡住「随便一个 .aos 后缀文件」）。
  {
    const std::wstring root = MakeTempRoot(L"wrongname");
    const std::string h = MakeHeader("other.aos");
    WriteBytes(root + L"\\scr.aos", h.data(), h.size());
    assert(!fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"scr.aos");
    RemoveDirectoryW(root.c_str());
  }
  // 3. 名字对但前 4 字节不是零 → 不匹配。
  {
    const std::wstring root = MakeTempRoot(L"prefix");
    const std::string h = MakeHeader("scr.aos", /*zero_prefix=*/false);
    WriteBytes(root + L"\\scr.aos", h.data(), h.size());
    assert(!fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"scr.aos");
    RemoveDirectoryW(root.c_str());
  }
  // 4. 名字是自己的前缀（截断）→ 不匹配：两边必须同时到头，否则 "s.aos" 会命中 "scr.aos"。
  {
    const std::wstring root = MakeTempRoot(L"prefixname");
    const std::string h = MakeHeader("scr");
    WriteBytes(root + L"\\scr.aos", h.data(), h.size());
    assert(!fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"scr.aos");
    RemoveDirectoryW(root.c_str());
  }
  // 5. 大小写不同 → 仍然匹配（归档名是 ASCII，判据大小写不敏感）。
  {
    const std::wstring root = MakeTempRoot(L"case");
    const std::string h = MakeHeader("SCR.AOS");
    WriteBytes(root + L"\\scr.aos", h.data(), h.size());
    assert(fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"scr.aos");
    RemoveDirectoryW(root.c_str());
  }
  // 6. 文件名含非 ASCII → 一律不匹配，而不是去猜编码。
  //
  //    必须用**自命名**的归档才能测到 ASCII 门：文件叫 `é.aos`（U+00E9）、
  //    头里存的是单字节 0xE9 '.' 'a' 'o' 's'。去掉 ASCII 门后
  //    `towlower(0xE9) == towlower(0xE9)` 恢复成立，它就会被认成 AOS 游戏——
  //    这才是这条用例要挡的东西。旧写法把文件叫 `あ.aos` 而头里写 `scr.aos`，
  //    两个名字本来就不同，走的是用例 2 已覆盖的「名字对不上」分支；
  //    变异实测：把 ASCII 门删掉，旧用例 8 组全部照样绿。
  {
    const std::wstring root = MakeTempRoot(L"nonascii");
    std::string h(64, '\0');
    h[4] = '\x31'; h[5] = '\x2c';
    h[8] = '\x20'; h[9] = '\x2b';
    h[12] = '\xe9'; h[13] = '.'; h[14] = 'a'; h[15] = 'o'; h[16] = 's';
    WriteBytes(root + L"\\\u00e9.aos", h.data(), h.size());
    assert(!fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"\u00e9.aos");
    // 旧形状（名字本来就不同）也一并留着，不交叉覆盖不代表该删。
    const std::string mismatched = MakeHeader("scr.aos");
    WriteBytes(root + L"\\あ.aos", mismatched.data(), mismatched.size());
    assert(!fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"あ.aos");
    RemoveDirectoryW(root.c_str());
  }
  // 7. 空目录 / 太短的文件 → 不匹配且不崩。
  {
    const std::wstring root = MakeTempRoot(L"empty");
    assert(!fushi_voice_hook::MatchesAosSfaLayout(root));
    WriteBytes(root + L"\\tiny.aos", "\0\0\0\0", 4);
    assert(!fushi_voice_hook::MatchesAosSfaLayout(root));
    Remove(root, L"tiny.aos");
    RemoveDirectoryW(root.c_str());
  }
  // 8. 测试进程自己的目录不是 AOS 游戏 → 进程级探测为假。
  assert(!fushi_voice_hook::MatchesAosSfaProfile(nullptr));
  std::printf("aos_sfa_adapter_test: ok\n");
  return 0;
}
