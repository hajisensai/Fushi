#pragma once

#include <windows.h>

#include <cwchar>
#include <string>

#include "../elf_ai6_arc.h"

namespace fushi_voice_hook {
struct ElfAi6FileIdentity {
  DWORD volume_serial = 0;
  DWORD file_index_high = 0;
  DWORD file_index_low = 0;
};

inline bool ReadElfAi6FileIdentity(HANDLE file, ElfAi6FileIdentity* out) {
  if (file == INVALID_HANDLE_VALUE || out == nullptr) return false;
  BY_HANDLE_FILE_INFORMATION info = {};
  if (!GetFileInformationByHandle(file, &info)) return false;
  if (info.nFileIndexHigh == 0 && info.nFileIndexLow == 0) return false;
  out->volume_serial = info.dwVolumeSerialNumber;
  out->file_index_high = info.nFileIndexHigh;
  out->file_index_low = info.nFileIndexLow;
  return true;
}

inline bool SameElfAi6FileIdentity(const ElfAi6FileIdentity& left,
                                   const ElfAi6FileIdentity& right) {
  return left.volume_serial == right.volume_serial &&
      left.file_index_high == right.file_index_high &&
      left.file_index_low == right.file_index_low;
}

inline bool ProbeElfAi6Profile(ElfAi6FileIdentity* identity_out) {
  wchar_t executable[MAX_PATH] = {0};
  if (GetModuleFileNameW(nullptr, executable, MAX_PATH) == 0) return false;
  wchar_t* slash = wcsrchr(executable, L'\\');
  const wchar_t* leaf = slash == nullptr ? executable : slash + 1;
  if (_wcsicmp(leaf, L"AI6WIN.exe") != 0 || slash == nullptr) return false;
  *slash = 0;
  const std::wstring archive = std::wstring(executable) + L"\\voice.arc";
  HANDLE file = CreateFileW(archive.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER file_size = {};
  ElfAi6FileIdentity identity;
  uint8_t prefix[elf_ai6::kHeaderBytes + elf_ai6::kEntryBytes] = {0};
  DWORD read = 0;
  const bool read_ok = GetFileSizeEx(file, &file_size) &&
      ReadElfAi6FileIdentity(file, &identity) &&
      ReadFile(file, prefix, sizeof(prefix), &read, nullptr) &&
      read == sizeof(prefix);
  CloseHandle(file);
  if (!read_ok || file_size.QuadPart <= 0) return false;
  uint64_t index_bytes = 0;
  if (!elf_ai6::IndexSize(prefix, sizeof(prefix), nullptr, &index_bytes) ||
      index_bytes > static_cast<uint64_t>(file_size.QuadPart)) {
    return false;
  }
  const uint8_t* record = prefix + elf_ai6::kHeaderBytes;
  const uint32_t packed = elf_ai6::ReadBe32(
      record + elf_ai6::kNameBytes + 4);
  const uint32_t unpacked = elf_ai6::ReadBe32(
      record + elf_ai6::kNameBytes + 8);
  const uint64_t offset = elf_ai6::ReadBe32(
      record + elf_ai6::kNameBytes + 12);
  const bool valid = packed >= 4 && packed <= elf_ai6::kMaxVoiceBytes &&
      packed == unpacked && offset == index_bytes &&
      packed <= static_cast<uint64_t>(file_size.QuadPart) - offset;
  if (valid && identity_out != nullptr) *identity_out = identity;
  return valid;
}

inline bool MatchesElfAi6Profile(const wchar_t*) {
  return ProbeElfAi6Profile(nullptr);
}
}  // namespace fushi_voice_hook
