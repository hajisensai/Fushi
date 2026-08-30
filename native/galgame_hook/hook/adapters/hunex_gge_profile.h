#pragma once

#include <cwchar>

namespace fushi_voice_hook {

// This title/role pair is measured from the local WITCH ON THE HOLY NIGHT
// v1.0 sample.  The HFA/HW parser is engine-generic, but data04000.hfa is not
// claimed as a family-wide HUNEX invariant.  Runtime admission also requires
// the sibling archive to pass structural HFA + HW/Ogg validation.
inline constexpr wchar_t kHunexGgeMahoyoExecutableName[] = L"WoH.exe";
inline constexpr wchar_t kHunexGgeMahoyoVoiceArchiveName[] =
    L"data04000.hfa";

inline const wchar_t* HunexGgeBasename(const wchar_t* path) {
  if (path == nullptr) return nullptr;
  const wchar_t* slash = wcsrchr(path, L'\\');
  const wchar_t* forward = wcsrchr(path, L'/');
  if (forward != nullptr && (slash == nullptr || forward > slash)) {
    slash = forward;
  }
  return slash == nullptr ? path : slash + 1;
}

inline bool MatchesHunexGgeTitleProfile(const wchar_t* executable_path) {
  const wchar_t* name = HunexGgeBasename(executable_path);
  return name != nullptr &&
         _wcsicmp(name, kHunexGgeMahoyoExecutableName) == 0;
}

inline bool IsHunexGgeVoiceArchivePath(const wchar_t* archive_path) {
  const wchar_t* name = HunexGgeBasename(archive_path);
  return name != nullptr &&
         _wcsicmp(name, kHunexGgeMahoyoVoiceArchiveName) == 0;
}

}  // namespace fushi_voice_hook
