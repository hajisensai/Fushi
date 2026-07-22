#ifndef HIBIKI_LUNA_HOOK_CONFIG_H_
#define HIBIKI_LUNA_HOOK_CONFIG_H_

#include <algorithm>
#include <cctype>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace hibiki_voice_hook {

struct LunaTargetIdentity {
  std::string executable_sha256;
  std::unordered_map<std::string, std::string> module_sha256;
};

struct LunaHookProfileMatch {
  int codepage = 0;
  std::vector<std::wstring> hook_codes;
};

inline std::string LowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

inline bool IsSha256(const std::string& value) {
  if (value.size() != 64) return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char c) {
    return std::isxdigit(c) != 0;
  });
}

inline std::vector<std::string> SplitTabs(const std::string& line) {
  std::vector<std::string> fields;
  size_t start = 0;
  while (true) {
    const size_t tab = line.find('\t', start);
    fields.push_back(line.substr(start, tab - start));
    if (tab == std::string::npos) break;
    start = tab + 1;
  }
  return fields;
}

// TSV schema: exe_sha256, module_name, module_sha256, codepage, hook_code,
// label. A row may identify the target by executable hash, module hash, or both.
inline LunaHookProfileMatch MatchLunaHookProfiles(
    const std::string& tsv, const LunaTargetIdentity& identity) {
  LunaHookProfileMatch result;
  std::istringstream input(tsv);
  std::string line;
  while (std::getline(input, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line[0] == '#' || line.rfind("exe_sha256\t", 0) == 0) {
      continue;
    }
    const auto fields = SplitTabs(line);
    if (fields.size() < 6) continue;
    const std::string exe_hash = LowerAscii(fields[0]);
    const std::string module_name = LowerAscii(fields[1]);
    const std::string module_hash = LowerAscii(fields[2]);
    if ((!exe_hash.empty() && !IsSha256(exe_hash)) ||
        (!module_hash.empty() && !IsSha256(module_hash)) ||
        (exe_hash.empty() && module_hash.empty())) {
      continue;
    }
    if (!exe_hash.empty() && exe_hash != LowerAscii(identity.executable_sha256)) {
      continue;
    }
    if (!module_hash.empty()) {
      const auto found = identity.module_sha256.find(module_name);
      if (found == identity.module_sha256.end() ||
          LowerAscii(found->second) != module_hash) {
        continue;
      }
    }
    try {
      const int codepage = fields[3].empty() ? 0 : std::stoi(fields[3]);
      if (codepage > 0) result.codepage = codepage;
    } catch (...) {
      continue;
    }
    if (!fields[4].empty()) {
      result.hook_codes.emplace_back(fields[4].begin(), fields[4].end());
    }
  }
  return result;
}

inline const char* BuiltInLunaHookProfiles() {
  return
#include "luna_hook_profiles.inc"
      ;
}

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_LUNA_HOOK_CONFIG_H_
