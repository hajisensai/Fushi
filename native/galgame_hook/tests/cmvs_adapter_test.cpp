// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// CMVS 身份判据用真临时目录验：判据读的是磁盘布局（cfg 节名 + CPZ 魔数），只有文件系统自己
// 能作证。四种布局：完整（匹配）、只有 cfg、只有 .cpz 但魔数不对、cfg 节名不对。
#include "../hook/adapters/cmvs_profile.h"

#include <cassert>
#include <cstdio>
#include <string>

namespace {

std::wstring MakeTempRoot(const wchar_t* tag) {
  wchar_t temp[MAX_PATH] = {0};
  assert(GetTempPathW(MAX_PATH, temp) != 0);
  std::wstring root = std::wstring(temp) + L"fushi_cmvs_test_" + tag + L"_" +
                      std::to_wstring(GetCurrentProcessId());
  assert(CreateDirectoryW(root.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS);
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

void MakePackDir(const std::wstring& root) {
  CreateDirectoryW((root + L"\\data").c_str(), nullptr);
  CreateDirectoryW((root + L"\\data\\pack").c_str(), nullptr);
}

void RemoveTree(const std::wstring& root) {
  DeleteFileW((root + L"\\cmvs.cfg").c_str());
  DeleteFileW((root + L"\\data\\pack\\voice.cpz").c_str());
  DeleteFileW((root + L"\\data\\pack\\script.cpz").c_str());
  RemoveDirectoryW((root + L"\\data\\pack").c_str());
  RemoveDirectoryW((root + L"\\data").c_str());
  RemoveDirectoryW(root.c_str());
}

const char kConfig[] = "\xEF\xBB\xBF\r\n[CMVS_SYSTEM_MAIN]\r\nSCRIPT_INIT_PATH=data\\pack\\\r\n";
const char kOtherConfig[] = "[OTHER_ENGINE]\r\nSCRIPT_INIT_PATH=data\\pack\\\r\n";
const char kCpz6[] = "CPZ6\x00\x11\x22\x33";
const char kNotCpz[] = "OggS\x00\x02\x00\x00";

}  // namespace

int main() {
  // 1. 完整布局（BOM + 空行前缀的 cfg、CPZ6 归档）→ 匹配。
  {
    const std::wstring root = MakeTempRoot(L"full");
    MakePackDir(root);
    WriteBytes(root + L"\\cmvs.cfg", kConfig, sizeof(kConfig) - 1);
    WriteBytes(root + L"\\data\\pack\\script.cpz", kNotCpz, sizeof(kNotCpz) - 1);
    WriteBytes(root + L"\\data\\pack\\voice.cpz", kCpz6, sizeof(kCpz6) - 1);
    assert(fushi_voice_hook::CmvsConfigPresent(root));
    assert(fushi_voice_hook::CmvsPackArchivePresent(root));
    assert(fushi_voice_hook::MatchesCmvsLayout(root));
    RemoveTree(root);
  }
  // 2. 只有 cfg，没有归档 → 不匹配（fail closed）。
  {
    const std::wstring root = MakeTempRoot(L"cfg_only");
    MakePackDir(root);
    WriteBytes(root + L"\\cmvs.cfg", kConfig, sizeof(kConfig) - 1);
    assert(!fushi_voice_hook::MatchesCmvsLayout(root));
    RemoveTree(root);
  }
  // 3. .cpz 后缀但魔数不是 CPZ → 不匹配。
  {
    const std::wstring root = MakeTempRoot(L"bad_magic");
    MakePackDir(root);
    WriteBytes(root + L"\\cmvs.cfg", kConfig, sizeof(kConfig) - 1);
    WriteBytes(root + L"\\data\\pack\\voice.cpz", kNotCpz, sizeof(kNotCpz) - 1);
    assert(!fushi_voice_hook::CmvsPackArchivePresent(root));
    assert(!fushi_voice_hook::MatchesCmvsLayout(root));
    RemoveTree(root);
  }
  // 4. cfg 节名不是 CMVS 的 → 不匹配。
  {
    const std::wstring root = MakeTempRoot(L"bad_cfg");
    MakePackDir(root);
    WriteBytes(root + L"\\cmvs.cfg", kOtherConfig, sizeof(kOtherConfig) - 1);
    WriteBytes(root + L"\\data\\pack\\voice.cpz", kCpz6, sizeof(kCpz6) - 1);
    assert(!fushi_voice_hook::CmvsConfigPresent(root));
    assert(!fushi_voice_hook::MatchesCmvsLayout(root));
    RemoveTree(root);
  }
  // 5. 测试进程自己的目录不是 CMVS 游戏 → 进程级探测为假。
  assert(!fushi_voice_hook::MatchesCmvsProfile(nullptr));
  std::printf("cmvs_adapter_test: ok\n");
  return 0;
}
