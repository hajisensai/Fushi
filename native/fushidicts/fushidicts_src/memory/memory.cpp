#include "memory.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>

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

mapped_file map_rd(const std::string& path) {
#ifdef _WIN32
  const std::wstring wpath = to_wide(path);
  HANDLE file = CreateFileW(wpath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return {};
  }

  LARGE_INTEGER file_size;
  if (!GetFileSizeEx(file, &file_size) || file_size.QuadPart == 0) {
    CloseHandle(file);
    return {};
  }

  HANDLE mapping = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
  CloseHandle(file);
  if (!mapping) {
    return {};
  }

  auto* data = static_cast<uint8_t*>(MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0));
  CloseHandle(mapping);
  if (!data) {
    return {};
  }

  return {.data = data, .size = static_cast<size_t>(file_size.QuadPart)};
#else
  int fd = open(path.c_str(), O_RDONLY);
  if (fd < 0) {
    return {};
  }

  struct stat st {};
  if (fstat(fd, &st) != 0 || st.st_size == 0) {
    close(fd);
    return {};
  }

  auto* data = static_cast<uint8_t*>(mmap(nullptr, st.st_size, PROT_READ, MAP_SHARED, fd, 0));
  close(fd);
  if (data == reinterpret_cast<uint8_t*>(MAP_FAILED)) {
    return {};
  }

  return {.data = data, .size = static_cast<size_t>(st.st_size)};
#endif
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
