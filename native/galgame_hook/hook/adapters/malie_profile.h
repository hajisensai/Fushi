// Malie（light / Greenwood 系）身份探测。
//
// 结构判据：exe 同级 `data2.dat` 的头 16 字节经 CFI 解块后是一个自洽的 LIBP 头
//（魔数 + 条目数/偏移数与文件大小互不矛盾，见 hook/malie_lib.h 的 ParseLibpHeader）。
//
// exe 名（`malie.exe` / `malie_dsp.exe` / `malie_fabla.exe`）**不进判据**。原实现把名字
// 当先决条件，名字不符时连 `data2.dat` 都不看；而"这个 data2.dat 能不能按 Malie 的
// 格式解开"本身就是比名字强得多的判据——它是内容级的，与发行方怎么给 exe 命名无关。
//
// 关于 CFI 密钥：解密用的是 malie_cfi.h 里那把 Dies Amantes 密钥。它是**内容级**常量
// （归档加密方案），不是 exe 级判据——同一把密钥覆盖整个 Malie 发布系列，改名不影响。
// 但它确实是单一作品系列的密钥：用别的密钥加密的 Malie 归档解不出 LIBP，会在这里判为
// 不匹配。这不是本次改动引入的限制（原实现在 LoadMalieArchive 里同样解不开、只是把
// 失败推迟到 install 阶段），而是 Malie 支持面本身的边界——诊断上"密钥不对"与"根本不是
// Malie"仍然同形，要分辨得靠另一条独立证据，记在 BUG-2153 里待后续。
#pragma once

#include <windows.h>

#include <cstdint>
#include <string>

#include "../malie_cfi.h"
#include "../malie_lib.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

constexpr const wchar_t* kMalieArchiveFileName = L"\\data2.dat";

// 给定游戏根目录的结构判据；测试用临时目录直接喂它。
inline bool MatchesMalieLayout(const std::wstring& directory) {
  const std::wstring archive = directory + kMalieArchiveFileName;
  uint64_t archive_size = 0;
  if (!engine_dir::FileSize(archive, &archive_size) || archive_size == 0) {
    return false;
  }
  // 从根限定 `::fushi_voice_hook::malie`：本头在 dll_main.cpp 里是从匿名命名空间内部被
  // 包的（malie_adapter.inc → generated/adapter_includes.inc → dll_main.cpp:604，在 128
  // 的 `namespace {` 之内），而 malie_lib.h 早在 dll_main.cpp:62 顶层就包过了。include
  // guard 会让里面这次变成空操作，非全限定的 `malie::` 会去 `(匿名)::fushi_voice_hook`
  // 里找、找不到。测试 TU 从全局作用域包本头时，`::` 限定同样成立。
  namespace mal = ::fushi_voice_hook::malie;
  uint8_t encrypted[mal::kLibpHeaderBytes] = {0};
  DWORD read = 0;
  if (!engine_dir::ReadFilePrefix(archive, encrypted, sizeof(encrypted),
                                  &read) ||
      read != sizeof(encrypted)) {
    return false;
  }
  uint8_t decrypted[mal::kLibpHeaderBytes] = {0};
  mal::DecryptCfiBlock(0, encrypted, decrypted);
  mal::LibpHeader header;
  return mal::ParseLibpHeader(decrypted, sizeof(decrypted), archive_size,
                              &header);
}

inline bool MatchesMalieProfile(const wchar_t*) {
  std::wstring directory;
  if (!engine_dir::ModuleDirectory(&directory)) return false;
  return MatchesMalieLayout(directory);
}

}  // namespace fushi_voice_hook
