#pragma once

// siglus_launch.h 目录签名的 Win32 落地：注入器（launch 策略 / 子进程识别）与 hook DLL
// （IsSiglusEngine）共用同一份磁盘判据，不各写一个谓词。

#include <windows.h>

#include <cstddef>
#include <string>

#include "siglus_launch.h"

namespace fushi_voice_hook {

// 普通文件存在（目录不算）。
inline bool SiglusRegularFileExists(const std::wstring& dir, const wchar_t* name) {
  const std::wstring path = dir + L"\\" + name;
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// 枚举 `dir\Scene*.pck` 的普通文件名。scan_limit 兜住病态目录：探测跑在注入器轮询与
// adapter probe 路径上，不能退化成全目录扫描；正常游戏只有一两个剧本包。
template <typename Visit>
void ForEachSiglusScenePackOnDisk(const std::wstring& dir, Visit visit,
                                  size_t scan_limit = 16) {
  if (dir.empty()) return;
  const std::wstring pattern = dir + L"\\Scene*.pck";
  WIN32_FIND_DATAW data = {};
  HANDLE find = FindFirstFileExW(pattern.c_str(), FindExInfoBasic, &data,
                                 FindExSearchNameMatch, nullptr, 0);
  if (find == INVALID_HANDLE_VALUE) return;
  size_t scanned = 0;
  do {
    if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    if (++scanned > scan_limit) break;
    if (!visit(std::wstring(data.cFileName))) break;
  } while (FindNextFileW(find, &data));
  FindClose(find);
}

inline bool DirectoryLooksLikeSiglusOnDisk(const std::wstring& dir) {
  return DirectoryLooksLikeSiglus(
      dir, SiglusRegularFileExists,
      [](const std::wstring& d, auto visit) {
        ForEachSiglusScenePackOnDisk(d, visit);
      });
}

}  // namespace fushi_voice_hook
