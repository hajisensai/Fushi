#include "memory.hpp"

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
  if (file_size == 0) {
    return {};
  }

#ifdef _WIN32
  const std::wstring wpath = to_wide(path);
  HANDLE file = CreateFileW(wpath.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return {};
  }

  LARGE_INTEGER size;
  size.QuadPart = static_cast<LONGLONG>(file_size);
  if (!SetFilePointerEx(file, size, nullptr, FILE_BEGIN) || !SetEndOfFile(file)) {
    CloseHandle(file);
    return {};
  }

  HANDLE mapping = CreateFileMappingW(file, nullptr, PAGE_READWRITE, size.HighPart, size.LowPart, nullptr);
  CloseHandle(file);
  if (!mapping) {
    return {};
  }

  auto* data = static_cast<uint8_t*>(MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, file_size));
  CloseHandle(mapping);
  if (!data) {
    return {};
  }

  return {.data = data, .size = file_size};
#else
  int fd = open(path.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    return {};
  }

  if (ftruncate(fd, static_cast<off_t>(file_size)) < 0) {
    close(fd);
    return {};
  }

  auto* data = static_cast<uint8_t*>(mmap(nullptr, file_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
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
  UnmapViewOfFile(mapping.data);
#else
  munmap(mapping.data, mapping.size);
#endif
}
}
