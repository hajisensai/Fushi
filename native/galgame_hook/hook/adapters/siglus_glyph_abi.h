#pragma once

#include <cstdint>

#if defined(_M_IX86)
namespace fushi_voice_hook {
using SiglusGlyphLayoutFn = uint8_t(__thiscall *)(void*, uintptr_t, uintptr_t,
    uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t,
    uintptr_t, uintptr_t);
using SiglusEightArgGlyphLayoutFn = uint8_t(__thiscall *)(void*, uintptr_t,
    uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);
using SiglusLegacyGlyphLayoutFn = uint8_t(__stdcall *)(void*, uintptr_t,
    uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t,
    uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t,
    uintptr_t, uintptr_t);
}  // namespace fushi_voice_hook
#endif
