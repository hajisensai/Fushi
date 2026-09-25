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
//
// Steam 多语言版把这对文件按语言带后缀：CLANNAD Steam 版（SiglusEngine_Steam.exe 1.1.134.0）
// 选简体中文时目录里只有 GameexeZH.dat + SceneZH.pck，没有无后缀的那一对。后缀由 Steam
// 语言决定、发行方随时可以加新语言，所以判据不列语言清单：从目录里实际存在的
// Scene<后缀>.pck 推出后缀，再要求同后缀的 Gameexe<后缀>.dat 存在——仍然是“配置 + 剧本
// 成对出现”这一条，只是允许两者共享一个语言后缀。

#include <cstddef>
#include <string>

namespace fushi_voice_hook {

// Siglus 核心数据文件（两者同时存在才判定，几乎无误报）。
inline const wchar_t* const kSiglusSignatureConfig = L"Gameexe.dat";
inline const wchar_t* const kSiglusSignatureScene = L"Scene.pck";

// 语言后缀上限。实测是两个字母（ZH），留到 8 兜住 ZHTW / JPN 一类写法；再长就不是语言标签，
// 不认，免得 Scene_backup_old.pck 之类的杂物把判据带歪。
inline constexpr size_t kSiglusLanguageSuffixMaxChars = 8;

// `Scene<后缀>.pck` → 后缀。后缀只收 ASCII 字母数字（可为空，即原版 Scene.pck）；前缀与扩展名
// 按 ASCII 大小写不敏感比对，与 Windows 文件系统一致。不是这个形状返回 false。
inline bool SiglusScenePackSuffix(const std::wstring& name, std::wstring* suffix) {
  static const wchar_t kPrefix[] = L"scene";
  static const wchar_t kExtension[] = L".pck";
  const size_t prefix_len = sizeof(kPrefix) / sizeof(kPrefix[0]) - 1;
  const size_t extension_len = sizeof(kExtension) / sizeof(kExtension[0]) - 1;
  if (name.size() < prefix_len + extension_len) return false;
  const size_t suffix_len = name.size() - prefix_len - extension_len;
  if (suffix_len > kSiglusLanguageSuffixMaxChars) return false;
  auto lower = [](wchar_t c) -> wchar_t {
    return (c >= L'A' && c <= L'Z') ? static_cast<wchar_t>(c - L'A' + L'a') : c;
  };
  for (size_t i = 0; i < prefix_len; ++i) {
    if (lower(name[i]) != kPrefix[i]) return false;
  }
  for (size_t i = 0; i < extension_len; ++i) {
    if (lower(name[prefix_len + suffix_len + i]) != kExtension[i]) return false;
  }
  std::wstring result = name.substr(prefix_len, suffix_len);
  for (wchar_t c : result) {
    const bool alnum = (c >= L'0' && c <= L'9') || (c >= L'A' && c <= L'Z') ||
                       (c >= L'a' && c <= L'z');
    if (!alnum) return false;
  }
  if (suffix != nullptr) *suffix = result;
  return true;
}

// 目录是否具备 Siglus 文件夹签名。file_exists(dir, name) 由调用方注入：
//   生产 = Win32 GetFileAttributesW；测试 = 假文件表。
// list_scene_packs(dir, visit) 枚举目录里匹配 `Scene*.pck` 的文件名，对每个名字调
// visit(name)，visit 返回 false 即停止：
//   生产 = FindFirstFileW；测试 = 假文件表。
template <typename FileExists, typename ListScenePacks>
bool DirectoryLooksLikeSiglus(const std::wstring& dir, FileExists file_exists,
                              ListScenePacks list_scene_packs) {
  if (dir.empty()) {
    return false;
  }
  if (file_exists(dir, kSiglusSignatureConfig) &&
      file_exists(dir, kSiglusSignatureScene)) {
    return true;
  }
  bool matched = false;
  list_scene_packs(dir, [&](const std::wstring& name) {
    std::wstring suffix;
    if (!SiglusScenePackSuffix(name, &suffix) || suffix.empty()) return true;
    const std::wstring config = L"Gameexe" + suffix + L".dat";
    if (file_exists(dir, config.c_str())) {
      matched = true;
      return false;
    }
    return true;
  });
  return matched;
}

}  // namespace fushi_voice_hook
