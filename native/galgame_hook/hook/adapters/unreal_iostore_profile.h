// Unreal Engine（IoStore 打包形态）身份探测的 hook 侧入口。
// 结构判据本体在 `include/unreal_launch.h`（**唯一真相源**，injector 的
// LooksLikeUnrealRuntime 调的是同一份），这里只负责把当前进程的模块目录喂给它——
// 判据写两遍迟早会分叉，那正是「身份说不清」这类 bug 的温床。
#pragma once

#include <windows.h>

#include <cwchar>
#include <string>

#include "unreal_launch.h"

namespace fushi_voice_hook {

inline bool MatchesUnrealIostoreProfile(const wchar_t*) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  return MatchesUnrealIostoreLayout(executable);
}

}  // namespace fushi_voice_hook
