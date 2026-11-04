#pragma once

#include <cstddef>
#include <cstdint>
#include <cerrno>
#include <cstdint>
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

// A byte range of a [blob_file]. [owner] keeps the backing window / buffer
// alive in windowed mode; it is empty in whole-file mode, where the engine's
// own reference to the blob_file keeps the mapping alive.
struct blob_span {
  const uint8_t* data = nullptr;
  size_t size = 0;
  std::shared_ptr<const void> owner;

  explicit operator bool() const { return data != nullptr; }
};

// Read-only random access to a dictionary's blobs.bin (BUG-4013).
//
// 64-bit processes map the whole file once (shared by identity, see
// map_rd_shared): view() is inline pointer arithmetic, identical to the old
// direct mapping. A 32-bit process (Android armeabi-v7a) has ~3 GB of address
// space for everything, and one large dictionary's blobs.bin can exceed what a
// single contiguous mapping can get -- the whole set (~1.9 GB of blobs across a
// typical library) never fits. There the file is served through 2 MB windows
// mapped on demand at 1 MB-aligned starts, kept in a process-wide LRU bounded
// to [kWindowCacheBytes] of address space; any view longer than
// [kWindowStepBytes] is read into a heap buffer instead. Pointers from a span
// stay valid while the span's owner (or a copy of it) is alive.
class blob_file {
 public:
  static constexpr size_t kWindowStepBytes = size_t{1} << 20;
  static constexpr size_t kWindowBytes = 2 * kWindowStepBytes;
  static constexpr size_t kWindowCacheBytes = size_t{96} << 20;

  blob_file() = default;
  ~blob_file();
  blob_file(const blob_file&) = delete;
  blob_file& operator=(const blob_file&) = delete;

  uint64_t size() const { return size_; }
  bool windowed() const { return !whole_; }

  // Bytes [offset, offset + min(len, size - offset)); empty when offset >= size.
  blob_span view(uint64_t offset, size_t len) const {
    if (offset >= size_) {
      return {};
    }
    const uint64_t left = size_ - offset;
    const size_t n = left < len ? static_cast<size_t>(left) : len;
    if (whole_) {
      return {whole_->data + offset, n, {}};
    }
    return view_windowed(offset, n);
  }

  // A variable-length record starting at [offset] whose length is only known
  // after parsing it. Whole-file mode: everything up to the end of the file
  // (unchanged semantics). Windowed: at most kWindowStepBytes -- records are
  // u8/u16-length fields and never come close.
  blob_span record(uint64_t offset) const {
    return view(offset, whole_ ? SIZE_MAX : kWindowStepBytes);
  }

 private:
  friend std::shared_ptr<const blob_file> open_blob_file(const std::string& path);
  blob_span view_windowed(uint64_t offset, size_t n) const;

  shared_mapping whole_;
  uint64_t size_ = 0;
  intptr_t handle_ = -1;   // windowed: fd / HANDLE kept open for mapping windows
  intptr_t mapping_ = 0;   // windowed (Windows): file-mapping object
};
using shared_blob_file = std::shared_ptr<const blob_file>;

// Opens [path] as a blob_file, shared process-wide by file identity like
// map_rd_shared. Empty when missing / empty / unopenable.
shared_blob_file open_blob_file(const std::string& path);

// A [u32 count][u64 x count] offset table in blobs.bin. [span] covers exactly
// the count u64s; it is empty when the header or the whole table does not fit
// in the file.
struct offset_list {
  blob_span span;
  uint32_t count = 0;
};
offset_list read_offset_list(const blob_file& blobs, uint64_t at);

// Which access mode open_blob_file picks. automatic: windowed in 32-bit
// processes (or when the FUSHIDICTS_BLOB_WINDOWED=1 environment variable is
// set, so the whole native suite can be run against the windowed path on a
// 64-bit host), whole-file otherwise. Applies to files opened afterwards.
enum class blob_mode { automatic, whole, windowed };
void set_blob_mode_for_test(blob_mode mode);
// Overrides the LRU address-space budget (default kWindowCacheBytes); 0 restores
// the default. Lets tests force constant eviction while spans are pinned.
void set_blob_window_cache_bytes_for_test(size_t bytes);

// Distinct windows currently held by the LRU (test-only observability).
size_t cached_blob_windows();

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
