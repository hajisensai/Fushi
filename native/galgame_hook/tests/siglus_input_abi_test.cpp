#ifdef NDEBUG
#undef NDEBUG
#endif
#define NOMINMAX
#include <windows.h>
#include <intrin.h>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>

static_assert(sizeof(void*) == 4);
namespace {
using MessageFn = void(__stdcall*)(UINT, WPARAM, LPARAM);
using LegacyMessageFn = void(__fastcall*)(LPARAM, WPARAM, UINT);
decltype(&GetKeyState) g_orig_SiglusGetKeyState = nullptr;
decltype(&GetKeyboardState) g_orig_SiglusGetKeyboardState = nullptr;
MessageFn g_orig_SiglusInputMessage = nullptr;
LegacyMessageFn g_orig_SiglusLegacyInputMessage = nullptr;
int sampled_calls = 0, api_calls = 0, message_calls = 0, policy_calls = 0;
int key_api_calls = 0, table_api_calls = 0;
bool toggle_sample = false;
bool consume = false, table = false;
SHORT raw_sample = 0;
BOOL api_result = 7;
constexpr UINT message_value = 0x0201;
constexpr WPARAM wparam_value = 0xabcdef12;
constexpr LPARAM lparam_value = static_cast<LPARAM>(0x89abcdef);

SHORT FilterSiglusLookupLeftButtonSample(SHORT raw, uintptr_t caller, bool keys) {
  assert(caller != 0);
  ++sampled_calls;
  raw_sample = raw;
  table = keys;
  return consume ? static_cast<SHORT>(static_cast<uint16_t>(raw) & ~0x8000u) : raw;
}
bool ConsumeSiglusLookupInputMessage(UINT message, LPARAM lparam, uintptr_t caller) {
  assert(message == message_value && lparam == lparam_value && caller != 0);
  ++policy_calls;
  return consume;
}
#include "../hook/adapters/siglus_lookup_input.inc"

SHORT WINAPI KeyOriginal(int key) {
  assert(key == VK_LBUTTON || key == VK_SHIFT);
  ++api_calls;
  ++key_api_calls;
  return static_cast<SHORT>(0x80a5);
}
BOOL WINAPI KeysOriginal(PBYTE keys) {
  ++api_calls;
  ++table_api_calls;
  if (api_result != FALSE && keys != nullptr) {
    for (int i = 0; i < 256; ++i) keys[i] = static_cast<BYTE>(i ^ 0xa5);
    if (toggle_sample) keys[VK_LBUTTON] = 0x81;
  }
  return api_result;
}
void CheckMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  assert(message == message_value && wparam == wparam_value && lparam == lparam_value);
  ++message_calls;
}
void __stdcall MessageOriginal(UINT message, WPARAM wparam, LPARAM lparam) {
  CheckMessage(message, wparam, lparam);
}
void __fastcall LegacyOriginal(LPARAM lparam, WPARAM wparam, UINT message) {
  CheckMessage(message, wparam, lparam);
}
__declspec(noinline) void CallMessages() {
  MessageFn volatile modern = &Detour_SiglusInputMessage;
  LegacyMessageFn volatile legacy = &Detour_SiglusLegacyInputMessage;
  modern(message_value, wparam_value, lparam_value);
  legacy(lparam_value, wparam_value, message_value);
}
__declspec(noinline) BOOL CallKeys(PBYTE keys) {
  decltype(&GetKeyboardState) volatile callback = &Detour_SiglusGetKeyboardState;
  return callback(keys);
}
} // namespace

int main() {
  BYTE keys[256] = {};
  assert(CallKeys(keys) == FALSE);
  assert(Detour_SiglusGetKeyState(VK_LBUTTON) == 0);
  CallMessages();
  assert(api_calls == 0 && sampled_calls == 0 && policy_calls == 0);
  g_orig_SiglusGetKeyState = KeyOriginal;
  g_orig_SiglusGetKeyboardState = KeysOriginal;
  g_orig_SiglusInputMessage = MessageOriginal;
  g_orig_SiglusLegacyInputMessage = LegacyOriginal;
  for (int mode = 0; mode < 2; ++mode) {
    consume = mode != 0;
    for (int n = 0; n < 4096; ++n) {
      assert(CallKeys(keys) == 7);
      assert(table && static_cast<uint16_t>(raw_sample) == 0xa400);
      for (int i = 0; i < 256; ++i) {
        const BYTE expected = static_cast<BYTE>((i ^ 0xa5) &
            ((consume && i == VK_LBUTTON) ? 0x7f : 0xff));
        assert(keys[i] == expected);
      }
      assert(static_cast<uint16_t>(Detour_SiglusGetKeyState(VK_LBUTTON)) ==
          (consume ? 0x00a5 : 0x80a5));
      assert(!table && static_cast<uint16_t>(raw_sample) == 0x80a5);
      const int before = sampled_calls;
      assert(static_cast<uint16_t>(Detour_SiglusGetKeyState(VK_SHIFT)) == 0x80a5);
      assert(sampled_calls == before);
      CallMessages();
    }
  }
  assert(message_calls == 8192 && policy_calls == 16384);
  assert(key_api_calls == 16384 && table_api_calls == 8192);
  assert(api_calls == 24576 && sampled_calls == 16384);
  toggle_sample = true;
  assert(CallKeys(keys) == 7 && keys[VK_LBUTTON] == 1);
  assert(static_cast<uint16_t>(raw_sample) == 0x8100);
  const int before = sampled_calls;
  api_result = FALSE;
  std::memset(keys, 0xbd, sizeof(keys));
  assert(CallKeys(keys) == FALSE && sampled_calls == before);
  for (BYTE key : keys) assert(key == 0xbd);
  api_result = 7;
  assert(CallKeys(nullptr) == 7 && sampled_calls == before);
  assert(key_api_calls == 16384 && table_api_calls == 8195 && api_calls == 24579);
  std::puts("Siglus input x86 ABI: BOOL, key bytes, argument bits, once-only forwarding and stack passed");
}
