// import_breadcrumb.hpp — synchronous "last import step" breadcrumb for native
// crash diagnostics (TODO-892).
//
// Dictionary import runs on a 32 MB worker thread spawned by the FFI layer, and
// the heavy bank decompression fans out to std::async worker threads. A native
// access violation there (e.g. the historical null-decompressor deref) is a
// Windows SEH structured exception, not a C++ throw, so it bypasses every
// try/catch and takes the whole process down before any async Dart log flushes.
//
// This header writes ONE small file ".import_step" into a Dart-provided fixed
// directory (the app documents dir) and fflush+fclose-es it synchronously, so
// the byte content survives a hard crash. The Dart side reads it back on the
// NEXT launch and folds it into the crash-recovery log entry, turning "some
// dictionary did not return" into "crashed while at: yomitan term_bank #3".
//
// Intentionally dependency-free (only <cstdio> / fs_utf8) and best-effort: any
// IO failure is swallowed — a breadcrumb is observability, never load-bearing.
#pragma once

#include <cstdio>
#include <string>
#include <string_view>

#include "fs_utf8.hpp"

namespace hoshi::import_breadcrumb {

// File name (under the caller-supplied directory) holding the last step.
inline constexpr const char* kStepFileName = "import_step_breadcrumb.txt";

// Build the UTF-8 path "<dir>/import_step_breadcrumb.txt".
inline std::string step_path(const std::string& dir) {
  if (dir.empty()) return {};
  const char tail = dir.back();
  std::string base = (tail == '/' || tail == '\\') ? dir : dir + "/";
  return base + kStepFileName;
}

// Synchronously overwrite the breadcrumb with `step`. Best-effort: a disabled
// breadcrumb (empty dir) or any IO failure is silently ignored — the import
// must never fail because diagnostics could not be written.
inline void set(const std::string& dir, std::string_view step) {
  const std::string path = step_path(dir);
  if (path.empty()) return;
  // fs_path() routes UTF-8 -> correct native wide path on Windows; _wfopen-like
  // behaviour is obtained via the wide string the path holds.
  FILE* fp = nullptr;
#ifdef _WIN32
  fp = _wfopen(hoshi::fs_path(path).c_str(), L"wb");
#else
  fp = std::fopen(path.c_str(), "wb");
#endif
  if (!fp) return;
  if (!step.empty()) {
    std::fwrite(step.data(), 1, step.size(), fp);
  }
  std::fflush(fp);
  std::fclose(fp);
}

// Remove the breadcrumb file on a clean (success or caught-failure) return.
// Best-effort: a leftover file just means the next launch reports a stale step.
inline void clear(const std::string& dir) {
  const std::string path = step_path(dir);
  if (path.empty()) return;
#ifdef _WIN32
  _wremove(hoshi::fs_path(path).c_str());
#else
  std::remove(path.c_str());
#endif
}

}  // namespace hoshi::import_breadcrumb
