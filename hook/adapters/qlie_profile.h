#pragma once

#include "../qlie_pack.h"

namespace hibiki_voice_hook {

inline volatile LONG g_qlie_profile_active = 0;

inline bool HasQliePackSignature(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {};
  uint8_t tail[96] = {};
  DWORD read = 0;
  bool found = false;
  if (GetFileSizeEx(file, &size) && size.QuadPart >= 16) {
    const DWORD bytes = static_cast<DWORD>(
        (std::min)(size.QuadPart, static_cast<LONGLONG>(sizeof(tail))));
    LARGE_INTEGER offset = {};
    offset.QuadPart = size.QuadPart - bytes;
    if (SetFilePointerEx(file, offset, nullptr, FILE_BEGIN) &&
        ReadFile(file, tail, bytes, &read, nullptr) && read == bytes) {
      found = qlie::ContainsFilePackSignature(tail, read);
    }
  }
  CloseHandle(file);
  return found;
}

inline bool MatchesQlieProfile(const wchar_t*) {
  wchar_t executable[520] = {};
  if (GetModuleFileNameW(nullptr, executable,
                         static_cast<DWORD>(std::size(executable))) == 0) {
    return false;
  }
  wchar_t* slash = wcsrchr(executable, L'\\');
  if (slash == nullptr) return false;
  *slash = 0;
  const std::wstring root(executable);
  const std::wstring decoder = root + L"\\DLL\\wuvorbis.dll";
  const std::wstring pack = root + L"\\GameData\\data0.pack";
  return GetFileAttributesW(decoder.c_str()) != INVALID_FILE_ATTRIBUTES &&
         GetFileAttributesW(pack.c_str()) != INVALID_FILE_ATTRIBUTES &&
         HasQliePackSignature(pack);
}

}  // namespace hibiki_voice_hook
