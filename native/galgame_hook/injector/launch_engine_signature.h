// 注入器的「目录是否带引擎数据签名」判据。启动器识别（LooksLikeLauncherLayout）与子进程
// 选择（ChildProcessCandidate::has_engine_signature）都问它，所以放头文件让单测测到注入器
// 实际调用的同一个函数，而不是测各引擎判据再假设注入器把它们接上了。
//
// Siglus（Gameexe[语言].dat + Scene[语言].pck）、UE IoStore（Content\Paks\*.utoc 的 16 字节
// TOC 魔数）与 CatSystem2（config\startup.xml + KIF 魔数的 *.int）各出一条；再加引擎时在
// 这里多写一个 || 即可，判据本身不用动。都要求数据文件真实存在/魔数成立，不认裸目录名。
// CatSystem2 复用 hook 侧同一份身份判据：体验版常见「根目录 WCBOOTMENU 启动器 +
// data\cs2.exe」布局（BUG-2930），启动器那层没有签名。
#pragma once

#include <string>

#include "adapters/catsystem2_profile.h"
#include "siglus_launch_win32.h"
#include "unreal_launch.h"

namespace fushi_voice_hook {

inline bool DirectoryHasEngineSignature(const std::wstring& dir) {
  return DirectoryLooksLikeSiglusOnDisk(dir) ||
         DirectoryLooksLikeUnrealIostore(dir) || MatchesCatSystem2Layout(dir);
}

}  // namespace fushi_voice_hook
