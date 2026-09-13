#pragma once
#include <windows.h>
#include <bcrypt.h>
#include "cmvs_dialogue_layout_reader.h"
#include "cmvs_hook_installation.h"
#include "cmvs_shift_transaction.h"

namespace fushi_voice_hook::cmvs_layout {

inline bool MatchesExecutable() {
#ifndef _WIN64
  return false;
#else
  wchar_t path[32768]{};
  const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
  if (length == 0 || length >= 32768) return false;
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  const bool bounded = GetFileSizeEx(file, &size) && size.QuadPart > 0 &&
                       size.QuadPart <= 32 * 1024 * 1024;
  HANDLE mapping = bounded ? CreateFileMappingW(file, nullptr, PAGE_READONLY,
                                                0, 0, nullptr) : nullptr;
  auto* bytes = mapping ? static_cast<uint8_t*>(
      MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0)) : nullptr;
  std::array<uint8_t, 32> digest{};
  bool matches = bytes && BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0,
      bytes, static_cast<ULONG>(size.QuadPart), digest.data(), 32) == 0;
  constexpr char hex[] = "0123456789ABCDEF";
  for (size_t i = 0; matches && i < digest.size(); ++i)
    matches = kExecutableSha256[i * 2] == hex[digest[i] >> 4] &&
              kExecutableSha256[i * 2 + 1] == hex[digest[i] & 15];
  if (bytes) UnmapViewOfFile(bytes);
  if (mapping) CloseHandle(mapping);
  CloseHandle(file);
  return matches;
#endif
}
}  // namespace fushi_voice_hook::cmvs_layout
