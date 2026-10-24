#pragma once

// knife engine identity: the Switch romfs layout knife plays from, found where
// knife itself looks for it (knife.ini `assets-dir`, `-a` / `--assets-dir`,
// default `assets` next to the exe). The engine's own shape is the scenario
// archive `allscr.mrg` plus loose Nintendo Opus streams in `stream/`; no exe
// name or hash takes part (engine_dir_signature.h).

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

#include "engine_dir_signature.h"
#include "knife_core.h"

namespace fushi_voice_hook {

namespace knife {

struct ResolvedLaunch {
  std::wstring assets_dir;      // absolute
  std::wstring text_websocket;  // HOST:PORT, empty when the server is off
};

inline std::wstring ReadUtf8FileAsWide(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return std::wstring();
  std::string bytes(64 * 1024, '\0');
  DWORD read = 0;
  const bool ok = ReadFile(file, bytes.data(),
                           static_cast<DWORD>(bytes.size()), &read,
                           nullptr) != FALSE;
  CloseHandle(file);
  if (!ok || read == 0) return std::wstring();
  bytes.resize(read);
  const int units = MultiByteToWideChar(CP_UTF8, 0, bytes.data(),
                                        static_cast<int>(bytes.size()),
                                        nullptr, 0);
  if (units <= 0) return std::wstring();
  std::wstring text(static_cast<size_t>(units), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()),
                      text.data(), units);
  return text;
}

inline std::wstring CurrentDirectory() {
  wchar_t buffer[MAX_PATH] = {0};
  const DWORD n = GetCurrentDirectoryW(MAX_PATH, buffer);
  if (n == 0 || n >= MAX_PATH) return std::wstring();
  std::wstring dir(buffer, n);
  while (!dir.empty() && IsPathSeparator(dir.back())) dir.pop_back();
  return dir;
}

// knife's option precedence: command line over knife.ini; ini paths are
// relative to the ini folder, command-line paths to the working directory.
inline bool ResolveLaunch(ResolvedLaunch* out) {
  if (out == nullptr) return false;
  std::wstring exe_dir;
  if (!engine_dir::ModuleDirectory(&exe_dir)) return false;
  const LaunchOptions ini =
      ParseIni(ReadUtf8FileAsWide(exe_dir + L"\\knife.ini"));
  const LaunchOptions cli =
      ApplyCommandLine(LaunchOptions{}, SplitCommandLine(GetCommandLineW()));
  out->assets_dir =
      !cli.assets_dir.empty()
          ? ResolveAgainst(CurrentDirectory(), cli.assets_dir)
          : ResolveAgainst(exe_dir, ini.assets_dir.empty() ? L"assets"
                                                           : ini.assets_dir);
  out->text_websocket =
      !cli.text_websocket.empty() ? cli.text_websocket : ini.text_websocket;
  return true;
}

inline bool AssetsLookLikeKnife(const std::wstring& assets_dir) {
  static constexpr uint8_t kMagic[4] = {0x01, 0x00, 0x00, 0x80};
  return engine_dir::FileExists(assets_dir + L"\\allscr.mrg") &&
         engine_dir::DirectoryHasFileStartingWith(
             assets_dir + L"\\stream", L"*.opus", kMagic, sizeof(kMagic));
}

}  // namespace knife

inline bool MatchesKnifeProfile(const wchar_t*) {
  knife::ResolvedLaunch launch;
  return knife::ResolveLaunch(&launch) &&
         knife::AssetsLookLikeKnife(launch.assets_dir);
}

}  // namespace fushi_voice_hook
