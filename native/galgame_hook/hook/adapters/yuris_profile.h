// YU-RIS identity probe.
//
// Structural rule: next to the game executable (its own directory or the
// `pac` subdirectory the engine searches) there is at least one `*.ypf` whose
// 32-byte header is a valid YPF header and whose first entries parse under
// one of the engine's index layouts (yuris_ypf.h: name-length table variant x
// 32/64-bit member offsets, every member after the index and inside the file).
// A magic alone is not enough: the first entries must agree with the layout.
//
// The executable name, title and hash are never consulted.  The lookup and
// text sites are resolved separately from the image's own code
// (yuris_lookup_core.h); a YPF-carrying process whose code does not match
// installs no hook there.
#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <string>

#include "../yuris_ypf.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

// Header + the first entries (bounded read).  The index walk stops at the
// end of the prefix: a prefix that holds at least `kPrefixEntries` entries
// must parse them all under a single layout candidate.
inline bool IsYurisArchivePrefix(const uint8_t* prefix, size_t prefix_bytes,
                                 uint64_t file_size) {
  namespace yuris = ::fushi_voice_hook::yuris;
  constexpr uint32_t kPrefixEntries = 4u;
  yuris::YpfHeader header;
  if (!yuris::ParseYpfHeader(prefix, prefix_bytes, file_size, &header)) {
    return false;
  }
  const size_t index_bytes = header.index_end - yuris::kYpfHeaderBytes;
  const size_t available = prefix_bytes - yuris::kYpfHeaderBytes;
  const uint8_t* index = prefix + yuris::kYpfHeaderBytes;
  const size_t usable = available < index_bytes ? available : index_bytes;
  const uint32_t wanted =
      header.count < kPrefixEntries ? header.count : kPrefixEntries;
  for (const bool swapped : {true, false}) {
    for (const uint32_t width : {4u, 8u}) {
      const yuris::YpfLayout layout{swapped, width};
      size_t cursor = 0u;
      uint32_t parsed = 0u;
      while (parsed < wanted &&
             yuris::ReadYpfEntry(index, usable, header, layout, file_size,
                                 &cursor, nullptr)) {
        ++parsed;
      }
      if (parsed == wanted) return true;
    }
  }
  return false;
}

inline bool IsYurisArchiveFile(const std::wstring& path) {
  constexpr DWORD kPrefixBytes = 4096u;
  uint8_t prefix[kPrefixBytes] = {0};
  DWORD read = 0;
  uint64_t size = 0;
  return engine_dir::FileSize(path, &size) &&
         engine_dir::ReadFilePrefix(path, prefix, kPrefixBytes, &read) &&
         IsYurisArchivePrefix(prefix, read, size);
}

inline bool DirectoryHasYurisArchive(const std::wstring& directory,
                                     size_t scan_limit) {
  WIN32_FIND_DATAW found = {};
  const std::wstring glob = directory + L"\\*.ypf";
  HANDLE search = FindFirstFileW(glob.c_str(), &found);
  if (search == INVALID_HANDLE_VALUE) return false;
  bool matched = false;
  size_t scanned = 0;
  do {
    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    if (++scanned > scan_limit) break;
    if (IsYurisArchiveFile(directory + L"\\" + found.cFileName)) {
      matched = true;
      break;
    }
  } while (FindNextFileW(search, &found));
  FindClose(search);
  return matched;
}

inline bool MatchesYurisLayout(const std::wstring& directory,
                               size_t scan_limit = 32) {
  return DirectoryHasYurisArchive(directory, scan_limit) ||
         DirectoryHasYurisArchive(directory + L"\\pac", scan_limit);
}

inline bool MatchesYurisProfile(const wchar_t*) {
  std::wstring directory;
  if (!engine_dir::ModuleDirectory(&directory)) return false;
  return MatchesYurisLayout(directory);
}

}  // namespace fushi_voice_hook
