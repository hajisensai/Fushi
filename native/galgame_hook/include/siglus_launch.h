#pragma once

// Siglus 引擎 launch 识别。
//
// launch 模式默认 CREATE_SUSPENDED 早注入（抢在 WinMain 前下钩）。但 Siglus 游戏的 Enigma
// 保护壳会拒绝挂起态早注入——注入器必须改为“正常启动 → 等保护壳退出、游戏主窗口出现 → 再附着”。
// 原判定只认 exe 名严格等于 SiglusEngine.exe；而 HD/Steam/同人改名版把 exe 重命名成游戏名
// （如 iroseka_HD.exe），于是走了早注入、被 Enigma 弹掉，表现为 engine.launch_or_inject_failed。
//
// exe 名不可靠，但 Siglus 的核心数据文件 Gameexe.dat（配置）+ Scene.pck（剧本）始终随 exe 同
// 目录，改名不影响。用文件夹签名识别（与 LooksLikeUnityRuntime 同一思路），把决策做成可注入
// file_exists 谓词的纯逻辑，便于离线单测、不碰真实文件系统。

#include <string>

namespace hibiki_voice_hook {

// Siglus 核心数据文件（两者同时存在才判定，几乎无误报）。
inline const wchar_t* const kSiglusSignatureConfig = L"Gameexe.dat";
inline const wchar_t* const kSiglusSignatureScene = L"Scene.pck";

// 目录是否具备 Siglus 文件夹签名。file_exists(dir, name) 由调用方注入：
//   生产 = Win32 GetFileAttributesW；测试 = 假文件表。
template <typename FileExists>
bool DirectoryLooksLikeSiglus(const std::wstring& dir, FileExists file_exists) {
  if (dir.empty()) {
    return false;
  }
  return file_exists(dir, kSiglusSignatureConfig) &&
         file_exists(dir, kSiglusSignatureScene);
}

}  // namespace hibiki_voice_hook
