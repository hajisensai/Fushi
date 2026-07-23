#pragma once

namespace hibiki_voice_hook {

inline bool MatchesCatSystem2Profile(const wchar_t*) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  const wchar_t* leaf = wcsrchr(executable, L'\\');
  leaf = leaf == nullptr ? executable : leaf + 1;
  if (_wcsicmp(leaf, L"cs2_open.exe") != 0 &&
      _wcsicmp(leaf, L"cs2.exe") != 0) {
    return false;
  }
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring config =
      std::wstring(executable) + L"\\config\\startup.xml";
  if (GetFileAttributesW(config.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  WIN32_FIND_DATAW found = {};
  const std::wstring pattern = std::wstring(executable) + L"\\*.int";
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  FindClose(search);
  return true;
}

}  // namespace hibiki_voice_hook
