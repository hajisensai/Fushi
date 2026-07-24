#ifndef HIBIKI_LUNA_HOOK_CONFIG_H_
#define HIBIKI_LUNA_HOOK_CONFIG_H_

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cwchar>
#include <cwctype>
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
  bool enable_pc_hooks = false;
  uint32_t defer_until_running_ms = 0;
  std::vector<std::wstring> hook_codes;
  std::vector<std::wstring> blocked_hook_codes;
  std::vector<std::wstring> blocked_hook_names;
  std::vector<std::wstring> preferred_hook_codes;
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

inline std::vector<std::string> SplitSemicolons(const std::string& value) {
  std::vector<std::string> fields;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t separator = value.find(';', start);
    fields.push_back(value.substr(start, separator - start));
    if (separator == std::string::npos) break;
    start = separator + 1;
  }
  return fields;
}

inline bool LunaHookCodeMatchesBlock(const std::wstring& blocked,
                                     const wchar_t* hook_code) {
  if (blocked.empty() || hook_code == nullptr) return false;
  const std::wstring actual(hook_code);
  return actual == blocked ||
         (actual.size() > blocked.size() &&
          actual.compare(0, blocked.size(), blocked) == 0 &&
          actual[blocked.size()] == L':');
}

inline bool LunaHostLogConfirmsHookRemoval(const wchar_t* log,
                                           const std::wstring& hook_name) {
  if (log == nullptr || hook_name.empty()) return false;
  size_t length = std::wcslen(log);
  while (length > 0 && std::iswspace(log[length - 1])) --length;
  return length >= hook_name.size() &&
         std::wstring(log + length - hook_name.size(), hook_name.size()) ==
             hook_name;
}

// TSV schema: exe_sha256, module_name, module_sha256, codepage, hook_code,
// label, options. Options are semicolon-separated: `pc-hooks` enables generic
// candidates; `block=<hook-code-without-module>` removes a known-crashing
// auto-detected hook; `block-name=<Luna-hook-name>` confirms that asynchronous
// removal completed; `prefer=<hook-code-without-module>` limits automatic text
// output to a known-good hook; `defer-ms=<milliseconds>` waits for fragile
// engines to initialize before installing the guarded hooks. A row may identify
// by executable hash, module hash, or both.
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
    if (fields.size() >= 7) {
      for (const std::string& option : SplitSemicolons(fields[6])) {
        if (option == "pc-hooks") {
          result.enable_pc_hooks = true;
        } else if (option.rfind("block=", 0) == 0 && option.size() > 6) {
          const std::string code = option.substr(6);
          result.blocked_hook_codes.emplace_back(code.begin(), code.end());
        } else if (option.rfind("block-name=", 0) == 0 &&
                   option.size() > 11) {
          const std::string name = option.substr(11);
          result.blocked_hook_names.emplace_back(name.begin(), name.end());
        } else if (option.rfind("prefer=", 0) == 0 && option.size() > 7) {
          const std::string code = option.substr(7);
          result.preferred_hook_codes.emplace_back(code.begin(), code.end());
        } else if (option.rfind("defer-ms=", 0) == 0 &&
                   option.size() > 9) {
          const unsigned long delay =
              std::strtoul(option.c_str() + 9, nullptr, 10);
          if (delay <= 30000) {
            result.defer_until_running_ms = static_cast<uint32_t>(delay);
          }
        }
      }
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
