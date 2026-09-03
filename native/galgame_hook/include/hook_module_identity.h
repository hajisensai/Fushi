#pragma once

#include <algorithm>
#include <cctype>
#include <cwchar>
#include <string>

namespace fushi_voice_hook {

// 已有共享映射只能由创建它的那份驻留 hook DLL 继续服务。仅凭 ABI + hooked=1 不足以
// 证明本次 injector 请求的是同一构建：Fushi 更新后，旧 DLL 仍会跟游戏进程一起驻留，
// 而旧映射也仍是 ready。此时复用会把新 helper 的能力误报成已生效。
enum class HookModuleIdentityStatus {
  kMatch,
  kModuleMissing,
  kPathUnavailable,
  kPathMismatch,
  kDigestUnavailable,
  kDigestMismatch,
};

inline bool EqualAsciiCaseInsensitive(const std::string& lhs,
                                      const std::string& rhs) {
  if (lhs.size() != rhs.size()) return false;
  return std::equal(lhs.begin(), lhs.end(), rhs.begin(),
                    [](unsigned char left, unsigned char right) {
                      return std::tolower(left) == std::tolower(right);
                    });
}

// 路径由 Win32 调用方先绝对化；这里保留为纯判定，便于不启动游戏地覆盖全部 fail-closed
// 分支。即使两个不同路径恰好包含相同字节也不复用：目标进程必须驻留“本次请求路径”那份
// DLL，而不是另一个安装/临时目录里的副本。
inline HookModuleIdentityStatus EvaluateHookModuleIdentity(
    bool module_found, const std::wstring& requested_normalized_path,
    const std::wstring& loaded_normalized_path,
    const std::string& requested_sha256,
    const std::string& loaded_sha256) {
  if (!module_found) return HookModuleIdentityStatus::kModuleMissing;
  if (requested_normalized_path.empty() || loaded_normalized_path.empty()) {
    return HookModuleIdentityStatus::kPathUnavailable;
  }
  if (_wcsicmp(requested_normalized_path.c_str(),
               loaded_normalized_path.c_str()) != 0) {
    return HookModuleIdentityStatus::kPathMismatch;
  }
  if (requested_sha256.empty() || loaded_sha256.empty()) {
    return HookModuleIdentityStatus::kDigestUnavailable;
  }
  if (!EqualAsciiCaseInsensitive(requested_sha256, loaded_sha256)) {
    return HookModuleIdentityStatus::kDigestMismatch;
  }
  return HookModuleIdentityStatus::kMatch;
}

inline const char* HookModuleIdentityStatusToken(
    HookModuleIdentityStatus status) {
  switch (status) {
    case HookModuleIdentityStatus::kMatch:
      return "match";
    case HookModuleIdentityStatus::kModuleMissing:
      return "moduleMissing";
    case HookModuleIdentityStatus::kPathUnavailable:
      return "pathUnavailable";
    case HookModuleIdentityStatus::kPathMismatch:
      return "pathMismatch";
    case HookModuleIdentityStatus::kDigestUnavailable:
      return "digestUnavailable";
    case HookModuleIdentityStatus::kDigestMismatch:
      return "digestMismatch";
  }
  return "unknown";
}

// Only a proven path/content mismatch requires the game process to exit. A
// missing module, unreadable path or unavailable digest can be a transient
// Toolhelp/filesystem race (for example while the previous injector is still
// releasing its mapping), so the host may retry those states with its normal
// bounded backoff.
inline bool HookModuleIdentityRequiresRestart(HookModuleIdentityStatus status) {
  return status == HookModuleIdentityStatus::kPathMismatch ||
         status == HookModuleIdentityStatus::kDigestMismatch;
}

}  // namespace fushi_voice_hook
