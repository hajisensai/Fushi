// 引擎身份的共享结构判据原语。
//
// 存在理由（BUG-2153）：exe 文件名和 exe 摘要都是绑**单个发行版**的判据，改名或换版本
// 即失效，而改名恰恰是发行方的常规操作——正式版把 exe 改成作品名、HD/Steam 版另起名字。
// 本仓在 Siglus 上真机踩过这一脚：注入器原本只认 `SiglusEngine.exe`，改名的
// `iroseka_HD.exe` 识别不到 → 走错注入策略 → 被 Enigma 保护壳弹掉
// （见 tests/siglus_launch_test.cpp 头部记录），修法就是换成文件夹结构签名。
//
// 引擎的固定形状在磁盘布局和归档魔数里，不在名字里。新 adapter 的身份判据一律用这里的
// 原语拼，exe 名最多进台账、不进判据。
#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <string>

namespace fushi_voice_hook::engine_dir {

// 读文件开头若干字节。读不到（不存在/占用/空文件）一律 false，不区分——身份判据只关心
// "有没有一个能证明是本引擎的文件"，证不出就是不匹配。
inline bool ReadFilePrefix(const std::wstring& path, uint8_t* out, DWORD capacity,
                           DWORD* read_out) {
  if (out == nullptr || read_out == nullptr || capacity == 0) return false;
  HANDLE file = CreateFileW(
      path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD read = 0;
  const bool ok = ReadFile(file, out, capacity, &read, nullptr) != FALSE;
  CloseHandle(file);
  if (!ok) return false;
  *read_out = read;
  return true;
}

// 主模块所在目录，不带尾反斜杠。取不到路径、或路径里没有反斜杠时返回 false。
inline bool ModuleDirectory(std::wstring* out) {
  if (out == nullptr) return false;
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  out->assign(executable);
  return true;
}

inline bool FileExists(const std::wstring& path) {
  return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// 归档头的自洽校验普遍要拿真实文件大小当上界（"索引长度不能超过文件本身"），
// 所以身份判据这一层就得能读到它。
inline bool FileSize(const std::wstring& path, uint64_t* out) {
  if (out == nullptr) return false;
  WIN32_FILE_ATTRIBUTE_DATA data = {};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) {
    return false;
  }
  if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) return false;
  *out = (static_cast<uint64_t>(data.nFileSizeHigh) << 32) |
         static_cast<uint64_t>(data.nFileSizeLow);
  return true;
}

// `dir\pattern` 命中的普通文件里，是否有一个以 `magic` 开头。
//
// scan_limit 兜住病态目录：某些引擎把上万个同后缀分卷摊在游戏根目录，身份探测跑在
// adapter probe 路径上（每次 Poll 都可能问一次），不能让它退化成全目录扫描。命中即停，
// 正常游戏第一个文件就中。
inline bool DirectoryHasFileStartingWith(const std::wstring& dir,
                                         const wchar_t* pattern,
                                         const void* magic, size_t magic_bytes,
                                         size_t scan_limit = 64) {
  if (pattern == nullptr || magic == nullptr || magic_bytes == 0 ||
      magic_bytes > 64) {
    return false;
  }
  WIN32_FIND_DATAW found = {};
  const std::wstring glob = dir + L"\\" + pattern;
  HANDLE search = FindFirstFileW(glob.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  size_t scanned = 0;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    if (++scanned > scan_limit) break;
    uint8_t prefix[64] = {0};
    DWORD read = 0;
    const std::wstring path = dir + L"\\" + found.cFileName;
    if (ReadFilePrefix(path, prefix, static_cast<DWORD>(magic_bytes), &read) &&
        read == magic_bytes && std::memcmp(prefix, magic, magic_bytes) == 0) {
      matched = true;
      break;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

}  // namespace fushi_voice_hook::engine_dir
