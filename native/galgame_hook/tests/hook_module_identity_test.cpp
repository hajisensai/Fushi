// Release 配置定义 NDEBUG；测试必须保留真实断言。
#undef NDEBUG

#include <cassert>
#include <string>

#include "hook_module_identity.h"

using fushi_voice_hook::EvaluateHookModuleIdentity;
using fushi_voice_hook::HookModuleIdentityRequiresRestart;
using fushi_voice_hook::HookModuleIdentityStatus;

int main() {
  const std::wstring requested =
      L"D:\\Fushi\\voice_hook\\x64\\fushi_voice_hook.dll";
  const std::string digest(64, 'a');

  assert(EvaluateHookModuleIdentity(false, requested, L"", digest, "") ==
         HookModuleIdentityStatus::kModuleMissing);
  assert(EvaluateHookModuleIdentity(true, requested, L"", digest, digest) ==
         HookModuleIdentityStatus::kPathUnavailable);

  // Windows 路径和 SHA 十六进制大小写不影响同一身份。
  assert(EvaluateHookModuleIdentity(
             true, requested,
             L"d:\\fushi\\VOICE_HOOK\\x64\\fushi_voice_hook.dll",
             digest, std::string(64, 'A')) ==
         HookModuleIdentityStatus::kMatch);

  // 相同字节但来自旧 staging 路径也不能复用。
  assert(EvaluateHookModuleIdentity(
             true, requested,
             L"D:\\stale\\voice_hook\\x64\\fushi_voice_hook.dll",
             digest, digest) == HookModuleIdentityStatus::kPathMismatch);

  // 同一路径若无法证明摘要或摘要不同，同样 fail closed。
  assert(EvaluateHookModuleIdentity(true, requested, requested, "", digest) ==
         HookModuleIdentityStatus::kDigestUnavailable);
  assert(EvaluateHookModuleIdentity(true, requested, requested, digest,
                                    std::string(64, 'b')) ==
         HookModuleIdentityStatus::kDigestMismatch);

  assert(HookModuleIdentityRequiresRestart(
      HookModuleIdentityStatus::kPathMismatch));
  assert(HookModuleIdentityRequiresRestart(
      HookModuleIdentityStatus::kDigestMismatch));
  assert(!HookModuleIdentityRequiresRestart(
      HookModuleIdentityStatus::kModuleMissing));
  assert(!HookModuleIdentityRequiresRestart(
      HookModuleIdentityStatus::kPathUnavailable));
  assert(!HookModuleIdentityRequiresRestart(
      HookModuleIdentityStatus::kDigestUnavailable));
  assert(!HookModuleIdentityRequiresRestart(HookModuleIdentityStatus::kMatch));
  return 0;
}
