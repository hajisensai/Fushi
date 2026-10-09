// LucaSystem (Prototype) identity probe.
//
// Structural rule, both halves required:
//   1. `system.cnf` next to the executable is the engine's tab-separated
//      boot configuration: it declares TARGET_PLATFORM and the design
//      SCREEN_WIDTH / SCREEN_HEIGHT;
//   2. the `files` directory beside it holds at least one `*.PAK` whose whole
//      index reads under exactly one of the engine's index layouts
//      (luca_pak.h).  A magic or a file name alone is not enough.
//
// The executable name, title and hash are never consulted.  The hook sites
// are resolved separately from the image's own code (luca_text_core.h); a
// process that matches here but whose code does not carry the MESSAGE shape
// installs nothing.
#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "../luca_pak.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

// Real indexes are 8 bytes per member plus a name table; larger files are not
// used as identity evidence (the scan moves on).
constexpr uint32_t kLucaProbeIndexBytes = 16u << 20;
constexpr DWORD kLucaSystemCnfBytes = 4096u;

// `text` is the start of a system.cnf.  A key counts only at the start of a
// line and only when followed by whitespace (the engine's `KEY<TAB>value`).
inline bool LucaSystemCnfHasKey(const std::string& text, const char* key) {
  const size_t key_length = std::strlen(key);
  size_t line = 0u;
  while (line < text.size()) {
    if (text.compare(line, key_length, key) == 0 &&
        line + key_length < text.size() &&
        (text[line + key_length] == '\t' || text[line + key_length] == ' ')) {
      return true;
    }
    const size_t next = text.find('\n', line);
    if (next == std::string::npos) break;
    line = next + 1u;
  }
  return false;
}

// Integer value of `KEY<ws>value` at the start of a line; false when absent
// or not a positive integer.
inline bool LucaSystemCnfInt(const std::string& text, const char* key,
                             int32_t* out) {
  const size_t key_length = std::strlen(key);
  size_t line = 0u;
  while (line < text.size()) {
    if (text.compare(line, key_length, key) == 0) {
      size_t at = line + key_length;
      if (at < text.size() && (text[at] == '\t' || text[at] == ' ')) {
        while (at < text.size() && (text[at] == '\t' || text[at] == ' ')) ++at;
        int64_t value = 0;
        size_t digits = 0u;
        while (at < text.size() && text[at] >= '0' && text[at] <= '9' &&
               digits < 6u) {
          value = value * 10 + (text[at] - '0');
          ++at;
          ++digits;
        }
        if (digits == 0u || value <= 0) return false;
        *out = static_cast<int32_t>(value);
        return true;
      }
    }
    const size_t next = text.find('\n', line);
    if (next == std::string::npos) break;
    line = next + 1u;
  }
  return false;
}

inline bool IsLucaSystemCnf(const std::string& text) {
  return LucaSystemCnfHasKey(text, "TARGET_PLATFORM") &&
         LucaSystemCnfHasKey(text, "SCREEN_WIDTH") &&
         LucaSystemCnfHasKey(text, "SCREEN_HEIGHT");
}

inline bool IsLucaArchiveFile(const std::wstring& path) {
  namespace luca = ::fushi_voice_hook::luca;
  uint64_t size = 0u;
  uint8_t header_bytes[luca::kPakHeaderBytes] = {0};
  DWORD read = 0;
  luca::PakIndex header;
  if (!engine_dir::FileSize(path, &size) ||
      !engine_dir::ReadFilePrefix(path, header_bytes, sizeof(header_bytes),
                                  &read) ||
      !luca::ParsePakHeader(header_bytes, read, size, &header) ||
      luca::PakIndexBytes(header) > kLucaProbeIndexBytes) {
    return false;
  }
  const DWORD index_bytes = static_cast<DWORD>(luca::PakIndexBytes(header));
  std::vector<uint8_t> head(index_bytes);
  return engine_dir::ReadFilePrefix(path, head.data(), index_bytes, &read) &&
         read == index_bytes &&
         luca::ParsePakIndex(head.data(), head.size(), size, nullptr,
                             nullptr) == luca::PakIndexResult::kValid;
}

inline bool DirectoryHasLucaArchive(const std::wstring& directory,
                                    size_t scan_limit) {
  WIN32_FIND_DATAW found = {};
  const std::wstring glob = directory + L"\\*.pak";
  HANDLE search = FindFirstFileW(glob.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  size_t scanned = 0u;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    if (++scanned > scan_limit) break;
    if (IsLucaArchiveFile(directory + L"\\" + found.cFileName)) {
      matched = true;
      break;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

inline bool MatchesLucaLayout(const std::wstring& directory,
                              size_t scan_limit = 32) {
  char text[kLucaSystemCnfBytes] = {0};
  DWORD read = 0;
  if (!engine_dir::ReadFilePrefix(directory + L"\\system.cnf",
                                  reinterpret_cast<uint8_t*>(text),
                                  sizeof(text), &read) ||
      !IsLucaSystemCnf(std::string(text, read))) {
    return false;
  }
  return DirectoryHasLucaArchive(directory + L"\\files", scan_limit);
}

// The design screen the engine lays text out in (SCREEN_WIDTH/HEIGHT).
inline bool ReadLucaDesignSize(int32_t* width, int32_t* height) {
  std::wstring directory;
  char text[kLucaSystemCnfBytes] = {0};
  DWORD read = 0;
  if (!engine_dir::ModuleDirectory(&directory) ||
      !engine_dir::ReadFilePrefix(directory + L"\\system.cnf",
                                  reinterpret_cast<uint8_t*>(text),
                                  sizeof(text), &read)) {
    return false;
  }
  const std::string cnf(text, read);
  return IsLucaSystemCnf(cnf) && LucaSystemCnfInt(cnf, "SCREEN_WIDTH", width) &&
         LucaSystemCnfInt(cnf, "SCREEN_HEIGHT", height);
}

inline bool MatchesLucaProfile(const wchar_t*) {
  std::wstring directory;
  if (!engine_dir::ModuleDirectory(&directory)) return false;
  return MatchesLucaLayout(directory);
}

}  // namespace fushi_voice_hook
