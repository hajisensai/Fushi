#ifndef FUSHI_SGRE_FAMILY_H_
#define FUSHI_SGRE_FAMILY_H_

#include <windows.h>

#include <string>

namespace fushi_voice_hook {

// SGRE (MAGES wind3d11) audio-family identity, shared by the in-game SGRE
// adapter (hook/adapters/sgre_profile.h, MatchesSgreFamily) and the injector.
//
// The M2 wind3d11 runtime keeps character voice in
// `<executable dir>\wind3d11data\voice_body.bin`. That layout is an engine
// structure, not a per-title name or hash, and it is visible on disk before
// anything is injected. The injector therefore reaches the same verdict as the
// adapter's probe() before the first Luna line instead of waiting for the hook
// DLL's adapter report. Waiting for the report let MAGES `#RRGGBB;` / `%p;` /
// `%r` controls leak into the first Luna lines (reports are published at most
// once per second) and into every line when the hook DLL never reported.
//
// The adapter can also prove the family from in-process text anchors without
// the archive; that verdict only exists after injection and keeps reaching the
// injector through AdapterReportsClaimEngine.

// Returns the archive path for `executable_path`, or an empty string when the
// path has no directory component.
inline std::wstring SgreVoiceArchivePathForExecutable(
    const std::wstring& executable_path) {
  const size_t slash = executable_path.find_last_of(L"/\\");
  if (slash == std::wstring::npos) return std::wstring();
  std::wstring path = executable_path.substr(0, slash + 1);
  path += L"wind3d11data\\voice_body.bin";
  return path;
}

// True when the wind3d11 voice archive exists next to `executable_path`.
inline bool SgreVoiceArchiveExistsBesideExecutable(
    const std::wstring& executable_path) {
  const std::wstring archive =
      SgreVoiceArchivePathForExecutable(executable_path);
  if (archive.empty()) return false;
  const DWORD attributes = GetFileAttributesW(archive.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_SGRE_FAMILY_H_
