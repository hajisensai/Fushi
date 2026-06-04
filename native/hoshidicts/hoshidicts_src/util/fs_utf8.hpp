// fs_utf8.hpp — single platform-boundary helper for UTF-8 filesystem paths.
//
// Dart passes paths to native as UTF-8 bytes. On Windows, constructing a
// std::filesystem::path from a std::string decodes via the active code page
// (ANSI), NOT UTF-8, so any non-ASCII path silently breaks. On POSIX the
// narrow encoding is already UTF-8. This helper bridges both: it builds the
// path from the UTF-8 bytes explicitly so Windows stores the correct UTF-16
// internally. All fstream / std::filesystem access in this library MUST route
// UTF-8 strings through fs_path() (or the open helpers below).
#pragma once

#include <filesystem>
#include <fstream>
#include <ios>
#include <string>

namespace hoshi {

// Build a std::filesystem::path from a UTF-8 std::string, correctly on all
// platforms. C++23: char8_t exists and std::filesystem::u8path is deprecated,
// so use the char8_t path constructor; older toolchains fall back to u8path.
inline std::filesystem::path fs_path(const std::string& utf8) {
#ifdef __cpp_char8_t
  return std::filesystem::path(
      std::u8string(reinterpret_cast<const char8_t*>(utf8.data()), utf8.size()));
#else
  return std::filesystem::u8path(utf8);
#endif
}

// Extract a UTF-8 std::string from a std::filesystem::path. The path's own
// .string() returns the native narrow encoding (ANSI on Windows), which loses
// non-ASCII; .u8string() always yields UTF-8. Use this whenever a path (or a
// component like .stem()/.filename()) is fed back into a UTF-8 string path.
inline std::string fs_to_utf8(const std::filesystem::path& p) {
#ifdef __cpp_char8_t
  const std::u8string u8 = p.u8string();
  return std::string(reinterpret_cast<const char*>(u8.data()), u8.size());
#else
  return p.u8string();
#endif
}

// Open helpers that take a UTF-8 path. fstream gained a std::filesystem::path
// ctor in C++17 which on Windows opens via the wide path -> correct.
inline std::ifstream open_ifstream(const std::string& utf8_path,
                                   std::ios::openmode mode = std::ios::in) {
  return std::ifstream(fs_path(utf8_path), mode);
}

inline std::ofstream open_ofstream(const std::string& utf8_path,
                                   std::ios::openmode mode = std::ios::out) {
  return std::ofstream(fs_path(utf8_path), mode);
}

}  // namespace hoshi
