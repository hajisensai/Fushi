// CMVS（Purple Software 自研引擎）身份探测。
//
// 结构判据（全部来自真实样本 クロノクロック 体験版v2 2015-03-20 的静态 probe，2026-09-04）：
//   * exe 同级 `cmvs.cfg`，文本以 `[CMVS_SYSTEM_MAIN]` 节开头，里面 `SCRIPT_INIT_PATH=data\pack\`；
//   * `data\pack\*.cpz`——CMVS 自有归档，4 字节魔数 `CPZ` + 版本位（样本是 `CPZ6`）；
//     voice.cpz / voice2.cpz / script.cpz / se.cpz 全在这一层。
// exe 名（cmvs32.exe / cmvs64.exe）和 mog2x32/64.dll 只作台账记录，不进判据：Purple 的正式版
// 会把 exe 改成作品名，而 cfg + CPZ 归档是引擎本体的固定形状。
// 判据要求两样**同时**存在，缺一即不匹配（fail closed）：只有 cfg 可能是别的引擎抄的 ini
// 段名，只有 .cpz 后缀也可能是别家格式；CPZ 魔数 + cfg 节名同时命中才是 CMVS。
#pragma once

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <cwchar>
#include <string>

namespace fushi_voice_hook {

constexpr const wchar_t* kCmvsConfigFileName = L"cmvs.cfg";
constexpr const char* kCmvsConfigSection = "[CMVS_SYSTEM_MAIN]";
constexpr const wchar_t* kCmvsPackPattern = L"\\data\\pack\\*.cpz";
constexpr size_t kCmvsConfigProbeBytes = 256;

inline bool CmvsReadFilePrefix(const std::wstring& path, uint8_t* out, DWORD capacity,
                           DWORD* read_out) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD read = 0;
  const bool ok = ReadFile(file, out, capacity, &read, nullptr) != FALSE;
  CloseHandle(file);
  if (!ok) return false;
  *read_out = read;
  return true;
}

// cmvs.cfg 前 256 字节里出现 `[CMVS_SYSTEM_MAIN]`（允许 BOM / 空行前缀）。
inline bool CmvsConfigPresent(const std::wstring& directory) {
  uint8_t prefix[kCmvsConfigProbeBytes] = {0};
  DWORD read = 0;
  if (!CmvsReadFilePrefix(directory + L"\\" + kCmvsConfigFileName, prefix,
                      sizeof(prefix), &read)) {
    return false;
  }
  const size_t needle = strlen(kCmvsConfigSection);
  if (read < needle) return false;
  for (size_t i = 0; i + needle <= read; ++i) {
    if (memcmp(prefix + i, kCmvsConfigSection, needle) == 0) return true;
  }
  return false;
}

// data\pack 下至少一个 *.cpz 以 `CPZ` 魔数开头。
inline bool CmvsPackArchivePresent(const std::wstring& directory) {
  WIN32_FIND_DATAW found = {};
  const std::wstring pattern = directory + kCmvsPackPattern;
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  do {
    if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
    uint8_t magic[4] = {0};
    DWORD read = 0;
    const std::wstring path = directory + L"\\data\\pack\\" + found.cFileName;
    if (CmvsReadFilePrefix(path, magic, sizeof(magic), &read) && read == 4 &&
        memcmp(magic, "CPZ", 3) == 0) {
      matched = true;
      break;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

// 给定游戏根目录的结构判据；测试用临时目录直接喂它。
inline bool MatchesCmvsLayout(const std::wstring& directory) {
  return CmvsConfigPresent(directory) && CmvsPackArchivePresent(directory);
}

inline bool MatchesCmvsProfile(const wchar_t*) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  return MatchesCmvsLayout(executable);
}

}  // namespace fushi_voice_hook
