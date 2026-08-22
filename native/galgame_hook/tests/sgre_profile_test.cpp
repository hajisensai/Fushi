// SGRE 归档能力的负向门测试。
//
// 这份测试存在的理由是 CLAUDE.md 的硬规则：「引擎特例必须收进 profile/adapter；共享中间件
// 不得仅凭 DLL 名启用，且须有跨引擎负向测试」。测试可执行文件旁边没有 wind3d11data 目录，
// 因此它就是「任何一个不是 SGRE 的进程」的代表：profile 必须不匹配，归档必须不映射。
#undef NDEBUG
#include <cassert>

#include "sgre_voice_archive.h"

int main() {
  // ① 跨引擎负向：本进程不是 SGRE 布局，profile 必须不匹配。
  //    旧实现按 exe 文件名门控，这条断言在那种实现下依然会过——所以下面②③才是真正
  //    钉住「门控依据换成了目录布局」的那两条。
  assert(!fushi_voice_hook::MatchesSgreProfile(nullptr));

  // ② 默认未激活：adapter 没装之前，通用 XAudio2 worker 问到的必须是 false。
  assert(!fushi_voice_hook::SgreProfileActive());

  // ③ profile 未激活时尝试打开必须失败，且**不得**把 attempted 记成已尝试：
  //    adapter 安装与第一批音频作业之间没有顺序保证，提前记一次失败会把这条路径
  //    在本次会话里永久毒死。
  assert(!fushi_voice_hook::OpenSgreVoiceArchive());
  assert(!fushi_voice_hook::g_sgre_voice_archive.attempted);

  // ④ 激活之后允许真正尝试一次（本机没有归档文件，所以仍然失败），此时才记 attempted。
  InterlockedExchange(&fushi_voice_hook::g_sgre_profile_active, 1);
  assert(!fushi_voice_hook::OpenSgreVoiceArchive());
  assert(fushi_voice_hook::g_sgre_voice_archive.attempted);

  // ⑤ 归档未映射时，任何负载都不能被判成角色语音资源。
  const unsigned char payload[512] = {};
  unsigned long long offset = 0;
  assert(!fushi_voice_hook::FindSgreVoiceArchivePayload(payload, sizeof(payload),
                                                        &offset));

  InterlockedExchange(&fushi_voice_hook::g_sgre_profile_active, 0);
  return 0;
}
