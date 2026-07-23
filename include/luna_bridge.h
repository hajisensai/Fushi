#ifndef HIBIKI_LUNA_BRIDGE_H_
#define HIBIKI_LUNA_BRIDGE_H_

#include <windows.h>

#include <array>
#include <cstdint>

#include "luna_version.h"

namespace hibiki_voice_hook {

// Hibiki-owned boundary around the vendored LunaTranslator v10.16.1.2 ABI.
// Only this header may describe LunaHost callback layouts or exported functions.
#pragma pack(push, 8)
struct LunaThreadParam {
  uint32_t processId;
  uint64_t addr;
  uint64_t ctx;
  uint64_t ctx2;
};
#pragma pack(pop)
static_assert(sizeof(LunaThreadParam) == 32,
              "LunaThreadParam must match LunaHost ABI");

using LunaProcessEvent = void (*)(DWORD);
using LunaThreadEventMaybeEmbed = void (*)(const wchar_t*, const char*,
                                            LunaThreadParam, bool);
using LunaThreadEvent = void (*)(const wchar_t*, const char*, LunaThreadParam);
using LunaOutputCallback = void (*)(const wchar_t*, const char*,
                                    LunaThreadParam, const wchar_t*);
using LunaHostInfoHandler = void (*)(int, const wchar_t*);
using LunaHookInsertHandler = void (*)(DWORD, uint64_t, const wchar_t*);
using LunaEmbedCallback = void (*)(const wchar_t*, LunaThreadParam);
using LunaI18nQueryCallback = wchar_t* (*)(const wchar_t*);
using LunaEmuGameInfoCallback = void (*)(const wchar_t*, const wchar_t*,
                                         const wchar_t*);
using PFN_Luna_Start = void (*)(
    LunaProcessEvent, LunaProcessEvent, LunaThreadEventMaybeEmbed,
    LunaThreadEvent, LunaOutputCallback, LunaHostInfoHandler,
    LunaHookInsertHandler, LunaEmbedCallback, LunaI18nQueryCallback,
    LunaEmuGameInfoCallback);
using PFN_Luna_ConnectProcess = void (*)(DWORD);
using PFN_Luna_CheckIfNeedInject = bool (*)(DWORD);
using PFN_Luna_DetachProcess = void (*)(DWORD);
using PFN_Luna_Settings = void (*)(int, bool, int, int, int, bool);
using PFN_Luna_InsertPCHooks = void (*)(DWORD, int);
using PFN_Luna_InsertHookCode = bool (*)(DWORD, const wchar_t*);

inline constexpr std::array<const char*, 4> kLunaRequiredExports = {
    "Luna_Start", "Luna_ConnectProcess", "Luna_CheckIfNeedInject",
    "Luna_DetachProcess"};
inline constexpr std::array<const char*, 13> kLunaOptionalExports = {
    "Luna_Settings",          "Luna_InsertPCHooks",
    "Luna_SettingsEx",        "Luna_ResetLang",
    "Luna_AllocString",       "Luna_InsertHookCode",
    "Luna_QueryThreadHistory", "Luna_RemoveHook",
    "Luna_FindHooks",         "Luna_SyncThread",
    "Luna_CheckIsUsingEmbed", "Luna_UseEmbed",
    "Luna_EmbedCallback"};

struct LunaBridgeExports {
  PFN_Luna_Start start = nullptr;
  PFN_Luna_ConnectProcess connect = nullptr;
  PFN_Luna_CheckIfNeedInject need_inject = nullptr;
  PFN_Luna_DetachProcess detach = nullptr;
  PFN_Luna_Settings settings = nullptr;
  PFN_Luna_InsertPCHooks insert_pc = nullptr;
  PFN_Luna_InsertHookCode insert_hook = nullptr;

  bool Resolve(HMODULE host) {
    start = reinterpret_cast<PFN_Luna_Start>(GetProcAddress(host, "Luna_Start"));
    connect = reinterpret_cast<PFN_Luna_ConnectProcess>(
        GetProcAddress(host, "Luna_ConnectProcess"));
    need_inject = reinterpret_cast<PFN_Luna_CheckIfNeedInject>(
        GetProcAddress(host, "Luna_CheckIfNeedInject"));
    detach = reinterpret_cast<PFN_Luna_DetachProcess>(
        GetProcAddress(host, "Luna_DetachProcess"));
    settings = reinterpret_cast<PFN_Luna_Settings>(
        GetProcAddress(host, "Luna_Settings"));
    insert_pc = reinterpret_cast<PFN_Luna_InsertPCHooks>(
        GetProcAddress(host, "Luna_InsertPCHooks"));
    insert_hook = reinterpret_cast<PFN_Luna_InsertHookCode>(
        GetProcAddress(host, "Luna_InsertHookCode"));
    return start != nullptr && connect != nullptr && need_inject != nullptr &&
           detach != nullptr;
  }
};

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_LUNA_BRIDGE_H_
