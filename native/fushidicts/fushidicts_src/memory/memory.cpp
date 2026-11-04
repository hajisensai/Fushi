#include "memory.hpp"

#include <algorithm>
#include <cerrno>
#include <compare>
#include <cstring>
#include <map>
#include <mutex>

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

bool file_reader::read_at(uint64_t offset, void* dst, size_t n) const {
  if (!open_ || offset > size_ || n > size_ - offset) {
    return false;
  }
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
    if (!ReadFile(reinterpret_cast<HANDLE>(handle_), out + done, chunk, &got, &ov) || got == 0) {
      return false;
    }
#else
    const ssize_t got = pread(static_cast<int>(handle_), out + done, n - done, static_cast<off_t>(pos));
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
