#ifndef HIBIKI_STEAM_LAUNCH_H_
#define HIBIKI_STEAM_LAUNCH_H_

#include <cwctype>
#include <string>

namespace hibiki_voice_hook {

struct SteamLibraryPath {
  std::wstring steamapps_dir;
  std::wstring install_dir;
};

inline std::wstring LowerWide(std::wstring value) {
  for (wchar_t& c : value) c = static_cast<wchar_t>(towlower(c));
  return value;
}

inline bool ParseSteamLibraryPath(const std::wstring& executable,
                                  SteamLibraryPath* out) {
  if (out == nullptr) return false;
  std::wstring normalized = executable;
  for (wchar_t& c : normalized) {
    if (c == L'/') c = L'\\';
  }
  const std::wstring lower = LowerWide(normalized);
  const std::wstring marker = L"\\steamapps\\common\\";
  const size_t marker_pos = lower.find(marker);
  if (marker_pos == std::wstring::npos) return false;
  const size_t install_begin = marker_pos + marker.size();
  const size_t install_end = normalized.find(L'\\', install_begin);
  if (install_end == std::wstring::npos || install_end == install_begin) {
    return false;
  }
  out->steamapps_dir = normalized.substr(0, marker_pos + 10);  // 含 \\steamapps
  out->install_dir = normalized.substr(install_begin,
                                       install_end - install_begin);
  return !out->steamapps_dir.empty() && !out->install_dir.empty();
}

inline std::wstring ParseAcfQuotedValue(const std::wstring& text,
                                        const std::wstring& key) {
  const std::wstring needle = L"\"" + LowerWide(key) + L"\"";
  const std::wstring lower = LowerWide(text);
  size_t pos = lower.find(needle);
  if (pos == std::wstring::npos) return L"";
  pos += needle.size();
  while (pos < text.size() && iswspace(text[pos])) ++pos;
  if (pos >= text.size() || text[pos] != L'\"') return L"";
  const size_t end = text.find(L'\"', pos + 1);
  if (end == std::wstring::npos) return L"";
  return text.substr(pos + 1, end - pos - 1);
}

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_STEAM_LAUNCH_H_
