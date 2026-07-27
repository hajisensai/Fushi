#pragma once

namespace hibiki_voice_hook {
inline bool MatchesRealliveProfile(const wchar_t*) {
  // RealLive recognition hashes remain empty until measured from a real sample. Runtime OVK
  // observation enables the shared resource path but never makes this profile match.
  return false;
}
}  // namespace hibiki_voice_hook
