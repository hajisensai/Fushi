#include <cassert>
#include <cstdint>

#include "voice_hook_ipc.h"

using fushi_voice_hook::HasReadyGameResourceAudio;
using fushi_voice_hook::kDiagKirikiriVoiceStreamHookReady;
using fushi_voice_hook::kDiagFfmpegResourceHooksReady;
using fushi_voice_hook::kDiagVisualArtsOvkHooksReady;
using fushi_voice_hook::kDiagSiglusOvkHooksReady;
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

  assert(!HasReadyGameResourceAudio(0, kDiagUnityIl2CppHooksReady));
  assert(!HasReadyGameResourceAudio(0, kDiagUnityResourceExtractorReady));
  assert(HasReadyGameResourceAudio(
      0, kDiagUnityIl2CppHooksReady | kDiagUnityResourceExtractorReady));
  return 0;
}
