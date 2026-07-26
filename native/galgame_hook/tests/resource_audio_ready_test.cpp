#include <cassert>
#include <cstdint>

#include "voice_hook_ipc.h"

using hibiki_voice_hook::HasReadyGameResourceAudio;
using hibiki_voice_hook::kDiagKirikiriVoiceStreamHookReady;
using hibiki_voice_hook::kDiagFfmpegResourceHooksReady;
using hibiki_voice_hook::kDiagSiglusOvkHooksReady;
using hibiki_voice_hook::kDiagUnityIl2CppHooksReady;
using hibiki_voice_hook::kDiagUnityResourceExtractorReady;

int main() {
  assert(!HasReadyGameResourceAudio(0, 0));
  assert(HasReadyGameResourceAudio(kDiagKirikiriVoiceStreamHookReady, 0));
  assert(HasReadyGameResourceAudio(0, kDiagFfmpegResourceHooksReady));
  assert(HasReadyGameResourceAudio(0, kDiagVisualArtsOvkHooksReady));
  assert(HasReadyGameResourceAudio(kDiagSiglusOvkHooksReady, 0));

  assert(!HasReadyGameResourceAudio(0, kDiagUnityIl2CppHooksReady));
  assert(!HasReadyGameResourceAudio(0, kDiagUnityResourceExtractorReady));
  assert(HasReadyGameResourceAudio(
      0, kDiagUnityIl2CppHooksReady | kDiagUnityResourceExtractorReady));
  return 0;
}
