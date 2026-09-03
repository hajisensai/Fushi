// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

#ifndef FLUTTER_ONNXRUNTIME_WINDOWS_UTILS_H_
#define FLUTTER_ONNXRUNTIME_WINDOWS_UTILS_H_

#include "pch.h"

// Include Windows headers
#include <windows.h>

namespace flutter_onnxruntime {

// Utility class for Windows-specific functionality
class WindowsUtils {
public:
  // Convert UTF-8 string to wide (UTF-16) string
  static std::wstring utf8ToWide(const std::string &utf8Str);

  // Convert wide (UTF-16) string to UTF-8 string
  static std::string wideToUtf8(const std::wstring &wideStr);

  // Get last Windows error as string
  static std::string getLastErrorAsString();

  // Coerce a native diagnostic string into valid UTF-8.
  //
  // The Flutter method channel encodes strings as UTF-8 and Dart's decoder is
  // strict, so a single stray byte makes the *reply itself* undecodable: the
  // Dart caller gets a FormatException instead of the error we tried to report,
  // and the real failure is lost. ONNX Runtime builds its Windows messages by
  // appending the system error text, which FormatMessage renders in the
  // machine's ANSI code page (GBK on a Chinese Windows), so this is the normal
  // case for a failing session, not an exotic one.
  //
  // Already-valid UTF-8 is returned untouched; anything else is read as ANSI
  // and re-encoded. Input that is neither keeps its ASCII skeleton (error code,
  // file and line stay readable) with the undecodable bytes replaced.
  static std::string toUtf8Message(const std::string &message);

  // Get path to application's temporary directory
  static std::string getAppTempDirectory();

  // Convert forward slashes to backslashes
  static std::string normalizePathSeparators(const std::string &path);

  // Check if path exists
  static bool pathExists(const std::string &path);

  // Create directory recursively
  static bool createDirectories(const std::string &path);

  // Get current module directory
  static std::string getModuleDirectory();

  // Add directory to DLL search path
  static bool addDllDirectory(const std::string &path);

  // Get Windows version information
  static std::string getWindowsVersionString();
};

} // namespace flutter_onnxruntime

#endif // FLUTTER_ONNXRUNTIME_WINDOWS_UTILS_H_