#ifndef FUSHI_UNITY_TEXT_PROFILE_H_
#define FUSHI_UNITY_TEXT_PROFILE_H_

#include <cwchar>

namespace fushi_voice_hook {

inline const wchar_t* WindowsBaseName(const wchar_t* path) {
  if (path == nullptr) return L"";
  const wchar_t* base = path;
  for (const wchar_t* p = path; *p != L'\0'; ++p) {
    if (*p == L'\\' || *p == L'/') base = p + 1;
  }
  return base;
}

// Real Sasasa.exe evidence shows the old KEMCO renderer emits a standalone
// U+3000 after each glyph batch. That marker is not a generic Unity rule:
// every other title preserves U+3000 as ordinary text.
inline bool UsesSasasaLegacyTextMeshTerminator(const wchar_t* executable_path) {
  return _wcsicmp(WindowsBaseName(executable_path), L"Sasasa.exe") == 0;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_UNITY_TEXT_PROFILE_H_
