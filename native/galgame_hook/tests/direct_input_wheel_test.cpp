#undef NDEBUG
#define DIRECTINPUT_VERSION 0x0800
#define NOMINMAX
#include <windows.h>
#include <dinput.h>
#include <atomic>
#include <cassert>
#include <cstring>
#include "lookup_wheel_source.h"

namespace {
enum class GenericDirectInputFormatState { kStandardMouse };
struct GenericDirectInputMouseDevice { GenericDirectInputFormatState format; };
SRWLOCK g_generic_shield_state_lock = SRWLOCK_INIT;
GenericDirectInputMouseDevice* FindGenericDirectInputDeviceLocked(void*) { return nullptr; }
void HookLogLine(const wchar_t*) {}
HWND FindGameMainWindow() { return nullptr; }
bool foreground_game = true;
HWND Foreground() { return reinterpret_cast<HWND>(1); }
DWORD ForegroundPid(HWND, DWORD* pid) {
  *pid = GetCurrentProcessId() + (foreground_game ? 0 : 1); return 1;
}
struct Device {
  void* vtable[16]{};
  void* identity = nullptr;
  DWORD type = DI8DEVTYPE_MOUSE, mode = DIPROPAXISMODE_REL, z = 0;
  bool sysmouse = true;
  bool property_ok = true;
};
void* VtableSlot(void* device, size_t slot) {
  return static_cast<Device*>(device)->vtable[slot];
}
HRESULT STDMETHODCALLTYPE Query(void* self, REFIID, void** out) {
  auto* device = static_cast<Device*>(self);
  *out = device->identity ? device->identity : self; return S_OK;
}
ULONG STDMETHODCALLTYPE Release(void*) { return 1; }
HRESULT STDMETHODCALLTYPE Caps(void* self, DIDEVCAPS* caps) {
  caps->dwDevType = static_cast<Device*>(self)->type; return DI_OK;
}
HRESULT STDMETHODCALLTYPE Property(void* self, REFGUID, DIPROPHEADER* header) {
  if (!static_cast<Device*>(self)->property_ok) return DIERR_INPUTLOST;
  reinterpret_cast<DIPROPDWORD*>(header)->dwData = static_cast<Device*>(self)->mode;
  return DI_OK;
}
HRESULT STDMETHODCALLTYPE Info(void* self, void* raw) {
  const GUID sys{0x6f1d2b60u,0xd5a0u,0x11cfu,{0xbf,0xc7,0x44,0x45,0x53,0x54,0,0}};
  GUID instance = static_cast<Device*>(self)->sysmouse ? sys : GUID{};
  std::memcpy(static_cast<uint8_t*>(raw) + 4, &instance, sizeof(instance)); return DI_OK;
}
HRESULT STDMETHODCALLTYPE Object(void* self, void* raw, DWORD offset, DWORD how) {
  assert(how == DIPH_BYOFFSET);
  if (offset != static_cast<Device*>(self)->z) return DIERR_OBJECTNOTFOUND;
  const GUID z{0xa36d02e2u,0xc9f3u,0x11cfu,{0xbf,0xc7,0x44,0x45,0x53,0x54,0,0}};
  std::memcpy(static_cast<uint8_t*>(raw) + 4, &z, sizeof(z)); return DI_OK;
}
#define GetForegroundWindow Foreground
#define GetWindowThreadProcessId ForegroundPid
#include "../hook/generic_direct_input_wheel.inc"
#undef GetForegroundWindow
#undef GetWindowThreadProcessId
fushi_voice_hook::LookupWheelSource source;
Device Mouse(DWORD z = 0) {
  Device out; out.z = z;
  out.vtable[0] = reinterpret_cast<void*>(&Query);
  out.vtable[2] = reinterpret_cast<void*>(&Release);
  out.vtable[3] = reinterpret_cast<void*>(&Caps);
  out.vtable[5] = reinterpret_cast<void*>(&Property);
  out.vtable[14] = reinterpret_cast<void*>(&Object);
  out.vtable[15] = reinterpret_cast<void*>(&Info); return out;
}
void Reset() {
  g_generic_kirikiri_wheel_enabled.store(true);
  for (auto& kind : g_generic_direct_input_kinds) kind = {};
  for (auto& consumer : g_wheel_consumers) consumer = {};
  source = {}; source.game_pid = source.host_pid = GetCurrentProcessId();
  source.generation = 1; source.ready = 1;
  g_wheel_source_published.store(&source); foreground_game = true;
}
LONG State(Device* device, LONG raw) {
  StripHostOverlayWheelFromMouseState(device, sizeof(raw), &raw); return raw;
}
void TestEventOwnershipAndDelayedReads() {
  Reset(); auto device = Mouse();
  assert(State(&device, 120) == 0); assert(source.consumer_ready == 1);
  assert(State(&device, -120) == 0); // owned event: outside total never advances
  fushi_voice_hook::PublishOutsideWheel(&source, -120);
  assert(State(&device, 0) == -120); // owned +120 and outside -120 cancel in DI
  assert(State(&device, 0) == 0);
  assert(State(&device, 120) == 0);
  fushi_voice_hook::PublishOutsideWheel(&source, 120);
  assert(State(&device, 0) == 120); // journal arriving after DI read delivers once
  assert(State(&device, 120) == 0);
  assert(State(&device, -120) == 0); // close/move does not release the owned tail
  fushi_voice_hook::PublishOutsideWheel(&source, -240);
  assert(State(&device, -360) == -240);
}
void TestCanonicalIdentityAndLifecycle() {
  Reset(); auto base = Mouse(), alternate = Mouse(); alternate.identity = &base;
  assert(State(&base, 0) == 0);
  fushi_voice_hook::PublishOutsideWheel(&source, 120);
  assert(State(&alternate, 120) == 120); assert(State(&base, 0) == 0);
  source.sequence |= 1; assert(State(&base, 120) == 0); source.sequence += 1;
  source.generation = 2; source.outside_total = 999;
  assert(State(&base, 120) == 0);
  ForgetGenericDirectInputKind(&base); assert(State(&base, 120) == 0);
  source.ready = 0;
  assert(State(&base, 120) == 0); assert(State(&base, -120) == 0);
  assert(State(&base, 0) == 0); assert(State(&base, 120) == 0);
  ForgetGenericDirectInputKind(&base); assert(State(&base, 120) == 0);
  foreground_game = false; assert(State(&base, 120) == 0);
  foreground_game = true; assert(State(&base, 120) == 0);
  base.property_ok = false; assert(State(&base, 120) == 0);
  base.property_ok = true; assert(State(&base, 120) == 0);
  source.ready = 1; source.generation = 3;
  assert(State(&base, 120) == 0);
  fushi_voice_hook::PublishOutsideWheel(&source, 120);
  assert(State(&base, 0) == 120);
  source.ready = 2; assert(State(&base, 120) == 0);
}
void TestNegativeDevicesAndModes() {
  Reset(); auto device = Mouse(); assert(State(&device, 0) == 0);
  device.mode = DIPROPAXISMODE_ABS; assert(State(&device, 123) == 123);
  device.mode = DIPROPAXISMODE_REL; assert(State(&device, 120) == 0);
  foreground_game = false; fushi_voice_hook::PublishOutsideWheel(&source, 120);
  assert(State(&device, 120) == 0);
  foreground_game = true; assert(State(&device, 0) == 0);
  g_generic_kirikiri_wheel_enabled.store(false); assert(State(&device, 120) == 120);
  Reset(); device = Mouse(); device.type = DI8DEVTYPE_KEYBOARD;
  assert(State(&device, 120) == 120);
  Reset(); device = Mouse(); device.sysmouse = false; assert(State(&device, 120) == 120);
  Reset(); device = Mouse(4); assert(State(&device, 120) == 120);
  Reset(); device = Mouse(); DIMOUSESTATE2 standard{1,2,120,{0x80,1,2,3,4,5,6,7}};
  const auto before = standard;
  StripHostOverlayWheelFromMouseState(&device, sizeof(standard), &standard);
  assert(std::memcmp(&standard, &before, sizeof(standard)) == 0);
}
void TestCacheEvictionAndBoundedDiagnostics() {
  Reset(); Device devices[48];
  for (auto& device : devices) { device = Mouse(); assert(State(&device, 0) == 0); }
  fushi_voice_hook::PublishOutsideWheel(&source, 120);
  assert(State(&devices[47], 120) == 120);
  g_wheel_diagnostic_budget.store(1);
  ForgetGenericDirectInputKind(&devices[47]); assert(State(&devices[47], 0) == 0);
  assert(g_wheel_diagnostic_budget.load() == 0);
  ForgetGenericDirectInputKind(&devices[47]); assert(State(&devices[47], 0) == 0);
  assert(g_wheel_diagnostic_budget.load() == 0);
}
} // namespace
int main() {
  TestEventOwnershipAndDelayedReads(); TestCanonicalIdentityAndLifecycle();
  TestNegativeDevicesAndModes();
  TestCacheEvictionAndBoundedDiagnostics();
}
