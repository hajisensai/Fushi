// CatSystem2（ねこかいはつ）身份探测。
//
// 结构判据（两条同时成立，fail closed）：
//   * exe 同级 `config\startup.xml`——CatSystem2 的固定启动配置路径；
//   * exe 同级至少一个 `*.int` 以 `KIF\0` 开头——KIF 是 CatSystem2 自有归档魔数。
// 单独一条都不够：`startup.xml` 这个名字别的引擎也可能用，`.int` 后缀更是撞得上；
// 两者同时命中才是 CatSystem2。
//
// exe 名（`cs2_open.exe` / `cs2.exe`）**不进判据**。原实现把名字放在最前面当先决条件，
// 后面的结构判据在名字不符时一行都不跑——等于给改名的发行版判了死刑，而结构证据就在
// 同一个目录里躺着。现在魔数是唯一判据，名字只是历史台账。
#pragma once

#include <windows.h>

#include <string>

#include "../catsystem2_int.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

constexpr const wchar_t* kCatSystem2ConfigRelativePath = L"\\config\\startup.xml";

// 给定游戏根目录的结构判据；测试用临时目录直接喂它。
//
// 魔数从根限定 `::fushi_voice_hook::catsystem2`：本头在 dll_main.cpp 里是从匿名命名空间
// 内部被包的（catsystem2_adapter.inc → generated/adapter_includes.inc →
// dll_main.cpp:604，在 128 的 `namespace {` 之内），而 catsystem2_int.h 早在
// dll_main.cpp:61 顶层就包过了，include guard 会让里面这次变成空操作。
inline bool MatchesCatSystem2Layout(const std::wstring& directory) {
  if (!engine_dir::FileExists(directory + kCatSystem2ConfigRelativePath)) {
    return false;
  }
  return engine_dir::DirectoryHasFileStartingWith(
      directory, L"*.int", ::fushi_voice_hook::catsystem2::kIntSignature,
      ::fushi_voice_hook::catsystem2::kIntSignatureBytes);
}

inline bool MatchesCatSystem2Profile(const wchar_t*) {
  std::wstring directory;
  if (!engine_dir::ModuleDirectory(&directory)) return false;
  return MatchesCatSystem2Layout(directory);
}

}  // namespace fushi_voice_hook
