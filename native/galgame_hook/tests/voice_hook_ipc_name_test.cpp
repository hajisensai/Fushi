#include "voice_hook_ipc.h"

#include <cassert>

int main() {
  using fushi_voice_hook::ComponentUsesLegacyHibikiIpc;
  using fushi_voice_hook::ReadyEventName;
  using fushi_voice_hook::SharedMemoryName;

  assert(ComponentUsesLegacyHibikiIpc(
      L"D:\\hibiki\\Hibiki\\voice_hook\\x86\\hibiki_voice_injector.exe"));
  assert(ComponentUsesLegacyHibikiIpc(
      L"D:\\hibiki\\Hibiki\\voice_hook\\x86\\HIBIKI_VOICE_HOOK.DLL"));
  assert(!ComponentUsesLegacyHibikiIpc(
      L"D:\\fushi\\voice_hook\\x86\\fushi_voice_injector.exe"));
  assert(!ComponentUsesLegacyHibikiIpc(
      L"D:\\games\\hibiki_voice_hook.dll.backup"));
  assert(!ComponentUsesLegacyHibikiIpc(L""));

  assert(SharedMemoryName(32464, true) ==
         L"Local\\HibikiVoiceHook_32464");
  assert(ReadyEventName(32464, true) ==
         L"Local\\HibikiVoiceHookReady_32464");
  assert(SharedMemoryName(32464) == L"Local\\FushiVoiceHook_32464");
  assert(ReadyEventName(32464) == L"Local\\FushiVoiceHookReady_32464");
  return 0;
}
