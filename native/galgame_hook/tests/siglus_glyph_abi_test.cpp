#ifdef NDEBUG
#undef NDEBUG
#endif
#define NOMINMAX
#include <windows.h>
#include <intrin.h>

#include "../hook/adapters/siglus_lookup.h"

#include <atomic>
#include <cassert>
#include <cstdio>
#include <limits>

static_assert(sizeof(void*) == 4, "This test exercises the real x86 stack ABI");

namespace {
using namespace fushi_voice_hook;
SiglusGlyphLayoutFn g_orig_SiglusGlyphLayout = nullptr;
SiglusEightArgGlyphLayoutFn g_orig_SiglusEightArgGlyphLayout = nullptr;
SiglusLegacyGlyphLayoutFn g_orig_SiglusLegacyGlyphLayout = nullptr;
std::atomic<bool> g_siglus_lookup_capture_enabled{false};
SiglusLookupProfile test_profile;
SiglusGlyphRecord published;
size_t publications = 0, original_calls = 0;
uint8_t original_result = 0xa5;
bool glyph_owned = true;
void* expected_self = nullptr;
constexpr uintptr_t args[] = {0x12345678u, 0x80000001u, 0x3f800000u,
    0xdeadbeefu, 5u, 6u, 7u, 8u, 9u, 10u, 11u, 12u, 13u, 14u, 0xffffffffu};

const SiglusLookupProfile* ActiveSiglusLookupProfile() { return &test_profile; }
bool IsSiglusLookupGlyphOwned(void*) { return glyph_owned; }
void PublishSiglusLookupGlyphEvent(uint16_t code_unit, int32_t x, int32_t y,
                                   int32_t extent) {
  published = {code_unit, extent, x, y};
  ++publications;
}

#include "../hook/adapters/siglus_lookup_glyph.inc"

uint8_t __fastcall OriginalModern(void* self, void*, uintptr_t a1,
    uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6,
    uintptr_t a7, uintptr_t a8, uintptr_t a9, uintptr_t a10) {
  assert(self == expected_self);
  const uintptr_t observed[] = {a1,a2,a3,a4,a5,a6,a7,a8,a9,a10};
  assert(memcmp(observed, args, sizeof(observed)) == 0);
  ++original_calls;
  return original_result;
}

uint8_t __stdcall OriginalLegacy(void* self, uintptr_t a1, uintptr_t a2,
    uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6, uintptr_t a7,
    uintptr_t a8, uintptr_t a9, uintptr_t a10, uintptr_t a11, uintptr_t a12,
    uintptr_t a13, uintptr_t a14, uintptr_t a15) {
  assert(self == expected_self);
  const uintptr_t observed[] = {a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15};
  assert(memcmp(observed, args, sizeof(observed)) == 0);
  ++original_calls;
  return original_result;
}

uint8_t __fastcall OriginalEightArg(void* self, void*, uintptr_t a1,
    uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6,
    uintptr_t a7, uintptr_t a8) {
  assert(self == expected_self);
  const uintptr_t observed[] = {a1,a2,a3,a4,a5,a6,a7,a8};
  assert(memcmp(observed, args, sizeof(observed)) == 0);
  ++original_calls;
  return original_result;
}

// Keep calls indirect and prevent inlining so optimizer cannot erase the
// callee stack-cleanup contract that this regression exercises.
__declspec(noinline) uint8_t CallModern() {
  decltype(&Detour_SiglusGlyphLayout) volatile callback = &Detour_SiglusGlyphLayout;
  return callback(expected_self, nullptr, args[0],args[1],args[2],args[3],args[4],
                   args[5],args[6],args[7],args[8],args[9]);
}
__declspec(noinline) uint8_t CallLegacy() {
  SiglusLegacyGlyphLayoutFn volatile callback = &Detour_SiglusLegacyGlyphLayout;
  return callback(expected_self, args[0],args[1],args[2],args[3],args[4],args[5],
      args[6],args[7],args[8],args[9],args[10],args[11],args[12],args[13],args[14]);
}

__declspec(noinline) uint8_t CallEightArg() {
  decltype(&Detour_SiglusEightArgGlyphLayout) volatile callback =
      &Detour_SiglusEightArgGlyphLayout;
  uintptr_t before = 0, after = 0;
  __asm mov before, esp
  const uint8_t result = callback(expected_self, nullptr, args[0],args[1],
      args[2],args[3],args[4],args[5],args[6],args[7]);
  __asm mov after, esp
  assert(before == after);
  return result;
}

template <typename T>
void Put(uint8_t* bytes, size_t offset, T value) {
  memcpy(bytes + offset, &value, sizeof(value));
}
}  // namespace

int main() {
  uint8_t record[0x48] = {};
  expected_self = record;
  assert(CallModern() == 0 && CallLegacy() == 0 && CallEightArg() == 0 &&
         original_calls == 0);
  // Fastcall's unused EDX shim has the same stack arguments as thiscall.
  g_orig_SiglusGlyphLayout = reinterpret_cast<SiglusGlyphLayoutFn>(&OriginalModern);
  g_orig_SiglusLegacyGlyphLayout = &OriginalLegacy;
  g_orig_SiglusEightArgGlyphLayout =
      reinterpret_cast<SiglusEightArgGlyphLayoutFn>(&OriginalEightArg);
  for (int i = 0; i < 4096; ++i) {
    assert(CallModern() == 0xa5 && CallLegacy() == 0xa5 && CallEightArg() == 0xa5);
  }
  assert(original_calls == 12288 && publications == 0);
  original_result = 0;
  assert(CallModern() == 0 && CallLegacy() == 0 && CallEightArg() == 0);
  assert(original_calls == 12291);

  test_profile.viewport_width = 1280;
  test_profile.viewport_height = 720;
  test_profile.dialogue_glyph_return_rva = 0x100;
  const uintptr_t caller = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr)) + 0x100;
  Put(record, 4, uint32_t{0x3042});
  Put(record, 8, int32_t{30});
  Put(record, 0x34, 240.0f);
  Put(record, 0x38, 560.0f);
  Put(record, 0x40, 400.0f);
  Put(record, 0x44, 300.0f);
  g_siglus_lookup_capture_enabled = true;
  CaptureSiglusLookupGlyph(record, 1, caller, SiglusGlyphLayoutAbi::kEcxTenArguments);
  assert(publications == 1 && published.x == 400 && published.y == 300);
  CaptureSiglusLookupGlyph(record, 1, caller, SiglusGlyphLayoutAbi::kStackSixteenArguments);
  assert(publications == 1); // A valid record under the wrong ABI is not admitted.
  test_profile.glyph_abi = SiglusGlyphLayoutAbi::kStackSixteenArguments;
  CaptureSiglusLookupGlyph(record, 1, caller, test_profile.glyph_abi);
  assert(publications == 2 && published.x == 240 && published.y == 560);
  glyph_owned = false;
  CaptureSiglusLookupGlyph(record, 1, caller, test_profile.glyph_abi);
  assert(publications == 2);
  glyph_owned = true;
  CaptureSiglusLookupGlyph(record, 0, caller, test_profile.glyph_abi);
  CaptureSiglusLookupGlyph(record, 1, caller + 1, test_profile.glyph_abi);
  CaptureSiglusLookupGlyph(record, 1, 0, test_profile.glyph_abi);
  CaptureSiglusLookupGlyph(nullptr, 1, caller, test_profile.glyph_abi);
  CaptureSiglusLookupGlyph(reinterpret_cast<void*>(1), 1, caller, test_profile.glyph_abi);
  assert(publications == 2);
  g_siglus_lookup_capture_enabled = false;
  CaptureSiglusLookupGlyph(record, 1, caller, test_profile.glyph_abi);
  assert(publications == 2);
  test_profile.glyph_abi = SiglusGlyphLayoutAbi::kEcxEightArguments;
  CaptureSiglusLookupGlyph(record, 1, caller, test_profile.glyph_abi);
  assert(publications == 2); // Capture disabled for every ABI.
  g_siglus_lookup_capture_enabled = true;
  CaptureSiglusLookupGlyph(record, 1, caller,
      SiglusGlyphLayoutAbi::kEcxTenArguments);
  assert(publications == 2); // Shared fields cannot admit the wrong callback.
  CaptureSiglusLookupGlyph(record, 1, caller, test_profile.glyph_abi);
  assert(publications == 3 && published.x == 400 && published.y == 300);
  CaptureSiglusLookupGlyph(record, 1, caller + 1, test_profile.glyph_abi);
  CaptureSiglusLookupGlyph(record, 0, caller, test_profile.glyph_abi);
  assert(publications == 3);
  glyph_owned = false;
  CaptureSiglusLookupGlyph(record, 1, caller, test_profile.glyph_abi);
  assert(publications == 3);
  glyph_owned = true;
  Put(record, 0x40, std::numeric_limits<float>::quiet_NaN());
  CaptureSiglusLookupGlyph(record, 1, caller, test_profile.glyph_abi);
  CaptureSiglusLookupGlyph(reinterpret_cast<void*>(1), 1, caller,
      test_profile.glyph_abi);
  assert(publications == 3);
  std::puts("Siglus x86 ABI: argument bits, AL, stack cleanup and capture gates passed");
}
