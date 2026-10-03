// FVP（Favorite View Point，FAVORITE）身份探测。
//
// 结构判据：exe 同级目录里有一个**自洽的 HCB 脚本**——首 u32 指向文件内的 trailer，
// trailer 的入口地址落在字节码区、标题字段与 syscall 名单逐项在界内且 NUL 结尾、
// 名单读完恰好落在文件尾（容许少量填充），并且名单里有 `TextPrint`（argc 2）这个
// 对白输出点（fvp_format.h ParseHcbTrailer）。HCB 是该引擎自己的脚本容器，别家不用；
// 只看扩展名不够，必须整条 trailer 自洽。
//
// exe 名、游戏标题、hcb 文件名都**不进判据**（同一引擎的作品各叫各的：World.exe /
// HoshimemoEH_HD.exe）。
#pragma once

#include <windows.h>

#include <cstddef>
#include <string>
#include <vector>

#include "../fvp_format.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

// 单个文件是否是自洽的 FVP HCB 脚本（有界读：头 4 字节 + trailer，trailer 最多 64 KiB）。
inline bool IsFvpHcbFile(const std::wstring& path) {
  namespace fvp = ::fushi_voice_hook::fvp;
  uint64_t size = 0u;
  if (!engine_dir::FileSize(path, &size) || size < 16u ||
      size > 0xffffffffull) {
    return false;
  }
  uint8_t head[4] = {0};
  DWORD read = 0;
  if (!engine_dir::ReadFilePrefix(path, head, sizeof(head), &read) ||
      read != sizeof(head)) {
    return false;
  }
  const uint32_t trailer_offset = fvp::ReadLe32(head);
  if (trailer_offset < 8u || trailer_offset >= size ||
      size - trailer_offset > fvp::kMaxHcbTrailerBytes) {
    return false;
  }
  const DWORD trailer_bytes = static_cast<DWORD>(size - trailer_offset);
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  std::vector<uint8_t> trailer(trailer_bytes);
  LARGE_INTEGER at = {};
  at.QuadPart = trailer_offset;
  DWORD got = 0;
  const bool ok = SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE &&
                  ReadFile(file, trailer.data(), trailer_bytes, &got,
                           nullptr) != FALSE &&
                  got == trailer_bytes;
  CloseHandle(file);
  fvp::HcbSummary summary;
  return ok &&
         fvp::ParseHcbTrailer(trailer.data(), trailer.size(), trailer_offset,
                              size, &summary) &&
         summary.has_text_print;
}

// 给定游戏根目录的结构判据；测试用临时目录直接喂它。scan_limit 防止 probe 退化成
// 全目录扫描：正常 FVP 游戏只有一两个 .hcb。
inline bool MatchesFvpLayout(const std::wstring& directory,
                             size_t scan_limit = 8) {
  WIN32_FIND_DATAW found = {};
  const std::wstring glob = directory + L"\\*.hcb";
  HANDLE search = FindFirstFileW(glob.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  size_t scanned = 0;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    if (++scanned > scan_limit) break;
    if (IsFvpHcbFile(directory + L"\\" + found.cFileName)) {
      matched = true;
      break;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

inline bool MatchesFvpProfile(const wchar_t*) {
  std::wstring directory;
  if (!engine_dir::ModuleDirectory(&directory)) return false;
  return MatchesFvpLayout(directory);
}

}  // namespace fushi_voice_hook
