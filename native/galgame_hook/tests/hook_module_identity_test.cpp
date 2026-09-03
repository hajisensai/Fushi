// Release 配置定义 NDEBUG；测试必须保留真实断言。
#undef NDEBUG

#include <cassert>
#include <fstream>
#include <sstream>
#include <string>

#include "hook_module_identity.h"

using fushi_voice_hook::EvaluateHookModuleIdentity;
using fushi_voice_hook::HookModuleIdentityRequiresRestart;
using fushi_voice_hook::HookModuleIdentityStatus;

namespace {

std::string ReadSourceFile(const char* path) {
  std::ifstream input(path, std::ios::binary);
  assert(input.is_open() && "扫不到源码文件 —— 判红，别让空集假绿");
  std::ostringstream buffer;
  buffer << input.rdbuf();
  std::string text = buffer.str();
  // 守卫不能因为换行风格而恒不匹配（那是最典型的零断言空转）。
  std::string normalized;
  normalized.reserve(text.size());
  for (char c : text) {
    if (c != '\r') normalized.push_back(c);
  }
  return normalized;
}

size_t CountOccurrences(const std::string& haystack, const std::string& needle) {
  size_t count = 0;
  for (size_t at = haystack.find(needle); at != std::string::npos;
       at = haystack.find(needle, at + needle.size())) {
    ++count;
  }
  return count;
}

// 取一个顶层函数的函数体文本：从签名处到第 0 列的收尾大括号。全文件裸 grep 不行 ——
// `Sha256File(` 在 injector 里另有五处合法调用，扫全文件既会假阳也会假阴。
std::string ExtractTopLevelFunctionBody(const std::string& source,
                                        const std::string& signature_anchor) {
  const size_t begin = source.find(signature_anchor);
  assert(begin != std::string::npos && "扫不到目标函数签名 —— 判红");
  assert(source.find(signature_anchor, begin + signature_anchor.size()) ==
             std::string::npos &&
         "目标函数签名出现多次，函数体切分不再唯一 —— 判红");
  const size_t end = source.find("\n}", begin);
  assert(end != std::string::npos && "扫不到函数体收尾大括号 —— 判红");
  const std::string body = source.substr(begin, end - begin);
  assert(body.size() > 200 && "函数体短到不可能是真实现 —— 判红");
  return body;
}

// 纯函数判据本身。
void TestIdentityReducer() {
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
}

// v17 真正要覆盖的那一格：**同一路径 + 不同构建**。
//
// 这一格在 v17 之前是纯理论的：调用方两侧都用 Sha256File 读磁盘，而能走到摘要比较时
// 路径已经相等，于是两次读的是同一个文件、摘要恒等，kDigestMismatch 永不可达。
// v17 把驻留侧摘要换成 header 里由**注入者本人**留下的记录之后，它才成为真实可达状态。
void TestResidentDigestDecidesSameSameBuildMismatch() {
  const std::wstring path =
      L"D:\\Fushi\\voice_hook\\x64\\fushi_voice_hook.dll";
  const std::string on_disk_now(64, 'c');   // 自更新后磁盘上的新构建
  const std::string resident_build(64, 'd');  // 游戏进程里还驻留着的旧构建

  const HookModuleIdentityStatus mismatch = EvaluateHookModuleIdentity(
      true, path, path, on_disk_now, resident_build);
  assert(mismatch == HookModuleIdentityStatus::kDigestMismatch);
  assert(HookModuleIdentityRequiresRestart(mismatch) &&
         "同路径不同构建必须要求重启游戏清掉旧 DLL");

  // header 里那条记录为空（旧注入算不出摘要，字段保持全 0）时只能 fail-open 到
  // 有界重试，不许把「不知道」当成「不匹配」去让用户重启游戏。
  const HookModuleIdentityStatus unavailable =
      EvaluateHookModuleIdentity(true, path, path, on_disk_now, "");
  assert(unavailable == HookModuleIdentityStatus::kDigestUnavailable);
  assert(!HookModuleIdentityRequiresRestart(unavailable));

  // 同一构建仍必须放行，否则每次重连都要求重启游戏。
  assert(EvaluateHookModuleIdentity(true, path, path, on_disk_now,
                                    on_disk_now) ==
         HookModuleIdentityStatus::kMatch);
}

// 调用侧守卫。上面的纯函数判据再对，只要调用方把**两侧摘要都从磁盘读**，
// kDigestMismatch 就重新恒不可达 —— 而这种退化纯函数测试一个字节都测不到。
void TestInjectorTakesResidentDigestFromSharedHeader() {
  const std::string source = ReadSourceFile(FUSHI_INJECTOR_MAIN_SOURCE);
  const std::string body = ExtractTopLevelFunctionBody(
      source, "HookModuleIdentityStatus InspectResidentHookIdentity(");

  // 请求侧摘要来自磁盘（本次要注入的那份 DLL），驻留侧不许再读磁盘。
  assert(CountOccurrences(body, "Sha256File(") == 1 &&
         "驻留身份判据里只允许对**请求侧**调用一次 Sha256File；两边都读磁盘"
         "会让 kDigestMismatch 恒不可达");
  assert(body.find("hook_module_sha256") != std::string::npos &&
         "驻留侧摘要必须取自共享头里注入者留下的记录");
  assert(body.find("strnlen") != std::string::npos &&
         "共享内存里的字节不可信，必须定长安全读，不许假定有 NUL");

  // 调用点必须把已映射的既有 header 传进来 —— 否则上面那条记录永远读不到。
  assert(source.find("InspectResidentHookIdentity(pid, dll_path, header)") !=
             std::string::npos &&
         "调用点必须把已 MapViewOfFile 的既有映射头传进身份判据");

  // 写侧：只有创建新映射的那次注入才留档，且写的是本次注入 DLL 的摘要。
  assert(source.find("memcpy(header->hook_module_sha256") !=
             std::string::npos &&
         "injector 必须在新建映射时把本次注入 DLL 的摘要写进 header");
}

}  // namespace

int main() {
  TestIdentityReducer();
  TestResidentDigestDecidesSameSameBuildMismatch();
  TestInjectorTakesResidentDigestFromSharedHeader();
  return 0;
}
