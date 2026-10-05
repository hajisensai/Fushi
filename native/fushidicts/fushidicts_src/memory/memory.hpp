#pragma once

#include <cstddef>
#include <cstdint>
#include <cerrno>
#include <string>
#include <system_error>

namespace memory {
struct mapped_file {
  uint8_t* data = nullptr;
  size_t size = 0;

  explicit operator bool() const { return data != nullptr; }
};

mapped_file map_rd(const std::string& path);
// Creates [path] with exactly [file_size] bytes and maps it writable. The bytes
// are *reserved on disk before the mapping is returned* (BUG-2952): a writable
// MAP_SHARED mapping over a sparse file defers block allocation to the first
// page fault, and when the volume is full that fault is delivered as SIGBUS
// (Windows: EXCEPTION_IN_PAGE_ERROR) -- a process kill no try/catch can see.
// Reserving up front turns a full disk into an ordinary failed call instead:
// the result is empty and [last_error] reports why.
mapped_file map_rw(const std::string& path, size_t file_size);
void unmap(mapped_file mapping);

// errno-style code (ENOSPC, EACCES, ...) of the most recent failed map_rw on
// this thread; 0 when it succeeded. Windows error codes are folded onto the
// matching errno value so callers can classify "disk full" portably.
int last_error();

// The exception map_rw callers throw on failure: carries [last_error] so the
// importer can tell "the disk is full" (ENOSPC) apart from any other failure
// and report it as such instead of a bare "failed to create hash table".
struct map_error : std::system_error {
  explicit map_error(const std::string& what)
      : std::system_error(last_error() != 0 ? last_error() : EIO, std::generic_category(), what) {}
};

}
