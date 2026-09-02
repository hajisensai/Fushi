// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

#include "windows_utils.h"
#include <Shlwapi.h>
#include <VersionHelpers.h>

namespace flutter_onnxruntime {

std::wstring WindowsUtils::utf8ToWide(const std::string &utf8Str) {
  if (utf8Str.empty()) {
    return std::wstring();
  }

  // Calculate required buffer size
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8Str.c_str(), -1, nullptr, 0);
  if (size <= 0) {
    throw std::runtime_error("Failed to convert UTF-8 string to wide string");
  }

  // Perform conversion
  std::vector<wchar_t> buffer(size);
  int result = MultiByteToWideChar(CP_UTF8, 0, utf8Str.c_str(), -1, buffer.data(), size);
  if (result <= 0) {
    throw std::runtime_error("Failed to convert UTF-8 string to wide string");
  }

  return std::wstring(buffer.data());
}

std::string WindowsUtils::wideToUtf8(const std::wstring &wideStr) {
  if (wideStr.empty()) {
    return std::string();
  }

  // Calculate required buffer size
  int size = WideCharToMultiByte(CP_UTF8, 0, wideStr.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("Failed to convert wide string to UTF-8 string");
  }

  // Perform conversion
  std::vector<char> buffer(size);
  int result = WideCharToMultiByte(CP_UTF8, 0, wideStr.c_str(), -1, buffer.data(), size, nullptr, nullptr);
  if (result <= 0) {
    throw std::runtime_error("Failed to convert wide string to UTF-8 string");
  }

  return std::string(buffer.data());
}

namespace {

// Whether every byte of `s` forms a well-formed UTF-8 sequence.
//
// This must reject at least as much as Dart's strict `utf8.decode`, otherwise
// a string that passes here would still blow up on the far side of the channel
// and toUtf8Message would have accomplished nothing. So overlong encodings,
// UTF-16 surrogates and anything past U+10FFFF are rejected too, not just the
// obviously malformed lead/continuation bytes.
bool isWellFormedUtf8(const std::string &s) {
  size_t i = 0;
  while (i < s.size()) {
    const unsigned char lead = static_cast<unsigned char>(s[i]);
    if (lead < 0x80) {
      i += 1;
      continue;
    }

    size_t continuations;
    unsigned char min_first;
    unsigned char max_first;
    if (lead >= 0xC2 && lead <= 0xDF) {
      continuations = 1;
      min_first = 0x80;
      max_first = 0xBF;
    } else if (lead == 0xE0) {
      // 0xE0 0x80..0x9F would be an overlong encoding of a 2-byte value.
      continuations = 2;
      min_first = 0xA0;
      max_first = 0xBF;
    } else if (lead == 0xED) {
      // 0xED 0xA0..0xBF encodes a UTF-16 surrogate, which is not a scalar value.
      continuations = 2;
      min_first = 0x80;
      max_first = 0x9F;
    } else if ((lead >= 0xE1 && lead <= 0xEC) || lead == 0xEE || lead == 0xEF) {
      continuations = 2;
      min_first = 0x80;
      max_first = 0xBF;
    } else if (lead == 0xF0) {
      continuations = 3;
      min_first = 0x90;
      max_first = 0xBF;
    } else if (lead >= 0xF1 && lead <= 0xF3) {
      continuations = 3;
      min_first = 0x80;
      max_first = 0xBF;
    } else if (lead == 0xF4) {
      // Beyond 0xF4 0x8F the code point would exceed U+10FFFF.
      continuations = 3;
      min_first = 0x80;
      max_first = 0x8F;
    } else {
      // 0x80..0xC1 (stray continuation or overlong lead) and 0xF5..0xFF.
      return false;
    }

    if (i + continuations >= s.size()) {
      return false;
    }
    const unsigned char first = static_cast<unsigned char>(s[i + 1]);
    if (first < min_first || first > max_first) {
      return false;
    }
    for (size_t k = 2; k <= continuations; k++) {
      if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) {
        return false;
      }
    }
    i += continuations + 1;
  }
  return true;
}

} // namespace

std::string WindowsUtils::toUtf8Message(const std::string &message) {
  if (message.empty() || isWellFormedUtf8(message)) {
    return message;
  }

  // Not UTF-8, so read it back as the ANSI code page FormatMessage wrote it in.
  // Lengths are passed explicitly rather than relying on -1: these strings are
  // diagnostics and may carry embedded NULs.
  const int length = static_cast<int>(message.size());
  const int wide_size = MultiByteToWideChar(CP_ACP, 0, message.c_str(), length, nullptr, 0);
  if (wide_size > 0) {
    std::wstring wide(static_cast<size_t>(wide_size), L'\0');
    if (MultiByteToWideChar(CP_ACP, 0, message.c_str(), length, &wide[0], wide_size) == wide_size) {
      const int utf8_size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), wide_size, nullptr, 0, nullptr, nullptr);
      if (utf8_size > 0) {
        std::string utf8(static_cast<size_t>(utf8_size), '\0');
        if (WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), wide_size, &utf8[0], utf8_size, nullptr, nullptr) ==
            utf8_size) {
          return utf8;
        }
      }
    }
  }

  // Neither UTF-8 nor decodable as ANSI. Keep what is unambiguous so the caller
  // still sees the error code and the source location; a mangled tail beats an
  // undecodable reply that erases the whole message.
  std::string ascii;
  ascii.reserve(message.size());
  for (const char raw : message) {
    ascii.push_back(static_cast<unsigned char>(raw) < 0x80 ? raw : '?');
  }
  return ascii;
}

std::string WindowsUtils::getLastErrorAsString() {
  DWORD error = GetLastError();
  if (error == 0) {
    return "No error";
  }

  LPSTR messageBuffer = nullptr;
  size_t size =
      FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                     nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)&messageBuffer, 0, nullptr);

  if (size == 0) {
    return "Unknown error: " + std::to_string(error);
  }

  std::string message(messageBuffer, size);
  LocalFree(messageBuffer);

  // Remove trailing newlines
  message.erase(
      std::find_if(message.rbegin(), message.rend(), [](unsigned char ch) { return ch != '\r' && ch != '\n'; }).base(),
      message.end());

  return message;
}

std::string WindowsUtils::getAppTempDirectory() {
  // Get system temp directory
  wchar_t tempPath[MAX_PATH];
  DWORD result = GetTempPathW(MAX_PATH, tempPath);

  if (result == 0 || result > MAX_PATH) {
    throw std::runtime_error("Failed to get temporary directory: " + getLastErrorAsString());
  }

  // Create a unique subdirectory for the app
  std::wstring appTempPath = std::wstring(tempPath) + L"flutter_onnxruntime\\";
  CreateDirectoryW(appTempPath.c_str(), nullptr);

  return wideToUtf8(appTempPath);
}

std::string WindowsUtils::normalizePathSeparators(const std::string &path) {
  std::string result = path;
  std::replace(result.begin(), result.end(), '/', '\\');
  return result;
}

bool WindowsUtils::pathExists(const std::string &path) {
  std::wstring widePath = utf8ToWide(path);
  DWORD attributes = GetFileAttributesW(widePath.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES;
}

bool WindowsUtils::createDirectories(const std::string &path) {
  std::wstring widePath = utf8ToWide(path);

  // SHCreateDirectoryEx creates all intermediate directories
  int result = SHCreateDirectoryExW(nullptr, widePath.c_str(), nullptr);

  return (result == ERROR_SUCCESS || result == ERROR_ALREADY_EXISTS);
}

std::string WindowsUtils::getModuleDirectory() {
  wchar_t path[MAX_PATH];
  HMODULE hm = nullptr;

  if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         (LPCWSTR)&WindowsUtils::getModuleDirectory, &hm) == 0) {
    throw std::runtime_error("GetModuleHandleEx failed: " + getLastErrorAsString());
  }

  if (GetModuleFileNameW(hm, path, MAX_PATH) == 0) {
    throw std::runtime_error("GetModuleFileName failed: " + getLastErrorAsString());
  }

  // Extract directory portion
  PathRemoveFileSpecW(path);

  return wideToUtf8(path);
}

bool WindowsUtils::addDllDirectory(const std::string &path) {
  std::wstring widePath = utf8ToWide(path);

  // Add directory to DLL search path
  HMODULE kernel32 = GetModuleHandleW(L"kernel32.dll");
  if (!kernel32) {
    return false;
  }

  typedef DLL_DIRECTORY_COOKIE(WINAPI * AddDllDirectoryFunc)(PCWSTR);
  AddDllDirectoryFunc addDllDirectory = (AddDllDirectoryFunc)GetProcAddress(kernel32, "AddDllDirectory");

  if (!addDllDirectory) {
    // On older Windows versions, fallback to SetDllDirectoryW
    return SetDllDirectoryW(widePath.c_str()) != 0;
  }

  return addDllDirectory(widePath.c_str()) != nullptr;
}

std::string WindowsUtils::getWindowsVersionString() {
  std::stringstream ss;

  if (IsWindows10OrGreater()) {
    ss << "Windows 10+";
  } else if (IsWindows8OrGreater()) {
    ss << "Windows 8";
  } else if (IsWindows7OrGreater()) {
    ss << "Windows 7";
  } else {
    ss << "Windows (older)";
  }

  SYSTEM_INFO sysInfo;
  GetNativeSystemInfo(&sysInfo);
  ss << " " << (sysInfo.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64 ? "x64" : "x86");

  return ss.str();
}

} // namespace flutter_onnxruntime