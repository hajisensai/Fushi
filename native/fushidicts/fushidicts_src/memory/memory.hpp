#pragma once

#include <cstddef>
#include <cstdint>
#include <cerrno>
#include <memory>
#include <string>
#include <system_error>

namespace memory {
struct mapped_file {
  uint8_t* data = nullptr;
  size_t size = 0;

  explicit operator bool() const { return data != nullptr; }
};

mapped_file map_rd(const std::string& path);

// Read-only mapping of [path] shared by every holder of the same on-disk file
// (BUG-4013). Query engines map each dictionary's files for the lifetime of the
// handle, and a reload builds a whole new engine (Dart `loadPendingAsync`
// shadow) while the old one -- plus any handle a background isolate still
// borrows -- stays alive. With private mappings every overlapping engine added
// another full copy of the dictionary set to the process's *virtual* address
// space (39 dictionaries ~ 3.8 GB per copy), which is what exhausted iOS's
// address-space limit and turned ordinary allocations into SIGABRTs.
//
// The cache is keyed by file identity (device + inode / volume + file index,
// plus size and mtime), not by path string, so a re-imported dictionary that
// replaced the file gets a fresh mapping while every engine holding the old
// one keeps its own until released. Entries are weak: the mapping is unmapped
// as soon as the last holder drops it, exactly as before. Empty pointer when
// the file is missing, empty or cannot be mapped. Thread-safe.
using shared_mapping = std::shared_ptr<const mapped_file>;
shared_mapping map_rd_shared(const std::string& path);

// Number of distinct live shared mappings (test-only observability).
size_t live_shared_mappings();

// Positional reads from a file that is NOT mapped (BUG-4013). For large,
// rarely touched payloads -- dictionary media.bin is ~1.6 GB across a typical
// set and only read when a popup shows an image or plays audio -- reserving
// address space for the whole file is pure cost. Opened per request so it holds
// no file descriptor between requests (iOS's soft RLIMIT_NOFILE is 256).
class file_reader {
 public:
  explicit file_reader(const std::string& path);
  ~file_reader();
  file_reader(const file_reader&) = delete;
  file_reader& operator=(const file_reader&) = delete;

  explicit operator bool() const { return open_; }
  uint64_t size() const { return size_; }
  // Fills [dst] with exactly [n] bytes from [offset]; false on short read / error.
  bool read_at(uint64_t offset, void* dst, size_t n) const;

 private:
  intptr_t handle_ = -1;
  uint64_t size_ = 0;
  bool open_ = false;
};
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
