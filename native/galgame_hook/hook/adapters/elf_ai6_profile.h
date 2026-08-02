#pragma once

#include "../elf_ai6_arc.h"

namespace hibiki_voice_hook {
inline bool MatchesElfAi6Profile(const wchar_t*) {
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
  uint8_t prefix[elf_ai6::kHeaderBytes + elf_ai6::kEntryBytes] = {0};
  DWORD read = 0;
  const bool read_ok = GetFileSizeEx(file, &file_size) &&
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
  return packed >= 4 && packed <= elf_ai6::kMaxVoiceBytes &&
      packed == unpacked && offset == index_bytes &&
      packed <= static_cast<uint64_t>(file_size.QuadPart) - offset;
}
}  // namespace hibiki_voice_hook
