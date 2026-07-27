#pragma once

#include <cwchar>

namespace hibiki_voice_hook {

inline bool MatchesBgiEthornellProfile(const wchar_t* module_name) {
  wchar_t executable[MAX_PATH] = {0};
  const wchar_t* candidate = module_name;
  if (candidate == nullptr) {
    if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
    const wchar_t* slash = wcsrchr(executable, L'\\');
    candidate = slash == nullptr ? executable : slash + 1;
  }
  return candidate != nullptr && _wcsicmp(candidate, L"BGI.exe") == 0;
}

}  // namespace hibiki_voice_hook
