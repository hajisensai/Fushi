#pragma once

namespace hibiki_voice_hook {

inline bool MatchesMalieProfile(const wchar_t*) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  const wchar_t* leaf = wcsrchr(executable, L'\\');
  leaf = leaf == nullptr ? executable : leaf + 1;
  if (_wcsicmp(leaf, L"malie.exe") != 0 &&
      _wcsicmp(leaf, L"malie_dsp.exe") != 0 &&
      _wcsicmp(leaf, L"malie_fabla.exe") != 0) {
    return false;
  }
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring archive = std::wstring(executable) + L"\\data2.dat";
  return GetFileAttributesW(archive.c_str()) != INVALID_FILE_ATTRIBUTES;
}

}  // namespace hibiki_voice_hook
