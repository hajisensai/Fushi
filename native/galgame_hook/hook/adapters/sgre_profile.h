#pragma once

#include <windows.h>

#include <string>

namespace fushi_voice_hook {

// SGRE = M2 的 wind3d11 运行时（STEINS;GATE RE:BOOT 等）。归档取原始语音的能力只能在
// 这个 profile 匹配时启用，绝不能装在通用 XAudio2 中间件上（CLAUDE.md：共享中间件不得
// 仅凭 DLL/exe 名启用）。
inline volatile LONG g_sgre_profile_active = 0;

// 身份判据是**运行时的目录布局**，不是可执行文件名。
//
// 为什么不能拿可执行文件名去 `_wcsicmp`：
//   * exe 名是发行渠道的属性，不是引擎的属性。同一 wind3d11 运行时换渠道/改名/加壳
//     启动器后名字就变，能力随之静默消失，而用户看到的只是「突然取不到语音」。
//   * 反过来，任何人把自己的游戏改成那个名字就能打开这条路径。
//   * 本仓既有范式都是结构签名：QLIE 查 DLL/wuvorbis.dll + GameData/data0.pack 并校验
//     pack 尾部签名；Siglus 的 detection.directory_files_all 查 Gameexe.dat + Scene.pck。
//
// wind3d11data 下这对无头 body blob 是该运行时的资源布局：角色语音在 voice_body.bin，
// BGM/SE 在 sound_body.bin。这个分离正是「归档命中 ⇒ 角色语音」这条推理的前提，所以
// 两个文件都必须在——只有 voice_body.bin 而没有 sound_body.bin 说明不是这套布局，
// 命中也证明不了角色身份。
//
// 误判的代价被下游兜死：即使 profile 误匹配，负载仍要与归档**逐字节**全等才会被当成
// 角色语音资源，匹配不上就退回运行时重建的通用 xWMA 路径。所以这里的判据只需要足够
// 窄到不误开销，不需要承担正确性。
inline bool SgreRuntimeDirectory(std::wstring* directory) {
  if (directory == nullptr) return false;
  wchar_t module_path[MAX_PATH] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, module_path,
      static_cast<DWORD>(sizeof(module_path) / sizeof(module_path[0])));
  if (chars == 0 || chars >= sizeof(module_path) / sizeof(module_path[0])) {
    return false;
  }
  std::wstring path(module_path, chars);
  const size_t slash = path.find_last_of(L"/\\");
  if (slash == std::wstring::npos) return false;
  path.resize(slash + 1);
  path += L"wind3d11data\\";
  *directory = path;
  return true;
}

inline bool SgreVoiceArchivePath(std::wstring* path) {
  std::wstring directory;
  if (path == nullptr || !SgreRuntimeDirectory(&directory)) return false;
  *path = directory + L"voice_body.bin";
  return true;
}

inline bool MatchesSgreProfile(const wchar_t*) {
  std::wstring directory;
  if (!SgreRuntimeDirectory(&directory)) return false;
  const std::wstring voice = directory + L"voice_body.bin";
  const std::wstring sound = directory + L"sound_body.bin";
  return GetFileAttributesW(voice.c_str()) != INVALID_FILE_ATTRIBUTES &&
         GetFileAttributesW(sound.c_str()) != INVALID_FILE_ATTRIBUTES;
}

inline bool SgreProfileActive() {
  return InterlockedCompareExchange(&g_sgre_profile_active, 0, 0) != 0;
}

}  // namespace fushi_voice_hook
