#ifndef HIBIKI_LUNA_HOOK_CONFIG_H_
#define HIBIKI_LUNA_HOOK_CONFIG_H_

#include <algorithm>
#include <cwctype>
#include <string>
#include <vector>

namespace hibiki_voice_hook {

// 已在对应游戏真机中验证过的版本专用文本 hook。固定模块偏移必须同时匹配
// 可执行文件名与游戏目录，避免误用于同引擎的其它版本。
inline std::vector<std::wstring> KnownLunaHookCodesForExecutable(
    const std::wstring& executable) {
  const size_t slash = executable.find_last_of(L"\\/");
  std::wstring basename = slash == std::wstring::npos
                              ? executable
                              : executable.substr(slash + 1);
  std::wstring lower = executable;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](wchar_t c) { return std::towlower(c); });
  std::transform(basename.begin(), basename.end(), basename.begin(),
                 [](wchar_t c) { return std::towlower(c); });
  // 9-nine-ここのつここのかここのいろ（Episode 1）正文渲染路径。
  // Luna 的通用 KiriKiriZ hook 只会读到存档元数据；该 EmbedKrkrZ hook 在
  // D:\9-nine\9-nine-Episode 1\nine_kokoiro.exe 真机上验证能逐句输出画面正文。
  if (basename == L"nine_kokoiro.exe" &&
      lower.find(L"9-nine-episode 1") != std::wstring::npos) {
    return {L"EXHVXN0@2198:nine_kokoiro.exe"};
  }
  return {};
}

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_LUNA_HOOK_CONFIG_H_
