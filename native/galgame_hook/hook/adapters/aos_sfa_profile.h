// AOS / SFA 引擎（Princess Sugar・Atelier Kaguya 系）身份探测。
//
// 结构判据（量自真实样本「姫様ＬＯＶＥライフ！」2015-08，2026-09-05）：
// 游戏目录下至少一个 `*.aos` 归档，其头部满足
//   偏移 0..3  : 全零
//   偏移 4..7  : u32
//   偏移 8..11 : u32
//   偏移 12..  : **该归档自身的文件名**，ASCII、NUL 结尾
// 「头里写着自己的文件名」这件事很难被别家格式偶然撞上，而且它同时把
// 「后缀是 .aos 但内容不是」挡在门外。样本里 5 个归档
// （bgm / cv / grp / scr / se.aos，61 MB ~ 2.99 GB）**全部**满足，不是只验了两个就外推。
//
// 运行期还有一个更强的信号：主窗口类名就是 `SFA`（真机实测）。但它进不了这个判据——
// 本函数在**进程启动早期**被调，那时窗口还不存在；窗口类只作台账，以及将来做运行期
// 二次确认时的材料。
//
// exe 名不进判据：样本的 exe 就叫作品名（全角日文），正式版各不相同。
#pragma once

#include <windows.h>

#include <cstdint>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <string>

namespace fushi_voice_hook {

constexpr const wchar_t* kAosArchivePattern = L"\\*.aos";
constexpr size_t kAosHeaderProbeBytes = 64;
constexpr size_t kAosNameOffset = 12;
// 运行期主窗口类名，台账用，不参与身份判据（判据在窗口存在之前就要给出答案）。
constexpr const wchar_t* kAosRuntimeWindowClass = L"SFA";

inline bool AosReadFilePrefix(const std::wstring& path, uint8_t* out, DWORD capacity,
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

// 宽字符文件名与头部里的窄字符名逐字节比（ASCII 大小写不敏感）。归档名都是纯 ASCII；
// 出现非 ASCII 字符一律判不匹配，而不是做任何编码猜测。
inline bool AosHeaderNamesItself(const uint8_t* header, DWORD read,
                                 const wchar_t* file_name) {
  if (read <= kAosNameOffset) return false;
  const uint8_t* stored = header + kAosNameOffset;
  const DWORD available = read - static_cast<DWORD>(kAosNameOffset);
  DWORD i = 0;
  for (; i < available; ++i) {
    const uint8_t c = stored[i];
    if (c == 0) break;
    const wchar_t w = file_name[i];
    if (w == 0 || w > 0x7f || c > 0x7f) return false;
    if (towlower(w) != towlower(static_cast<wchar_t>(c))) return false;
  }
  if (i == 0 || i >= available) return false;  // 空名 / 没读到结尾的 NUL 都不算
  return file_name[i] == 0;                    // 两边必须同时到头
}

inline bool AosArchivePresent(const std::wstring& directory) {
  WIN32_FIND_DATAW found = {};
  const std::wstring pattern = directory + kAosArchivePattern;
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  do {
    if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
    uint8_t header[kAosHeaderProbeBytes] = {0};
    DWORD read = 0;
    const std::wstring path = directory + L"\\" + found.cFileName;
    if (!AosReadFilePrefix(path, header, sizeof(header), &read)) continue;
    if (read <= kAosNameOffset) continue;
    if (std::memcmp(header, "\0\0\0\0", 4) != 0) continue;
    if (!AosHeaderNamesItself(header, read, found.cFileName)) continue;
    matched = true;
    break;
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

// 给定游戏根目录的结构判据；测试用临时目录直接喂它。
inline bool MatchesAosSfaLayout(const std::wstring& directory) {
  return AosArchivePresent(directory);
}

inline bool MatchesAosSfaProfile(const wchar_t*) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  return MatchesAosSfaLayout(executable);
}

}  // namespace fushi_voice_hook
