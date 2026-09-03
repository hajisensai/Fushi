// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>

#include "voice_hook_ipc.h"

using fushi_voice_hook::HasReadyGameResourceAudio;
using fushi_voice_hook::kDiagKirikiriVoiceStreamHookReady;
using fushi_voice_hook::kDiagFfmpegResourceHooksReady;
using fushi_voice_hook::kDiagVisualArtsOvkHooksReady;
using fushi_voice_hook::kDiagSiglusOvkHooksReady;
using fushi_voice_hook::kXAudioDiagGameResourcePublished;
using fushi_voice_hook::kXAudioDiagHunexHfaHooksReady;
using fushi_voice_hook::kXAudioDiagLeafLacHooksReady;
using fushi_voice_hook::kDiagUnityIl2CppHooksReady;
using fushi_voice_hook::kDiagUnityResourceExtractorReady;
using fushi_voice_hook::kDiagElfAi6ArcHooksReady;

int main() {
  assert(!HasReadyGameResourceAudio(0, 0));
  assert(HasReadyGameResourceAudio(kDiagKirikiriVoiceStreamHookReady, 0));
  assert(HasReadyGameResourceAudio(0, kDiagFfmpegResourceHooksReady));
  assert(HasReadyGameResourceAudio(0, kDiagVisualArtsOvkHooksReady));
  assert(HasReadyGameResourceAudio(kDiagSiglusOvkHooksReady, 0));
  assert(HasReadyGameResourceAudio(0, 0, kDiagElfAi6ArcHooksReady));
  assert(HasReadyGameResourceAudio(
      0, 0, 0, kXAudioDiagGameResourcePublished));
  assert(HasReadyGameResourceAudio(0, 0, 0, kXAudioDiagLeafLacHooksReady));
  // HUNEX remains fail-closed until a real HFA/HW member has been published.
  assert(!HasReadyGameResourceAudio(0, 0, 0, kXAudioDiagHunexHfaHooksReady));

  assert(!HasReadyGameResourceAudio(0, kDiagUnityIl2CppHooksReady));
  assert(!HasReadyGameResourceAudio(0, kDiagUnityResourceExtractorReady));
  assert(HasReadyGameResourceAudio(
      0, kDiagUnityIl2CppHooksReady | kDiagUnityResourceExtractorReady));
  return 0;
}
