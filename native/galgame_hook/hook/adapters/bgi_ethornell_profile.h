// BGI / Ethornell（BURIKO General Interpreter）身份探测。
//
// 结构判据：exe 同级目录里至少一个 `*.arc` 是**自洽的 BGI 归档索引**——以
// `BURIKO ARC20`（新）或 `PackFile    `（旧，12 字节含 4 个空格）开头，count 合法、
// 索引不超过文件，且前若干条目名字在字段内 NUL 结尾、首条目 offset 为 0、条目首尾相接、
// 成员落在文件内（bgi::IsArcIdentityPrefix）。两代归档都由本 adapter 的解析层读得了
// （bgi_arc.h），所以都认领。
//
// 只看魔数不够：`PackFile` 是个泛词（QLiE 的包尾签名是相近的 `FilePackVer*`，同一个
// 词根被别家当前缀用并不意外），12 字节魔数之外再加索引自洽性，才不会把别家的 .arc
// 认成 BGI。同一目录里的非 BGI .arc（例如 Eustia 体验版的 MPEG-PS 视频 data06010.arc）
// 只是跳过，不影响认领。
//
// exe 名（`BGI.exe`）**不进判据**。它曾经是唯一判据，那意味着任何改过名的 BGI 发行版
// 整个 adapter 一行都不跑（BUG-2153）；反过来，一个恰好叫 BGI.exe 但没有 BGI 归档的
// 进程也不再被误认领。
#pragma once

#include <windows.h>

#include <cstddef>
#include <string>

#include "../bgi_arc.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

// 单个文件是否是自洽的 BGI 归档（有界读：头 + 前 8 条目，ARC20 最多 1040 字节）。
inline bool IsBgiArchiveFile(const std::wstring& path) {
  constexpr DWORD kPrefixBytes =
      static_cast<DWORD>(::fushi_voice_hook::bgi::kArcHeaderBytes +
                         8 * ::fushi_voice_hook::bgi::kArc20EntryBytes);
  uint8_t prefix[kPrefixBytes] = {0};
  DWORD read = 0;
  uint64_t size = 0;
  return engine_dir::FileSize(path, &size) &&
         engine_dir::ReadFilePrefix(path, prefix, kPrefixBytes, &read) &&
         ::fushi_voice_hook::bgi::IsArcIdentityPrefix(prefix, read, size);
}

// 给定游戏根目录的结构判据；测试用临时目录直接喂它。
// 从根限定 `::fushi_voice_hook::bgi`：本头在 dll_main.cpp 里是从匿名命名空间内部被包的
// （adapters/*.inc → generated/adapter_includes.inc → dll_main.cpp），而 bgi_arc.h 早在
// dll_main.cpp 顶层就包过了。include guard 会让里面这次变成空操作，于是非全限定的
// `bgi::` 会去 `(匿名)::fushi_voice_hook` 里找、找不到。测试 TU 从全局作用域包本头时，
// `::` 限定同样成立。
//
// scan_limit 与 engine_dir::DirectoryHasFileStartingWith 同理：probe 可能每次 Poll 都问，
// 不能退化成全目录扫描；命中即停，正常 BGI 游戏第一个 .arc 就中。
inline bool MatchesBgiEthornellLayout(const std::wstring& directory,
                                      size_t scan_limit = 64) {
  WIN32_FIND_DATAW found = {};
  const std::wstring glob = directory + L"\\*.arc";
  HANDLE search = FindFirstFileW(glob.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  size_t scanned = 0;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    if (++scanned > scan_limit) break;
    if (IsBgiArchiveFile(directory + L"\\" + found.cFileName)) {
      matched = true;
      break;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

inline bool MatchesBgiEthornellProfile(const wchar_t*) {
  std::wstring directory;
  if (!engine_dir::ModuleDirectory(&directory)) return false;
  return MatchesBgiEthornellLayout(directory);
}

}  // namespace fushi_voice_hook
