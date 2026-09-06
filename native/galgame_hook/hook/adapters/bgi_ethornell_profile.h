// BGI / Ethornell（BURIKO General Interpreter）身份探测。
//
// 结构判据：exe 同级目录里至少一个 `*.arc` 以 `BURIKO ARC20` 开头。
//
// exe 名（`BGI.exe`）**不进判据**。它曾经是唯一判据，那意味着任何改过名的 BGI 发行版
// 整个 adapter 一行都不跑——语音归档就摆在旁边也认不出来。判据换成归档魔数后，改名不再
// 影响识别；反过来，一个恰好叫 BGI.exe 但没有 ARC20 归档的进程也不再被误认领。
//
// 只认 ARC20 而不认更老的 BGI 归档版本，是**故意**的：本 adapter 的 install() 只装
// ARC20 语音钩子（bgi_ethornell_adapter.inc 的 TryHookBgiArcVoice），认领一个读不了的
// 归档版本只会把"已支持"喊出去却什么都拿不到。能读什么就认什么。
#pragma once

#include <windows.h>

#include <cstddef>
#include <string>

#include "../bgi_arc.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

// 给定游戏根目录的结构判据；测试用临时目录直接喂它。
// 从根限定 `::fushi_voice_hook::bgi`：本头在 dll_main.cpp 里是从匿名命名空间内部被包的
// （adapters/*.inc → generated/adapter_includes.inc → dll_main.cpp:604，在 128 的
// `namespace {` 之内），而 bgi_arc.h 早在 dll_main.cpp:59 顶层就包过了。include guard 会
// 让里面这次变成空操作，于是非全限定的 `bgi::` 会去 `(匿名)::fushi_voice_hook` 里找、
// 找不到。测试 TU 从全局作用域包本头时，`::` 限定同样成立。
inline bool MatchesBgiEthornellLayout(const std::wstring& directory) {
  return engine_dir::DirectoryHasFileStartingWith(
      directory, L"*.arc", ::fushi_voice_hook::bgi::kArc20Signature,
      ::fushi_voice_hook::bgi::kArc20SignatureBytes);
}

inline bool MatchesBgiEthornellProfile(const wchar_t*) {
  std::wstring directory;
  if (!engine_dir::ModuleDirectory(&directory)) return false;
  return MatchesBgiEthornellLayout(directory);
}

}  // namespace fushi_voice_hook
