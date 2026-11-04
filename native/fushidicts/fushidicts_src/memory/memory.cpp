#include "memory.hpp"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <compare>
#include <cstdlib>
#include <cstring>
#include <list>
#include <map>
#include <mutex>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#ifdef _WIN32
namespace {
// Dart passes paths as UTF-8. The narrow (ANSI) Win32 file APIs decode via the
// active code page, so non-ASCII paths fail (ERROR_INVALID_NAME). Convert to
// UTF-16 and use the wide Win32 APIs so any path opens correctly.
std::wstring to_wide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), &w[0], n);
  return w;
}
}  // namespace
#endif

namespace memory {
namespace {
thread_local int g_last_error = 0;

#ifndef _WIN32
// Allocate real blocks for [size] bytes of [fd] (see map_rw in the header).
// posix_fallocate is the cheap path; where the filesystem refuses it (some
// FUSE / emulated-storage mounts answer EOPNOTSUPP / EINVAL) the bytes are
// reserved the slow way, by writing zeros, which allocates on every
// filesystem and fails with ENOSPC instead of faulting later. Returns 0 or an
// errno value.
int reserve_blocks(int fd, size_t size) {
#if !defined(__APPLE__)
  const int rc = posix_fallocate(fd, 0, static_cast<off_t>(size));
  if (rc == 0) {
    return 0;
  }
  if (rc == ENOSPC || rc == EFBIG
#ifdef EDQUOT
      || rc == EDQUOT
#endif
  ) {
    return rc;
  }
#endif
  static constexpr size_t kChunk = 64 * 1024;
  static const char zeros[kChunk] = {};
  size_t done = 0;
  while (done < size) {
    const size_t n = std::min(kChunk, size - done);
    const ssize_t w = pwrite(fd, zeros, n, static_cast<off_t>(done));
    if (w < 0) {
      if (errno == EINTR) continue;
      return errno != 0 ? errno : EIO;
    }
    if (w == 0) {
      return ENOSPC;
    }
    done += static_cast<size_t>(w);
  }
  return 0;
}
#else
int errno_from_win32(DWORD err) {
  switch (err) {
    case ERROR_DISK_FULL:
    case ERROR_HANDLE_DISK_FULL:
      return ENOSPC;
    case ERROR_ACCESS_DENIED:
      return EACCES;
    case ERROR_NOT_ENOUGH_MEMORY:
    case ERROR_OUTOFMEMORY:
      return ENOMEM;
    default:
      return EIO;
  }
}
#endif
}  // namespace

int last_error() { return g_last_error; }

namespace {

// An open read-only file plus the identity the shared-mapping cache keys on.
struct opened_file {
#ifdef _WIN32
  HANDLE handle = INVALID_HANDLE_VALUE;
#else
  int fd = -1;
#endif
  uint64_t size = 0;
  // device/volume, inode/file index, mtime (ns or FILETIME ticks)
  uint64_t dev = 0;
  uint64_t ino = 0;
  int64_t mtime = 0;

  bool ok() const {
#ifdef _WIN32
    return handle != INVALID_HANDLE_VALUE;
#else
    return fd >= 0;
#endif
  }
  void close_file() {
#ifdef _WIN32
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    handle = INVALID_HANDLE_VALUE;
#else
    if (fd >= 0) close(fd);
    fd = -1;
#endif
  }
};

// Opens [path] read-only; fails (returns !ok()) for a missing or empty file.
opened_file open_rd(const std::string& path) {
  opened_file f;
#ifdef _WIN32
  const std::wstring wpath = to_wide(path);
  f.handle = CreateFileW(wpath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f.handle == INVALID_HANDLE_VALUE) {
    return f;
  }
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(f.handle, &info)) {
    f.close_file();
    return f;
  }
  f.size = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
  f.dev = info.dwVolumeSerialNumber;
  f.ino = (static_cast<uint64_t>(info.nFileIndexHigh) << 32) | info.nFileIndexLow;
  f.mtime = static_cast<int64_t>((static_cast<uint64_t>(info.ftLastWriteTime.dwHighDateTime) << 32) |
                                 info.ftLastWriteTime.dwLowDateTime);
#else
  f.fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (f.fd < 0) {
    return f;
  }
  struct stat st {};
  if (fstat(f.fd, &st) != 0) {
    f.close_file();
    return f;
  }
  f.size = static_cast<uint64_t>(st.st_size);
  f.dev = static_cast<uint64_t>(st.st_dev);
  f.ino = static_cast<uint64_t>(st.st_ino);
#if defined(__APPLE__)
  f.mtime = static_cast<int64_t>(st.st_mtimespec.tv_sec) * 1000000000LL + st.st_mtimespec.tv_nsec;
#else
  f.mtime = static_cast<int64_t>(st.st_mtim.tv_sec) * 1000000000LL + st.st_mtim.tv_nsec;
#endif
#endif
  if (f.size == 0) {
    f.close_file();
  }
  return f;
}

// Maps an opened file read-only. Does not close [f].
mapped_file map_opened(const opened_file& f) {
  if (!f.ok() || f.size == 0) {
    return {};
  }
#ifdef _WIN32
  HANDLE mapping = CreateFileMappingW(f.handle, nullptr, PAGE_READONLY, 0, 0, nullptr);
  if (!mapping) {
    return {};
  }
  auto* data = static_cast<uint8_t*>(MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0));
  CloseHandle(mapping);
  if (!data) {
    return {};
  }
#else
  auto* data = static_cast<uint8_t*>(mmap(nullptr, f.size, PROT_READ, MAP_SHARED, f.fd, 0));
  if (data == reinterpret_cast<uint8_t*>(MAP_FAILED)) {
    return {};
  }
#endif
  return {.data = data, .size = static_cast<size_t>(f.size)};
}

struct mapping_key {
  uint64_t dev;
  uint64_t ino;
  uint64_t size;
  int64_t mtime;
  auto operator<=>(const mapping_key&) const = default;
};

struct mapping_cache {
  std::mutex mu;
  std::map<mapping_key, std::weak_ptr<const mapped_file>> entries;
};

// Leaked on purpose: engines can outlive static destruction at process exit.
mapping_cache& cache() {
  static auto* c = new mapping_cache();
  return *c;
}

}  // namespace

mapped_file map_rd(const std::string& path) {
  opened_file f = open_rd(path);
  mapped_file m = map_opened(f);
  f.close_file();
  return m;
}

shared_mapping map_rd_shared(const std::string& path) {
  opened_file f = open_rd(path);
  if (!f.ok()) {
    return {};
  }
  const mapping_key key{f.dev, f.ino, f.size, f.mtime};
  mapping_cache& c = cache();
  std::lock_guard lock(c.mu);
  if (auto it = c.entries.find(key); it != c.entries.end()) {
    if (shared_mapping hit = it->second.lock()) {
      f.close_file();
      return hit;
    }
  }
  mapped_file m = map_opened(f);
  f.close_file();
  if (!m) {
    return {};
  }
  // Drop entries whose mapping is already gone so the table stays bounded.
  std::erase_if(c.entries, [](const auto& e) { return e.second.expired(); });
  shared_mapping owned(new mapped_file(m), [](const mapped_file* p) {
    unmap(*p);
    delete p;
  });
  c.entries[key] = owned;
  return owned;
}

size_t live_shared_mappings() {
  mapping_cache& c = cache();
  std::lock_guard lock(c.mu);
  return static_cast<size_t>(
      std::count_if(c.entries.begin(), c.entries.end(), [](const auto& e) { return !e.second.expired(); }));
}

file_reader::file_reader(const std::string& path) {
  opened_file f = open_rd(path);
  if (!f.ok()) {
    return;
  }
#ifdef _WIN32
  handle_ = reinterpret_cast<intptr_t>(f.handle);
#else
  handle_ = f.fd;
#endif
  size_ = f.size;
  open_ = true;
}

file_reader::~file_reader() {
  if (!open_) {
    return;
  }
#ifdef _WIN32
  CloseHandle(reinterpret_cast<HANDLE>(handle_));
#else
  close(static_cast<int>(handle_));
#endif
}

namespace {

#if defined(__ANDROID__) && !defined(__LP64__)
// 32-bit bionic: off_t is 32 bits unless _FILE_OFFSET_BITS=64; use the 64-bit
// entry points explicitly so offsets past 2 GB work.
inline ssize_t pread_any(int fd, void* buf, size_t n, uint64_t pos) {
  return pread64(fd, buf, n, static_cast<off64_t>(pos));
}
inline void* mmap_any(size_t len, int fd, uint64_t pos) {
  return mmap64(nullptr, len, PROT_READ, MAP_SHARED, fd, static_cast<off64_t>(pos));
}
#elif !defined(_WIN32)
inline ssize_t pread_any(int fd, void* buf, size_t n, uint64_t pos) {
  return pread(fd, buf, n, static_cast<off_t>(pos));
}
inline void* mmap_any(size_t len, int fd, uint64_t pos) {
  return mmap(nullptr, len, PROT_READ, MAP_SHARED, fd, static_cast<off_t>(pos));
}
#endif

// Reads exactly [n] bytes at [offset] of an open file handle / fd.
bool read_handle_at(intptr_t handle, uint64_t offset, void* dst, size_t n) {
  auto* out = static_cast<uint8_t*>(dst);
  size_t done = 0;
  while (done < n) {
    const uint64_t pos = offset + done;
#ifdef _WIN32
    const DWORD chunk = static_cast<DWORD>(std::min<size_t>(n - done, 1u << 30));
    OVERLAPPED ov{};
    ov.Offset = static_cast<DWORD>(pos & 0xFFFFFFFFu);
    ov.OffsetHigh = static_cast<DWORD>(pos >> 32);
    DWORD got = 0;
    if (!ReadFile(reinterpret_cast<HANDLE>(handle), out + done, chunk, &got, &ov) || got == 0) {
      return false;
    }
#else
    const ssize_t got = pread_any(static_cast<int>(handle), out + done, n - done, pos);
    if (got < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (got == 0) {
      return false;
    }
#endif
    done += static_cast<size_t>(got);
  }
  return true;
}

}  // namespace

bool file_reader::read_at(uint64_t offset, void* dst, size_t n) const {
  if (!open_ || offset > size_ || n > size_ - offset) {
    return false;
  }
  return read_handle_at(handle_, offset, dst, n);
}

// ── blob_file ────────────────────────────────────────────────────────

namespace {

std::atomic<int> g_blob_mode{static_cast<int>(blob_mode::automatic)};
std::atomic<size_t> g_window_cache_bytes{0};  // 0 = blob_file::kWindowCacheBytes

bool use_windowed_blobs() {
  switch (static_cast<blob_mode>(g_blob_mode.load(std::memory_order_relaxed))) {
    case blob_mode::whole:
      return false;
    case blob_mode::windowed:
      return true;
    case blob_mode::automatic:
      break;
  }
  if (sizeof(void*) < 8) {
    return true;
  }
  const char* env = std::getenv("FUSHIDICTS_BLOB_WINDOWED");
  return env != nullptr && env[0] == '1';
}

// One mapped window. Unmapped when the last span / LRU slot holding it drops.
struct blob_window {
  uint8_t* base = nullptr;
  size_t len = 0;
  ~blob_window() {
    if (!base) return;
#ifdef _WIN32
    UnmapViewOfFile(base);
#else
    munmap(base, len);
#endif
  }
};

struct window_lru {
  using key = std::pair<const blob_file*, uint64_t>;
  struct entry {
    key k;
    std::shared_ptr<const blob_window> w;
  };
  std::mutex mu;
  std::list<entry> order;  // front = most recently used
  std::map<key, std::list<entry>::iterator> index;
  size_t bytes = 0;

  void drop_file(const blob_file* f) {
    std::lock_guard lock(mu);
    for (auto it = index.lower_bound({f, 0}); it != index.end() && it->first.first == f;) {
      bytes -= it->second->w->len;
      order.erase(it->second);
      it = index.erase(it);
    }
  }
};

window_lru& lru() {
  static auto* l = new window_lru();
  return *l;
}

struct blob_cache {
  std::mutex mu;
  std::map<mapping_key, std::weak_ptr<const blob_file>> entries;
};

blob_cache& blobs_cache() {
  static auto* c = new blob_cache();
  return *c;
}

}  // namespace

void set_blob_mode_for_test(blob_mode mode) { g_blob_mode.store(static_cast<int>(mode)); }

void set_blob_window_cache_bytes_for_test(size_t bytes) { g_window_cache_bytes.store(bytes); }

size_t cached_blob_windows() {
  window_lru& l = lru();
  std::lock_guard lock(l.mu);
  return l.order.size();
}

blob_file::~blob_file() {
  if (whole_) {
    return;
  }
  lru().drop_file(this);
#ifdef _WIN32
  if (mapping_) CloseHandle(reinterpret_cast<HANDLE>(mapping_));
  if (handle_ != -1) CloseHandle(reinterpret_cast<HANDLE>(handle_));
#else
  if (handle_ >= 0) close(static_cast<int>(handle_));
#endif
}

blob_span blob_file::view_windowed(uint64_t offset, size_t n) const {
  if (n > kWindowStepBytes) {
    // Longer than a window guarantees: read it into an owned buffer.
    auto buf = std::make_shared<std::vector<uint8_t>>(n);
    if (!read_handle_at(handle_, offset, buf->data(), n)) {
      return {};
    }
    const uint8_t* p = buf->data();
    return {p, n, std::move(buf)};
  }
  // Window [k*step, k*step + 2*step) contains every range of <= step bytes that
  // starts inside [k*step, (k+1)*step).
  const uint64_t index = offset / kWindowStepBytes;
  const uint64_t start = index * kWindowStepBytes;
  window_lru& l = lru();
  std::shared_ptr<const blob_window> w;
  {
    std::lock_guard lock(l.mu);
    if (auto it = l.index.find({this, index}); it != l.index.end()) {
      l.order.splice(l.order.begin(), l.order, it->second);
      w = it->second->w;
    }
  }
  if (!w) {
    const size_t len = static_cast<size_t>(std::min<uint64_t>(kWindowBytes, size_ - start));
    auto fresh = std::make_shared<blob_window>();
#ifdef _WIN32
    fresh->base = static_cast<uint8_t*>(MapViewOfFile(reinterpret_cast<HANDLE>(mapping_), FILE_MAP_READ,
                                                      static_cast<DWORD>(start >> 32),
                                                      static_cast<DWORD>(start & 0xFFFFFFFFu), len));
#else
    void* p = mmap_any(len, static_cast<int>(handle_), start);
    fresh->base = p == MAP_FAILED ? nullptr : static_cast<uint8_t*>(p);
#endif
    if (!fresh->base) {
      return {};
    }
    fresh->len = len;
    std::lock_guard lock(l.mu);
    if (auto it = l.index.find({this, index}); it != l.index.end()) {
      // Another thread mapped it meanwhile: use theirs, drop ours.
      l.order.splice(l.order.begin(), l.order, it->second);
      w = it->second->w;
    } else {
      w = fresh;
      l.order.push_front({{this, index}, w});
      l.index[{this, index}] = l.order.begin();
      l.bytes += len;
      const size_t budget = g_window_cache_bytes.load(std::memory_order_relaxed);
      const size_t cap = budget == 0 ? kWindowCacheBytes : budget;
      while (l.bytes > cap && l.order.size() > 1) {
        const auto& victim = l.order.back();
        l.bytes -= victim.w->len;
        l.index.erase(victim.k);
        l.order.pop_back();  // still mapped while a span pins it
      }
    }
  }
  const uint8_t* p = w->base + (offset - start);
  return {p, n, std::move(w)};
}

offset_list read_offset_list(const blob_file& blobs, uint64_t at) {
  offset_list out;
  const blob_span head = blobs.view(at, sizeof(uint32_t));
  if (head.size < sizeof(uint32_t)) {
    return out;
  }
  std::memcpy(&out.count, head.data, sizeof(uint32_t));
  // The count is read from disk. A table claiming more u64s than the file still
  // holds is corrupt; reading it would size the windowed heap buffer by the
  // rest of the file (bad_alloc across the FFI on 32-bit). Same outcome as an
  // unreadable header.
  const uint64_t table_at = at + sizeof(uint32_t);
  const uint64_t table_bytes = uint64_t{out.count} * sizeof(uint64_t);
  if (table_bytes > blobs.size() - table_at) {
    out.count = 0;
    return out;
  }
  out.span = blobs.view(table_at, static_cast<size_t>(table_bytes));
  return out;
}

shared_blob_file open_blob_file(const std::string& path) {
  const bool windowed = use_windowed_blobs();
  if (!windowed) {
    shared_mapping whole = map_rd_shared(path);
    if (!whole) {
      return {};
    }
    auto f = std::make_shared<blob_file>();
    f->size_ = whole->size;
    f->whole_ = std::move(whole);
    return f;
  }

  opened_file of = open_rd(path);
  if (!of.ok()) {
    return {};
  }
  const mapping_key key{of.dev, of.ino, of.size, of.mtime};
  blob_cache& c = blobs_cache();
  std::lock_guard lock(c.mu);
  if (auto it = c.entries.find(key); it != c.entries.end()) {
    if (shared_blob_file hit = it->second.lock()) {
      of.close_file();
      return hit;
    }
  }
  auto f = std::make_shared<blob_file>();
  f->size_ = of.size;
#ifdef _WIN32
  HANDLE mapping = CreateFileMappingW(of.handle, nullptr, PAGE_READONLY, 0, 0, nullptr);
  if (!mapping) {
    of.close_file();
    return {};
  }
  f->handle_ = reinterpret_cast<intptr_t>(of.handle);
  f->mapping_ = reinterpret_cast<intptr_t>(mapping);
#else
  f->handle_ = of.fd;
#endif
  std::erase_if(c.entries, [](const auto& e) { return e.second.expired(); });
  c.entries[key] = f;
  return f;
}

mapped_file map_rw(const std::string& path, size_t file_size) {
  g_last_error = 0;
  if (file_size == 0) {
    g_last_error = EINVAL;
    return {};
  }

#ifdef _WIN32
  const std::wstring wpath = to_wide(path);
  HANDLE file = CreateFileW(wpath.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    g_last_error = errno_from_win32(GetLastError());
    return {};
  }

  // SetEndOfFile on a non-sparse NTFS file allocates the clusters, so a full
  // volume fails here (ERROR_DISK_FULL) rather than on a later page fault.
  LARGE_INTEGER size;
  size.QuadPart = static_cast<LONGLONG>(file_size);
  if (!SetFilePointerEx(file, size, nullptr, FILE_BEGIN) || !SetEndOfFile(file)) {
    g_last_error = errno_from_win32(GetLastError());
    CloseHandle(file);
    DeleteFileW(wpath.c_str());
    return {};
  }

  HANDLE mapping = CreateFileMappingW(file, nullptr, PAGE_READWRITE, size.HighPart, size.LowPart, nullptr);
  if (!mapping) {
    g_last_error = errno_from_win32(GetLastError());
  }
  CloseHandle(file);
  if (!mapping) {
    return {};
  }

  auto* data = static_cast<uint8_t*>(MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, file_size));
  if (!data) {
    g_last_error = errno_from_win32(GetLastError());
  }
  CloseHandle(mapping);
  if (!data) {
    return {};
  }

  return {.data = data, .size = file_size};
#else
  int fd = open(path.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    g_last_error = errno != 0 ? errno : EIO;
    return {};
  }

  // ftruncate alone only sets the size: the file stays sparse and the first
  // store into each mapped page has to allocate a block. On a full volume that
  // allocation fails inside the page-fault handler and the kernel answers with
  // SIGBUS -- the hash/bloom build then kills the whole app mid-import
  // (BUG-2952, user log "native 词典导入未返回" on a nearly full phone).
  const int reserve_rc = reserve_blocks(fd, file_size);
  if (reserve_rc != 0) {
    g_last_error = reserve_rc;
    close(fd);
    unlink(path.c_str());
    return {};
  }

  auto* data = static_cast<uint8_t*>(mmap(nullptr, file_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
  if (data == reinterpret_cast<uint8_t*>(MAP_FAILED)) {
    g_last_error = errno != 0 ? errno : EIO;
  }
  close(fd);
  if (data == reinterpret_cast<uint8_t*>(MAP_FAILED)) {
    return {};
  }

  return {.data = data, .size = file_size};
#endif
}

void unmap(mapped_file mapping) {
  if (!mapping.data) {
    return;
  }

#ifdef _WIN32
  // 上游 d4183d4：unmap 前显式刷脏页——导入刚完成即崩溃时文件可能没落盘
  //（只读映射无脏页，调用无害）。
  FlushViewOfFile(mapping.data, 0);
  UnmapViewOfFile(mapping.data);
#else
  msync(mapping.data, mapping.size, MS_SYNC);
  munmap(mapping.data, mapping.size);
#endif
}
}
