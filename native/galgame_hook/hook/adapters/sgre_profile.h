#pragma once

#include <windows.h>
#include <bcrypt.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "sgre_lookup.h"
#include "sgre_voice_archive.h"

#pragma comment(lib, "bcrypt.lib")

namespace fushi_voice_hook {

inline constexpr std::array<uint8_t, 32> kSgreExecutableSha256 = {
    0x75, 0xa8, 0x3a, 0x0e, 0x2a, 0x7e, 0x22, 0x05,
    0x54, 0x17, 0xae, 0x04, 0x74, 0xb4, 0x7b, 0xe9,
    0x84, 0x18, 0xc4, 0xe4, 0x2c, 0x69, 0x5c, 0x54,
    0x8b, 0x55, 0x87, 0x05, 0xc4, 0x04, 0xb9, 0xd8,
};

inline bool MatchesSgreExecutableHash(const uint8_t* digest,
                                      size_t digest_bytes) {
  if (digest == nullptr || digest_bytes != kSgreExecutableSha256.size()) {
    return false;
  }
  uint8_t difference = 0;
  for (size_t i = 0; i < digest_bytes; ++i) {
    difference |= digest[i] ^ kSgreExecutableSha256[i];
  }
  return difference == 0;
}

inline bool Sha256FileForSgreProfile(const wchar_t* path,
                                     std::array<uint8_t, 32>* digest) {
  if (path == nullptr || digest == nullptr) return false;
  HANDLE file = CreateFileW(path, GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_bytes = 0;
  DWORD hash_bytes = 0;
  DWORD result_bytes = 0;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                        nullptr, 0) == 0;
  if (ok) {
    ok = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                           reinterpret_cast<PUCHAR>(&object_bytes),
                           sizeof(object_bytes), &result_bytes, 0) == 0;
  }
  if (ok) {
    ok = BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH,
                           reinterpret_cast<PUCHAR>(&hash_bytes),
                           sizeof(hash_bytes), &result_bytes, 0) == 0 &&
         hash_bytes == digest->size();
  }
  std::vector<uint8_t> hash_object(object_bytes);
  if (ok) {
    ok = BCryptCreateHash(algorithm, &hash, hash_object.data(), object_bytes,
                          nullptr, 0, 0) == 0;
  }
  std::array<uint8_t, 64 * 1024> buffer = {};
  while (ok) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &read, nullptr)) {
      ok = false;
      break;
    }
    if (read == 0) break;
    ok = BCryptHashData(hash, buffer.data(), read, 0) == 0;
  }
  if (ok) {
    ok = BCryptFinishHash(hash, digest->data(),
                          static_cast<ULONG>(digest->size()), 0) == 0;
  }
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file);
  return ok;
}

inline bool SgreVoiceArchivePath(std::wstring* archive_path) {
  if (archive_path == nullptr) return false;
  wchar_t executable[32768] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable,
      static_cast<DWORD>(sizeof(executable) / sizeof(executable[0])));
  if (chars == 0 || chars >= sizeof(executable) / sizeof(executable[0])) {
    return false;
  }
  std::wstring path(executable, chars);
  const size_t slash = path.find_last_of(L"/\\");
  if (slash == std::wstring::npos) return false;
  path.resize(slash + 1);
  path += L"wind3d11data\\voice_body.bin";
  *archive_path = std::move(path);
  return true;
}

inline bool MatchesSgreProfile(const wchar_t*) {
  wchar_t executable[32768] = {};
  const DWORD chars = GetModuleFileNameW(
      nullptr, executable,
      static_cast<DWORD>(sizeof(executable) / sizeof(executable[0])));
  if (chars == 0 || chars >= sizeof(executable) / sizeof(executable[0])) {
    return false;
  }
  std::array<uint8_t, 32> digest = {};
  if (!Sha256FileForSgreProfile(executable, &digest) ||
      !MatchesSgreExecutableHash(digest.data(), digest.size())) {
    return false;
  }
  std::wstring archive_path;
  return SgreVoiceArchivePath(&archive_path) &&
         GetFileAttributesW(archive_path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

}  // namespace fushi_voice_hook
