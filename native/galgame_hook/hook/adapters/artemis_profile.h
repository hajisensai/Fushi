#pragma once

namespace hibiki_voice_hook {

inline bool MatchesArtemisProfile(const wchar_t*) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  std::wstring runtime = std::wstring(executable) + L"\\iarsys64.dll";
  if (GetFileAttributesW(runtime.c_str()) == INVALID_FILE_ATTRIBUTES) {
    runtime = std::wstring(executable) + L"\\iarsys.dll";
    if (GetFileAttributesW(runtime.c_str()) == INVALID_FILE_ATTRIBUTES) {
      return false;
    }
  }
  WIN32_FIND_DATAW found = {};
  const std::wstring pattern = std::wstring(executable) + L"\\*.pfs";
  HANDLE search = FindFirstFileW(pattern.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  FindClose(search);
  return true;
}

}  // namespace hibiki_voice_hook
