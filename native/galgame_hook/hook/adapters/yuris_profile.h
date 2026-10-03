// YU-RIS identity probe.
//
// Structural rule: next to the game executable (its own directory or the
// `pac` subdirectory the engine searches) there is at least one `*.ypf` whose
// 32-byte header is a valid YPF header and whose whole index parses under
// exactly one reading of the engine's index layouts (yuris_ypf.h:
// name-length table variant x 32/64-bit member offsets; every entry parses,
// every member lies after the index and inside the file, the last entry ends
// exactly at index_end, and layouts that both pass must decode the same
// entries).  A magic alone is not enough.
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
#include <vector>

#include "../yuris_ypf.h"
#include "engine_dir_signature.h"

namespace fushi_voice_hook {

// The probe reads a whole index; an archive whose index is larger than this
// is not used as identity evidence (the scan moves on to the next archive).
// Real indexes are a few dozen bytes per member.
constexpr uint32_t kYurisProbeIndexBytes = 16u << 20;

// `head` is the file from offset 0 and holds the whole index (header through
// index_end): the archive is YU-RIS when exactly one index layout reads every
// entry (yuris::ResolveYpfLayout).
inline bool IsYurisArchiveHead(const uint8_t* head, size_t head_bytes,
                               uint64_t file_size) {
  namespace yuris = ::fushi_voice_hook::yuris;
  yuris::YpfHeader header;
  return yuris::ParseYpfHeader(head, head_bytes, file_size, &header) &&
         yuris::ResolveYpfLayout(head, head_bytes, header, file_size,
                                 nullptr) == yuris::YpfIndexResult::kValid;
}

inline bool IsYurisArchiveFile(const std::wstring& path) {
  namespace yuris = ::fushi_voice_hook::yuris;
  uint64_t size = 0;
  uint8_t header_bytes[yuris::kYpfHeaderBytes] = {0};
  DWORD read = 0;
  yuris::YpfHeader header;
  if (!engine_dir::FileSize(path, &size) ||
      !engine_dir::ReadFilePrefix(path, header_bytes, sizeof(header_bytes),
                                  &read) ||
      !yuris::ParseYpfHeader(header_bytes, read, size, &header) ||
      header.index_end > kYurisProbeIndexBytes) {
    return false;
  }
  std::vector<uint8_t> head(header.index_end);
  return engine_dir::ReadFilePrefix(path, head.data(), header.index_end,
                                    &read) &&
         read == header.index_end &&
         IsYurisArchiveHead(head.data(), head.size(), size);
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
