#pragma once
#include "siglus_autoprofile.h"

namespace fushi_voice_hook::siglus_eightarg_input_viewport {
namespace ex = exact_lookup;
namespace family = siglus_family;
// Structural sites only. Named USER32 imports must be independently verified
// by the caller. This neither admits glyphs nor grants an input lease.
struct Imports {
  uintptr_t key_state = 0, cursor_position = 0, active_window = 0,
            screen_to_client = 0;
};
struct Sites {
  uintptr_t root_slot = 0, owner_slot = 0, config_slot = 0, window_slot = 0;
  uintptr_t input_slot = 0, current_input_slot = 0, prior_input_slot = 0;
  uintptr_t viewport_slot = 0, gate2_slot = 0, gate3_slot = 0, manager_slot = 0;
  uintptr_t sampler = 0, key_state_return = 0, main_input = 0,
            main_sampler_return = 0;
  uintptr_t message = 0, window_handler = 0, window_message_return = 0,
            window_vtable = 0;
  // Scene alias only; the selected normal group still needs joint glyph proof.
  uintptr_t scene_slot = 0;
};
inline constexpr uint32_t kRootConfig = 0x54, kRootOwner = 0xa476b0;
inline constexpr uint32_t kConfigOwner = 0xa4765c, kConfigWidth = 0x64,
                          kConfigHeight = 0x68;
inline constexpr uint32_t kOwnerWindow = 0x178, kOwnerInput = 0x35ad4;
inline constexpr uint32_t kOwnerCurrentInput = 0x3939c,
                          kOwnerPriorInput = 0x3b000;
inline constexpr uint32_t kOwnerViewport = 0x3cca0, kOwnerGate2 = 0x3d124;
inline constexpr uint32_t kOwnerGate3 = 0x4296c, kOwnerManager = 0x3d174;
inline constexpr uint32_t kOwnerScene = 0x42898;
inline constexpr uint32_t kOwnerDesignWidth = 0x3cca8,
                          kOwnerDesignHeight = 0x3ccac;
inline constexpr uint32_t kOwnerViewportX = 0x3ccb0, kOwnerViewportY = 0x3ccb4;
inline constexpr uint32_t kOwnerViewportWidth = 0x3ccc0,
                          kOwnerViewportHeight = 0x3ccc4;
// Necessary rejection gates; Save/Log/hidden-scene semantics are not claimed.
inline constexpr uint32_t kViewportGateByte = 0xb4, kGate2Byte = 2,
                          kGate3Byte = 0x138;

// Only absolute addresses and external CALL operands relocate. All branches,
// stack cleanup, frame accesses, buffer strides and coordinate arithmetic stay
// exact. Each relocated edge is role checked and critical relations are joined.
inline constexpr family::Signature kRoot{
    "8D 41 18 89 0D ?? ?? ?? ?? A3 ?? ?? ?? ?? 8D B9 B0 76 A4 00 8D 41 54 89 "
    "3D ?? ?? ?? ?? A3 ?? ?? ?? "
    "?? 8D 81 14 76 A4 00 A3 ?? ?? ?? ??"};
inline constexpr family::Signature kRootCtor{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 51 56 A1 ?? ?? ?? ?? "
    "33 C5 50 8D 45 F4 64 A3 00 "
    "00 00 00 8B F1 89 75 F0 E8 ?? ?? ?? ?? C7 45 FC 00 00 00 00 33 C0 C7 46 "
    "18 00 00 00 00 C7 46 1C 00 "
    "00 00 00 C7 46 20 00 00 00 00 C7 46 38 07 00 00 00 C7 46 34 00 00 00 00 "
    "66 89 46 24 C7 46 50 07 00 "
    "00 00 89 46 4C 66 89 46 3C 8D 4E 54 C6 45 FC 01 E8 ?? ?? ?? ?? 8D 8E 14 "
    "76 A4 00 E8 ?? ?? ?? ?? 8D "
    "8E B0 76 A4 00 C6 45 FC 03 E8 ?? ?? ?? ?? 8B C6 8B 4D F4 64 89 0D 00 00 "
    "00 00 59 5E 8B E5 5D C3"};
inline constexpr family::Signature kOwnerCtor{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 0C 53 56 57 A1 "
    "?? ?? ?? ?? 33 C5 50 8D 45 "
    "F4 64 A3 00 00 00 00 8B F9 89 7D F0 C7 07 00 00 00 00 C7 47 04 00 00 00 "
    "00 C7 47 08 00 00 00 00 C7 "
    "47 0C 00 00 00 00 8D 4F 10 C7 45 FC 00 00 00 00 E8 ?? ?? ?? ?? 8D B7 A4 "
    "00 00 00 C7 06 00 00 00 00 "
    "89 75 EC C7 46 04 00 00 00 00 C7 46 08 00 00 00 00 C6 45 FC 02 C7 46 0C "
    "00 00 00 00 C7 46 10 00 00 "
    "00 00 E8 ?? ?? ?? ?? 89 46 0C C7 87 C8 00 00 00 00 00 00 00 C7 87 CC 00 "
    "00 00 00 00 00 00 C7 87 D0 "
    "00 00 00 00 00 00 00 C6 45 FC 04 C7 87 D4 00 00 00 00 00 00 00 C7 87 D8 "
    "00 00 00 00 00 00 00 E8 ?? "
    "?? ?? ?? 89 87 D4 00 00 00 8D 8F DC 00 00 00 E8 ?? ?? ?? ?? C7 87 6C 01 "
    "00 00 00 00 00 00 C7 87 70 "
    "01 00 00 00 00 00 00 C7 87 74 01 00 00 00 00 00 00 8D 8F 78 01 00 00 E8 "
    "?? ?? ?? ??"};
inline constexpr family::Signature kAliases{
    "8B 4D F0 8D 81 78 01 00 00 C6 81 44 8D 04 00 00 A3 ?? ?? ?? ?? 8D 81 00 "
    "1E 00 00 A3 ?? ?? ?? ?? 8D "
    "81 90 1E 00 00 A3 ?? ?? ?? ?? 8D 81 D4 5A 03 00 A3 ?? ?? ?? ?? 8D 81 9C "
    "93 03 00 A3 ?? ?? ?? ?? 8D "
    "81 00 B0 03 00 A3 ?? ?? ?? ?? 8D 81 70 CC 03 00 A3 ?? ?? ?? ?? 8D 81 88 "
    "CC 03 00 A3 ?? ?? ?? ?? 8D "
    "81 A0 CC 03 00 A3 ?? ?? ?? ?? 8D 81 88 CE 03 00 A3 ?? ?? ?? ?? 8D 81 30 "
    "CF 03 00 A3 ?? ?? ?? ?? 8D "
    "81 24 D1 03 00 A3 ?? ?? ?? ?? 8D 81 74 D1 03 00 A3 ?? ?? ?? ?? 8D 41 10 "
    "A3 ?? ?? ?? ?? 8D 81 B8 00 "
    "00 00 A3 ?? ?? ?? ?? 8D 81 D4 00 00 00 A3 ?? ?? ?? ?? 8D 81 D4 D5 03 00 "
    "A3 ?? ?? ?? ?? 8D 81 40 D6 "
    "03 00 A3 ?? ?? ?? ?? 8D 81 68 D6 03 00 A3 ?? ?? ?? ?? 8D 81 B4 D6 03 00 "
    "A3 ?? ?? ?? ?? 8D 81 BC D6 "
    "03 00 A3 ?? ?? ?? ?? 8D 81 C8 D6 03 00 A3 ?? ?? ?? ?? 8D 81 4C D7 03 00 "
    "A3 ?? ?? ?? ?? 8D 81 84 D7 "
    "03 00 A3 ?? ?? ?? ?? 8D 81 74 D8 03 00 A3 ?? ?? ?? ?? 8D 81 2C D9 03 00 "
    "A3 ?? ?? ?? ?? 8D 81 34 D9 "
    "03 00 A3 ?? ?? ?? ?? 8D 81 40 D9 03 00 A3 ?? ?? ?? ?? 8D 81 54 D9 03 00 "
    "A3 ?? ?? ?? ?? 8D 81 60 D9 "
    "03 00 A3 ?? ?? ?? ?? 8D 81 6C D9 03 00 A3 ?? ?? ?? ?? 8D 81 80 D9 03 00 "
    "A3 ?? ?? ?? ?? 8D 81 D4 D9 "
    "03 00 A3 ?? ?? ?? ?? 8D 81 40 DA 03 00 A3 ?? ?? ?? ?? 8D 81 78 DA 03 00 "
    "A3 ?? ?? ?? ?? 8D 81 84 DA "
    "03 00 A3 ?? ?? ?? ?? 8D 81 90 DA 03 00 A3 ?? ?? ?? ?? 8D 81 58 13 04 00 "
    "A3 ?? ?? ?? ?? 8D 81 A0 13 "
    "04 00 A3 ?? ?? ?? ?? 8D 81 EC 13 04 00 A3 ?? ?? ?? ?? 8D 81 B0 13 04 00 "
    "A3 ?? ?? ?? ?? 8D 81 64 CC "
    "03 00 A3 ?? ?? ?? ?? 8D 81 08 14 04 00 A3 ?? ?? ?? ?? 8D 81 8C 1F 04 00 "
    "A3 ?? ?? ?? ?? 8D 81 44 20 "
    "04 00 A3 ?? ?? ?? ?? 8D 81 FC 20 04 00 A3 ?? ?? ?? ?? 8D 81 B4 21 04 00 "
    "A3 ?? ?? ?? ?? 8D 81 6C 22 "
    "04 00 A3 ?? ?? ?? ?? 8D 81 38 25 04 00 A3 ?? ?? ?? ?? 8D 81 70 26 04 00 "
    "A3 ?? ?? ?? ?? 8D 81 28 27 "
    "04 00 A3 ?? ?? ?? ?? 8D 81 E0 27 04 00 A3 ?? ?? ?? ?? 8D 81 98 28 04 00 "
    "A3 ?? ?? ?? ?? 8D 81 6C 29 "
    "04 00 A3 ?? ?? ?? ?? 8D 81 54 7D 04 00 A3 ?? ?? ?? ?? 8D 81 74 7F 04 00 "
    "A3 ?? ?? ?? ?? 8D 81 2C 84 "
    "04 00 A3 ?? ?? ?? ??"};
inline constexpr family::Signature kWindowCtor{
    "56 8B F1 E8 ?? ?? ?? ?? C7 86 8C 00 00 00 07 00 00 00 8D 8E 90 00 00 00 "
    "C7 86 88 00 00 00 00 00 00 "
    "00 33 C0 66 89 46 78 C7 06 ?? ?? ?? ??"};
inline constexpr family::Signature kSampler{
    "55 8B EC 81 EC 1C 01 00 00 A1 ?? ?? ?? ?? 33 C5 89 45 FC 53 56 8B 35 ?? "
    "?? ?? ?? 57 C7 85 E4 FE FF "
    "FF 00 00 00 00 C7 85 E8 FE FF FF 00 00 00 00 8B 86 64 1C 00 00 89 85 F0 "
    "FE FF FF 8B 86 68 1C 00 00 "
    "89 85 EC FE FF FF 8D 85 E4 FE FF FF 50 FF 15 ?? ?? ?? ?? 8B 85 E4 FE FF "
    "FF 89 86 64 1C 00 00 8B 85 "
    "E8 FE FF FF 68 FF 00 00 00 89 86 68 1C 00 00 8D 85 F9 FE FF FF 6A 00 50 "
    "C6 85 F8 FE FF FF 00 E8 ?? "
    "?? ?? ?? 83 C4 0C FF 15 ?? ?? ?? ?? 85 C0 74 24 8B 1D ?? ?? ?? ?? 33 FF "
    "8D 64 24 00 57 FF D3 C1 E8 "
    "08 24 80 88 84 3D F8 FE FF FF 47 81 FF 00 01 00 00 7C E8 8B 86 68 1C 00 "
    "00 2B 85 EC FE FF FF 8B 8E "
    "80 1C 00 00 2B 8D F0 FE FF FF 03 8E 64 1C 00 00 8B BE 84 1C 00 00 03 F8 "
    "89 8E 80 1C 00 00 8B C1 89 "
    "BE 84 1C 00 00 99 8B D8 8B C7 33 DA 2B DA 99 33 C2 2B C2 3B D8 7E 0A 83 "
    "F9 E0 7C 26 83 F9 20 EB 1F "
    "7D 32 83 FF E0 7D 15 83 BE 7C 1C 00 00 01 75 24 C7 86 7C 1C 00 00 02 00 "
    "00 00 EB 18 83 FF 20 7E 13 "
    "83 BE 7C 1C 00 00 01 7C 0A C7 86 7C 1C 00 00 01 00 00 00 8B 86 68 1C 00 "
    "00 2B 85 EC FE FF FF 8B 8E "
    "9C 1C 00 00 2B 8D F0 FE FF FF 03 8E 64 1C 00 00 8B BE A0 1C 00 00 03 F8 "
    "89 8E 9C 1C 00 00 8B C1 89 "
    "BE A0 1C 00 00 99 8B D8 8B C7 33 DA 2B DA 99 33 C2 2B C2 3B D8 7E 0A 83 "
    "F9 E0 7C 26 83 F9 20 EB 1F "
    "7D 32 83 FF E0 7D 15 83 BE 98 1C 00 00 01 75 24 C7 86 98 1C 00 00 02 00 "
    "00 00 EB 18 83 FF 20 7E 13 "
    "83 BE 98 1C 00 00 01 7C 0A C7 86 98 1C 00 00 01 00 00 00 83 BE 6C 1C 00 "
    "00 01 8A 85 F9 FE FF FF 88 "
    "85 F7 FE FF FF 75 47 84 C0 78 43 83 BE 74 1C 00 00 00 C7 86 6C 1C 00 00 "
    "00 00 00 00 75 0A C7 86 74 "
    "1C 00 00 01 00 00 00 83 BE 78 1C 00 00 01 75 0A C7 86 78 1C 00 00 02 00 "
    "00 00 83 BE 7C 1C 00 00 02 "
    "75 0A C7 86 7C 1C 00 00 03 00 00 00 83 BE 88 1C 00 00 01 8A BD FA FE FF "
    "FF 75 47 84 FF 78 43 83 BE "
    "90 1C 00 00 00 C7 86 88 1C 00 00 00 00 00 00 75 0A C7 86 90 1C 00 00 01 "
    "00 00 00 83 BE 94 1C 00 00 "
    "01 75 0A C7 86 94 1C 00 00 02 00 00 00 83 BE 98 1C 00 00 02 75 0A C7 86 "
    "98 1C 00 00 03 00 00 00 83 "
    "BE A4 1C 00 00 01 8A 9D FC FE FF FF 75 47 84 DB 78 43 83 BE AC 1C 00 00 "
    "00 C7 86 A4 1C 00 00 00 00 "
    "00 00 75 0A C7 86 AC 1C 00 00 01 00 00 00 83 BE B0 1C 00 00 01 75 0A C7 "
    "86 B0 1C 00 00 02 00 00 00 "
    "83 BE B4 1C 00 00 02 75 0A C7 86 B4 1C 00 00 03 00 00 00 33 C9 8D 86 D4 "
    "1C 00 00 83 78 F4 01 75 36 "
    "F6 84 0D F8 FE FF FF 80 75 2C C7 40 F4 00 00 00 00 83 78 FC 00 75 07 C7 "
    "40 FC 01 00 00 00 83 38 01 "
    "75 06 C7 00 02 00 00 00 83 78 04 02 75 07 C7 40 04 03 00 00 00 41 83 C0 "
    "1C 81 F9 00 01 00 00 7C B8 "
    "8B CE E8 ?? ?? ?? ?? 8A 85 F7 FE FF FF 32 C9 24 80 3A C8 1B C0 80 E7 80 "
    "F7 D8 89 46 08 32 C0 3A C7 "
    "1B C0 80 E3 80 F7 D8 89 46 24 32 C0 3A C3 1B C0 33 C9 F7 D8 89 46 40 83 "
    "C6 64 8A 84 0D F8 FE FF FF "
    "8D 76 1C 24 80 32 D2 3A D0 1B C0 41 F7 D8 89 46 E4 81 F9 00 01 00 00 7C "
    "E0 8B 4D FC 5F 5E 33 CD 5B "
    "E8 ?? ?? ?? ?? 8B E5 5D C3"};
inline constexpr family::Signature kMain{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 44 02 00 00 A1 "
    "?? ?? ?? ?? 33 C5 89 45 F0 "
    "53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B F1 89 B5 C4 FD FF FF E8 ?? ?? "
    "?? ?? 84 C0 75 07 32 C0 E9 "
    "75 10 00 00 8B 86 B0 CC 03 00 89 86 B8 CC 03 00 8B 86 B4 CC 03 00 89 86 "
    "BC CC 03 00 8B 86 C0 CC 03 "
    "00 89 86 C8 CC 03 00 8B 86 C4 CC 03 00 89 86 CC CC 03 00 C7 86 50 CD 03 "
    "00 00 00 00 00 66 C7 86 00 "
    "CE 03 00 01 01 C7 86 45 CE 03 00 00 00 00 00 FF 15 ?? ?? ?? ?? 8B 0D ?? "
    "?? ?? ?? 3B 41 04 0F 94 C0 "
    "88 86 50 CD 03 00 FF 15 ?? ?? ?? ?? 8B F8 85 FF 0F 84 B5 00 00 00 8B 0D "
    "?? ?? ?? ?? 3B 79 04 75 0C "
    "C6 86 51 CD 03 00 01 E9 9E 00 00 00 33 C0 68 FE 01 00 00 50 66 89 85 F0 "
    "FD FF FF 8D 85 F2 FD FF FF "
    "50 E8 ?? ?? ?? ?? 83 C4 0C 8D 85 F0 FD FF FF 68 00 01 00 00 50 57 FF 15 "
    "?? ?? ?? ?? 8D 85 F0 FD FF "
    "FF 50 8D 8D D8 FD FF FF E8 ?? ?? ?? ?? BA ?? ?? ?? ?? C7 45 FC 00 00 00 "
    "00 8B C8 E8 ?? ?? ?? ?? C7 "
    "45 FC FF FF FF FF 8A D8 83 BD EC FD FF FF 08 72 0E FF B5 D8 FD FF FF E8 "
    "?? ?? ?? ?? 83 C4 04 33 C0 "
    "C7 85 EC FD FF FF 07 00 00 00 C7 85 E8 FD FF FF 00 00 00 00 66 89 85 D8 "
    "FD FF FF 84 DB 74 07 C6 86 "
    "52 CD 03 00 01 83 BE 08 CD 03 00 00 74 19 A1 ?? ?? ?? ?? C6 80 B7 00 00 "
    "00 01 FF 8E 08 CD 03 00 75 "
    "05 E8 ?? ?? ?? ?? 80 BE 49 CE 03 00 00 74 15 80 BE 4A CE 03 00 00 75 0C "
    "C6 86 00 CE 03 00 00 E9 09 "
    "0F 00 00 83 BE D0 83 04 00 01 75 1F A1 ?? ?? ?? ?? 85 C0 74 16 8B 08 8D "
    "95 C0 FD FF FF 52 50 FF 51 "
    "2C 83 BD C0 FD FF FF 09 74 CC 68 64 1C 00 00 FF 35 ?? ?? ?? ?? 8D 9E 00 "
    "B0 03 00 53 E8 ?? ?? ?? ?? "
    "8B 86 9C 93 03 00 8D BE 9C 93 03 00 83 C4 0C 89 03 8B 47 04 89 43 04 E8 "
    "?? ?? ?? ?? A1 ?? ?? ?? ?? "
    "83 78 14 02 75 3A 83 BE 14 B0 03 00 00 75 31 83 78 08 00 75 21 83 78 10 "
    "01 75 1B 83 78 14 02 75 15 "
    "C7 40 08 01 00 00 00 C7 40 10 00 00 00 00 C7 40 14 01 00 00 00 C7 80 6C "
    "1C 00 00 01 00 00 00 8B CE "
    "E8 ?? ?? ?? ?? 68 64 1C 00 00 FF 35 ?? ?? ?? ?? 57 E8 ?? ?? ?? ?? 83 C4 "
    "0C 8B CE E8 ?? ?? ?? ?? 8B "
    "0D ?? ?? ?? ?? 8B 01 89 85 B0 FD FF FF 8B 41 04 89 85 B4 FD FF FF 8D 85 "
    "B0 FD FF FF 50 A1 ?? ?? ?? "
    "?? FF 70 04 FF 15 ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 8B 85 B0 FD FF FF 8B 0D "
    "?? ?? ?? ?? 89 07 8B 85 B4 "
    "FD FF FF 89 47 04 8B 07 2B 86 B0 CC 03 00 0F AF 86 A8 CC 03 00 99 F7 BE "
    "C0 CC 03 00 89 07 8B 47 04 "
    "2B 86 B4 CC 03 00 0F AF 86 AC CC 03 00 99 F7 BE C4 CC 03 00 89 47 04 80 "
    "BE 58 CD 03 00 00 74 3F C6 "
    "86 58 CD 03 00 00 C7 41 0C 00 00 00 00 C7 41 10 00 00 00 00 C7 41 14 00 "
    "00 00 00 C7 41 18 00 00 00 "
    "00 C7 41 28 00 00 00 00 C7 41 2C 00 00 00 00 C7 41 30 00 00 00 00 C7 41 "
    "34 00 00 00 00 8B 07 3B 03 "
    "75 08 8B 47 04 3B 43 04 74 07 C6 86 94 CD 03 00 00 A1 ?? ?? ?? ?? 8B 15 "
    "?? ?? ?? ?? 80 B8 B4 00 00 "
    "00 00 74 04 32 C0 EB 19 80 BA 38 01 00 00 00 74 04 32 C0 EB 0C A1 ?? ?? "
    "?? ?? 80 78 02 00 0F 94 C0 "
    "83 79 0C 01 75 1D 84 C0 0F 84 EA 00 00 00"};
inline constexpr family::Signature kMainEnd{
    "B0 01 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B 4D F0 33 CD E8 ?? ?? "
    "?? ?? 8B E5 5D C3"};
inline constexpr family::Signature kMessage{
    "55 8B EC 51 8B 45 08 8B 0D ?? ?? ?? ?? 3D 01 02 00 00 0F 87 A2 00 00 00 "
    "74 43 05 00 FF FF FF 83 F8 "
    "05 0F 87 16 01 00 00 FF 24 85 ?? ?? ?? ?? FF 75 10 81 C1 C8 1C 00 00 FF "
    "75 0C E8 ?? ?? ?? ?? 8B E5 "
    "5D C2 0C 00 FF 75 10 81 C1 C8 1C 00 00 FF 75 0C E8 ?? ?? ?? ?? 8B E5 5D "
    "C2 0C 00 83 B9 70 1C 00 00 "
    "00 C7 81 6C 1C 00 00 01 00 00 00 75 0A C7 81 70 1C 00 00 01 00 00 00 83 "
    "B9 78 1C 00 00 00 75 0A C7 "
    "81 78 1C 00 00 01 00 00 00 83 B9 7C 1C 00 00 00 75 0A C7 81 7C 1C 00 00 "
    "01 00 00 00 C7 81 80 1C 00 "
    "00 00 00 00 00 C7 81 84 1C 00 00 00 00 00 00 8B E5 5D C2 0C 00 05 FE FD "
    "FF FF 83 F8 08 77 7A FF 24 "
    "85 ?? ?? ?? ?? 83 EC 08 81 C1 6C 1C 00 00 E8 ?? ?? ?? ?? 8B E5 5D C2 0C "
    "00 83 EC 08 81 C1 88 1C 00 "
    "00 E8 ?? ?? ?? ?? 8B E5 5D C2 0C 00 83 EC 08 81 C1 88 1C 00 00 E8 ?? ?? "
    "?? ?? 8B E5 5D C2 0C 00 83 "
    "EC 08 81 C1 A4 1C 00 00 E8 ?? ?? ?? ?? 8B E5 5D C2 0C 00 83 EC 08 81 C1 "
    "A4 1C 00 00 E8 ?? ?? ?? ?? "
    "8B E5 5D C2 0C 00 51 FF 75 0C 81 C1 C0 1C 00 00 E8 ?? ?? ?? ?? 8B E5 5D "
    "C2 0C 00"};
inline constexpr family::Signature kHandler{
    "55 8B EC 83 E4 F8 51 53 56 8B 75 08 8B D9 57 FF 75 10 8B 7D 0C 57 56 E8 "
    "?? ?? ?? ?? 81 FE 04 01 00 "
    "00 77 7E 74 68 8D 46 FF 83 F8 1F 0F 87 11 01 00 00 0F B6 80 ?? ?? ?? ?? "
    "FF 24 85 ?? ?? ?? ?? 8B CB "
    "E8 ?? ?? ?? ?? 84 C0 0F 85 F4 00 00 00 33 C0 5F 5E 5B 8B E5 5D C2 0C 00 "
    "8B CB E8 ?? ?? ?? ?? 84 C0 "
    "0F 85 DA 00 00 00 33 C0 5F 5E 5B 8B E5 5D C2 0C 00 8B CB E8 ?? ?? ?? ?? "
    "84 C0 0F 85 C0 00 00 00 33 "
    "C0 5F 5E 5B 8B E5 5D C2 0C 00 83 FF 79 0F 85 AC 00 00 00 33 C0 5F 5E 5B "
    "8B E5 5D C2 0C 00 81 FE 16 "
    "01 00 00 77 7C 74 65 8B C6 2D 11 01 00 00 74 44 48 0F 85 87 00 00 00 A1 "
    "?? ?? ?? ?? 80 B8 B7 00 00 "
    "00 00 75 07 C6 80 B7 00 00 00 01 81 FF 40 F1 00 00 75 6A E8 ?? ?? ?? ?? "
    "84 C0 75 09 E8 ?? ?? ?? ?? "
    "84 C0 74 58 B8 01 00 00 00 5F 5E 5B 8B E5 5D C2 0C 00 51 57 8B CB E8 ?? "
    "?? ?? ?? 84 C0 75 3D 33 C0 "
    "5F 5E 5B 8B E5 5D C2 0C 00 3B BB F0 1A 00 00 8D 8B F0 1A 00 00 75 24 E8 "
    "?? ?? ?? ?? EB 1D 81 FE 11 "
    "02 00 00 75 15 A1 ?? ?? ?? ?? 80 B8 B7 00 00 00 00 75 07 C6 80 B7 00 00 "
    "00 01 8B C6 83 E8 02 75 36 "
    "83 BB 8C 00 00 00 08 8D 7B 78 72 04 8B 07 EB 02 8B C7 FF 35 ?? ?? ?? ?? "
    "50 FF 15 ?? ?? ?? ?? 83 7F "
    "14 08 C7 47 10 00 00 00 00 72 02 8B 3F 33 C0 66 89 07 8B 7D 0C FF 75 10 "
    "8B CB 57 56 E8 ?? ?? ?? ?? "
    "5F 5E 5B 8B E5 5D C2 0C 00 8D 49 00"};
inline constexpr family::Signature kDesign{
    "8B 0D ?? ?? ?? ?? 8B 15 ?? ?? ?? ?? 89 87 68 D6 03 00 C7 87 6C D6 03 00 "
    "00 00 00 00 C7 87 70 D6 03 "
    "00 00 00 00 00 C7 87 74 D6 03 00 00 00 00 00 66 C7 87 A0 CC 03 00 00 00 "
    "8A 82 95 00 00 00 88 87 A2 "
    "CC 03 00 C6 87 A3 CC 03 00 00 C7 87 A4 CC 03 00 FF FF FF FF 8B 41 64 89 "
    "87 A8 CC 03 00 8B 41 68 89 "
    "87 AC CC 03 00 C7 87 B0 CC 03 00 00 00 00 00 C7 87 B4 CC 03 00 00 00 00 "
    "00 C7 87 B8 CC 03 00 00 00 "
    "00 00 C7 87 BC CC 03 00 00 00 00 00 8B 41 64 89 87 C0 CC 03 00 8B 41 68 "
    "89 87 C4 CC 03 00 8B 41 64 "
    "89 87 C8 CC 03 00 8B 41 68 89 87 CC CC 03 00 8B 41 64 89 87 D0 CC 03 00 "
    "8B 41 68 89 87 D4 CC 03 00"};
inline constexpr family::Signature kScale{
    "66 0F 6E 93 C4 CC 03 00 8D 8B 30 83 04 00 66 0F 6E 83 AC CC 03 00 66 0F "
    "6E 8B C0 CC 03 00 0F 5B C0 "
    "0F 5B D2 0F 5B C9 F3 0F 5E D0 66 0F 6E 83 A8 CC 03 00 0F 5B C0 F3 0F 11 "
    "93 08 84 04 00 F3 0F 5E C8 "
    "F3 0F 11 8B 04 84 04 00 8B 83 B0 CC 03 00 89 83 0C 84 04 00 8B 83 B4 CC "
    "03 00 89 83 10 84 04 00"};
inline constexpr family::Signature kGate{
    "55 8B EC A1 ?? ?? ?? ?? 56 8B F2 8B D1 80 B8 B4 00 00 00 00 74 04 32 C9 "
    "EB 1E A1 ?? ?? ?? ?? 80 B8 "
    "38 01 00 00 00 74 04 32 C9 EB 0C A1 ?? ?? ?? ?? 80 78 02 00 0F 94 C1"};

enum class Role { Call, Code, Data, ReadOnly };
struct Relocation {
  size_t offset;
  Role role;
};
inline bool Span(const ex::LoadedPeImage& image, uintptr_t rva, size_t size,
                 uint32_t required, uint32_t excluded = 0) {
  return image.base && rva < image.size && size <= image.size - rva &&
         ex::SectionHasRole(ex::FindSectionForRva(image, rva, size), required,
                            excluded) &&
         ex::IsReadableSpan(image.base + rva, size);
}
inline uintptr_t Base(const ex::LoadedPeImage& image) {
  return image.absolute_base ? image.absolute_base
                             : reinterpret_cast<uintptr_t>(image.base);
}
inline uint32_t U32(const ex::LoadedPeImage& image, uintptr_t rva) {
  uint32_t result = 0;
  std::memcpy(&result, image.base + rva, 4);
  return result;
}
inline uintptr_t Address(const ex::LoadedPeImage& image, uintptr_t operand) {
  if (!Span(image, operand, 4, IMAGE_SCN_MEM_READ)) return 0;
  const uint32_t absolute = U32(image, operand);
  return absolute >= Base(image) && absolute - Base(image) < image.size
             ? absolute - Base(image)
             : 0;
}
inline uintptr_t Call(const ex::LoadedPeImage& image, uintptr_t operand) {
  if (!operand ||
      !Span(image, operand - 1, 5,
            IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE) ||
      image.base[operand - 1] != 0xe8)
    return 0;
  int32_t delta = 0;
  std::memcpy(&delta, image.base + operand, 4);
  const int64_t result = static_cast<int64_t>(operand) + 4 + delta;
  return result > 0 && static_cast<uint64_t>(result) < image.size &&
                 Span(image, static_cast<uintptr_t>(result), 1,
                      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE)
             ? static_cast<uintptr_t>(result)
             : 0;
}
inline bool RoleAt(const ex::LoadedPeImage& image, uintptr_t operand,
                   Role role) {
  if (role == Role::Call) return Call(image, operand) != 0;
  const auto target = Address(image, operand);
  if (!target) return false;
  if (role == Role::Code)
    return Span(image, target, 1, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE);
  if (role == Role::Data)
    return (target & 3u) == 0 &&
           Span(image, target, 4, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,
                IMAGE_SCN_MEM_EXECUTE);
  return Span(image, target, 4, IMAGE_SCN_MEM_READ,
              IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE);
}
template <size_t N>
inline bool Relocations(const ex::LoadedPeImage& image, uintptr_t start,
                        const Relocation (&items)[N]) {
  for (const auto& item : items)
    if (!RoleAt(image, start + item.offset, item.role)) return false;
  return true;
}
inline constexpr Relocation kRootRelocations[] = {{5, Role::Data},
                                                  {10, Role::Data},
                                                  {25, Role::Data},
                                                  {30, Role::Data},
                                                  {41, Role::Data}};
inline constexpr Relocation kRootCtorRelocations[] = {
    {6, Role::Code},   {20, Role::Data},  {42, Role::Call},
    {116, Role::Call}, {127, Role::Call}, {142, Role::Call}};
inline constexpr Relocation kOwnerCtorRelocations[] = {
    {6, Role::Code},   {24, Role::Data},  {83, Role::Call}, {135, Role::Call},
    {197, Role::Call}, {214, Role::Call}, {255, Role::Call}};
inline constexpr Relocation kAliasesRelocations[] = {
    {17, Role::Data},  {28, Role::Data},  {39, Role::Data},  {50, Role::Data},
    {61, Role::Data},  {72, Role::Data},  {83, Role::Data},  {94, Role::Data},
    {105, Role::Data}, {116, Role::Data}, {127, Role::Data}, {138, Role::Data},
    {149, Role::Data}, {157, Role::Data}, {168, Role::Data}, {179, Role::Data},
    {190, Role::Data}, {201, Role::Data}, {212, Role::Data}, {223, Role::Data},
    {234, Role::Data}, {245, Role::Data}, {256, Role::Data}, {267, Role::Data},
    {278, Role::Data}, {289, Role::Data}, {300, Role::Data}, {311, Role::Data},
    {322, Role::Data}, {333, Role::Data}, {344, Role::Data}, {355, Role::Data},
    {366, Role::Data}, {377, Role::Data}, {388, Role::Data}, {399, Role::Data},
    {410, Role::Data}, {421, Role::Data}, {432, Role::Data}, {443, Role::Data},
    {454, Role::Data}, {465, Role::Data}, {476, Role::Data}, {487, Role::Data},
    {498, Role::Data}, {509, Role::Data}, {520, Role::Data}, {531, Role::Data},
    {542, Role::Data}, {553, Role::Data}, {564, Role::Data}, {575, Role::Data},
    {586, Role::Data}, {597, Role::Data}, {608, Role::Data}, {619, Role::Data},
    {630, Role::Data}};
inline constexpr Relocation kWindowCtorRelocations[] = {{4, Role::Call},
                                                        {42, Role::ReadOnly}};
inline constexpr Relocation kSamplerRelocations[] = {
    {10, Role::Data},  {23, Role::Data},      {81, Role::ReadOnly},
    {131, Role::Call}, {140, Role::ReadOnly}, {150, Role::ReadOnly},
    {795, Role::Call}, {892, Role::Call}};
inline constexpr Relocation kMainRelocations[] = {
    {6, Role::Code},       {24, Role::Data},      {55, Role::Call},
    {149, Role::ReadOnly}, {155, Role::Data},     {173, Role::ReadOnly},
    {189, Role::Data},     {233, Role::Call},     {255, Role::ReadOnly},
    {273, Role::Call},     {278, Role::ReadOnly}, {292, Role::Call},
    {321, Role::Call},     {378, Role::Data},     {398, Role::Call},
    {442, Role::Data},     {479, Role::Data},     {491, Role::Call},
    {519, Role::Call},     {524, Role::Data},     {595, Role::Call},
    {606, Role::Data},     {612, Role::Call},     {622, Role::Call},
    {628, Role::Data},     {657, Role::Data},     {666, Role::ReadOnly},
    {672, Role::Data},     {684, Role::Data},     {843, Role::Data},
    {849, Role::Data},     {880, Role::Data}};
inline constexpr Relocation kMainEndRelocations[] = {{22, Role::Call}};
inline constexpr Relocation kMessageRelocations[] = {
    {9, Role::Data},   {43, Role::Code},  {60, Role::Call},  {83, Role::Call},
    {199, Role::Code}, {213, Role::Call}, {233, Role::Call}, {253, Role::Call},
    {273, Role::Call}, {293, Role::Call}, {314, Role::Call}};
inline constexpr Relocation kHandlerRelocations[] = {
    {24, Role::Call},  {53, Role::Code},      {60, Role::Code},
    {67, Role::Call},  {93, Role::Call},      {119, Role::Call},
    {189, Role::Data}, {218, Role::Call},     {227, Role::Call},
    {254, Role::Call}, {288, Role::Call},     {303, Role::Data},
    {350, Role::Data}, {357, Role::ReadOnly}, {392, Role::Call}};
inline constexpr Relocation kDesignRelocations[] = {{2, Role::Data},
                                                    {8, Role::Data}};
inline constexpr Relocation kGateRelocations[] = {
    {4, Role::Data}, {27, Role::Data}, {45, Role::Data}};

inline bool Resolve(const ex::LoadedPeImage& image, const Imports& imports,
                    Sites* output) {
  if (!output) return false;
  *output = {};
  if (!image.base || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 || image.section_count > image.sections.size() ||
      Base(image) > UINT32_MAX || image.size > UINT32_MAX - Base(image))
    return false;
  uintptr_t Root = 0;
  if (!family::Unique(image, kRoot.pattern(), &Root) ||
      !Relocations(image, Root, kRootRelocations))
    return false;
  uintptr_t RootCtor = 0;
  if (!family::Unique(image, kRootCtor.pattern(), &RootCtor) ||
      !Relocations(image, RootCtor, kRootCtorRelocations))
    return false;
  uintptr_t OwnerCtor = 0;
  if (!family::Unique(image, kOwnerCtor.pattern(), &OwnerCtor) ||
      !Relocations(image, OwnerCtor, kOwnerCtorRelocations))
    return false;
  uintptr_t Aliases = 0;
  if (!family::Unique(image, kAliases.pattern(), &Aliases) ||
      !Relocations(image, Aliases, kAliasesRelocations))
    return false;
  uintptr_t WindowCtor = 0;
  if (!family::Unique(image, kWindowCtor.pattern(), &WindowCtor) ||
      !Relocations(image, WindowCtor, kWindowCtorRelocations))
    return false;
  uintptr_t Sampler = 0;
  if (!family::Unique(image, kSampler.pattern(), &Sampler) ||
      !Relocations(image, Sampler, kSamplerRelocations))
    return false;
  uintptr_t Main = 0;
  if (!family::Unique(image, kMain.pattern(), &Main) ||
      !Relocations(image, Main, kMainRelocations))
    return false;
  // A standard epilogue is shared by unrelated functions. Its identity is
  // the exact location in the independently unique main-input frame.
  if (Main > UINTPTR_MAX - 0x10b9) return false;
  const uintptr_t MainEnd = Main + 0x10b9;
  if (!Span(image, MainEnd, kMainEnd.pattern().size,
            IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE) ||
      !ex::MatchesMaskedPattern(image.base + MainEnd, kMainEnd.pattern()) ||
      !Relocations(image, MainEnd, kMainEndRelocations))
    return false;
  uintptr_t Message = 0;
  if (!family::Unique(image, kMessage.pattern(), &Message) ||
      !Relocations(image, Message, kMessageRelocations))
    return false;
  uintptr_t Handler = 0;
  if (!family::Unique(image, kHandler.pattern(), &Handler) ||
      !Relocations(image, Handler, kHandlerRelocations))
    return false;
  uintptr_t Design = 0;
  if (!family::Unique(image, kDesign.pattern(), &Design) ||
      !Relocations(image, Design, kDesignRelocations))
    return false;
  uintptr_t Scale = 0;
  if (!family::Unique(image, kScale.pattern(), &Scale)) return false;
  uintptr_t Gate = 0;
  if (!family::Unique(image, kGate.pattern(), &Gate) ||
      !Relocations(image, Gate, kGateRelocations))
    return false;
  // These fragments must stay in the same compiler frame, not merely coexist.
  if (Aliases < OwnerCtor || Aliases - OwnerCtor != 0x895) return false;
  if (Call(image, RootCtor + 142) != OwnerCtor) return false;
  if (Call(image, OwnerCtor + 255) != WindowCtor) return false;
  if (Call(image, Main + 519) != Sampler) return false;
  if (Call(image, Handler + 24) != Message) return false;
  // Every constructor publication is a distinct role. An otherwise unused
  // alias must not overwrite a required window/input/manager publication.
  for (size_t i = 0; i < std::size(kAliasesRelocations); ++i) {
    const auto target = Address(image, Aliases + kAliasesRelocations[i].offset);
    for (size_t j = 0; j < i; ++j)
      if (target == Address(image, Aliases + kAliasesRelocations[j].offset))
        return false;
    for (const auto& root_item : kRootRelocations)
      if (target == Address(image, Root + root_item.offset)) return false;
  }
  for (size_t i = 0; i < std::size(kRootRelocations); ++i)
    for (size_t j = 0; j < i; ++j)
      if (Address(image, Root + kRootRelocations[i].offset) ==
          Address(image, Root + kRootRelocations[j].offset))
        return false;
  const auto root = Address(image, Root + 5);
  const auto owner = Address(image, Root + 25);
  const auto config = Address(image, Root + 30);
  const auto window = Address(image, Aliases + 17);
  const auto input = Address(image, Aliases + 50);
  const auto current = Address(image, Aliases + 61);
  const auto prior = Address(image, Aliases + 72);
  const auto viewport = Address(image, Aliases + 105);
  const auto gate2 = Address(image, Aliases + 138);
  const auto gate3 = Address(image, Aliases + 597);
  const auto manager = Address(image, Aliases + 149);
  const auto scene = Address(image, Aliases + 586);
  const uintptr_t slots[] = {root,  owner,    config, window, input,  current,
                             prior, viewport, gate2,  gate3,  manager, scene};
  for (size_t a = 0; a < std::size(slots); ++a) {
    if (!slots[a]) return false;
    for (size_t b = 0; b < a; ++b)
      if (slots[a] == slots[b]) return false;
  }
  if (Address(image, Sampler + 23) != input) return false;
  if (Address(image, Main + 155) != window) return false;
  if (Address(image, Main + 189) != window) return false;
  if (Address(image, Main + 378) != viewport) return false;
  if (Address(image, Main + 479) != input) return false;
  if (Address(image, Main + 524) != input) return false;
  if (Address(image, Main + 606) != input) return false;
  if (Address(image, Main + 628) != current) return false;
  if (Address(image, Main + 657) != window) return false;
  if (Address(image, Main + 672) != current) return false;
  if (Address(image, Main + 684) != input) return false;
  if (Address(image, Main + 843) != viewport) return false;
  if (Address(image, Main + 849) != gate3) return false;
  if (Address(image, Main + 880) != gate2) return false;
  if (Address(image, Message + 9) != input) return false;
  if (Address(image, Handler + 189) != viewport) return false;
  if (Address(image, Handler + 303) != viewport) return false;
  if (Address(image, Design + 2) != config) return false;
  if (Address(image, Gate + 4) != viewport) return false;
  if (Address(image, Gate + 27) != gate3) return false;
  if (Address(image, Gate + 45) != gate2) return false;
  if (!imports.key_state || Address(image, Sampler + 150) != imports.key_state)
    return false;
  if (!imports.cursor_position ||
      Address(image, Sampler + 81) != imports.cursor_position)
    return false;
  if (!imports.active_window ||
      Address(image, Sampler + 140) != imports.active_window)
    return false;
  if (Address(image, Main + 149) != imports.active_window) return false;
  if (!imports.screen_to_client ||
      Address(image, Main + 666) != imports.screen_to_client)
    return false;
  const auto vtable = Address(image, WindowCtor + 42);
  if (!Span(image, vtable, 8, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE) ||
      Address(image, vtable + 4) != Handler)
    return false;
  const auto table0 = Address(image, Message + 43);
  constexpr uint32_t offsets0[] = {0x2f, 0x46, 0x13e, 0x13e, 0x2f, 0x46};
  if (table0 < Message || table0 - Message != 324 ||
      !Span(image, table0, sizeof(offsets0), IMAGE_SCN_MEM_READ))
    return false;
  for (size_t i = 0; i < std::size(offsets0); ++i)
    if (Address(image, table0 + i * 4) != Message + offsets0[i]) return false;
  const auto table1 = Address(image, Message + 199);
  constexpr uint32_t offsets1[] = {0xcb,  0x13e, 0xdf,  0xf3, 0x13e,
                                   0x107, 0x11b, 0x13e, 0x12f};
  if (table1 < Message || table1 - Message != 348 ||
      !Span(image, table1, sizeof(offsets1), IMAGE_SCN_MEM_READ))
    return false;
  for (size_t i = 0; i < std::size(offsets1); ++i)
    if (Address(image, table1 + i * 4) != Message + offsets1[i]) return false;
  const auto table2 = Address(image, Handler + 60);
  constexpr uint32_t offsets2[] = {0x40, 0x74, 0x5a, 0x143, 0x143};
  if (table2 < Handler || table2 - Handler != 408 ||
      !Span(image, table2, sizeof(offsets2), IMAGE_SCN_MEM_READ))
    return false;
  for (size_t i = 0; i < std::size(offsets2); ++i)
    if (Address(image, table2 + i * 4) != Handler + offsets2[i]) return false;
  const auto indices = Address(image, Handler + 53);
  constexpr uint8_t expected_indices[] = {0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
                                          4, 4, 4, 1, 2, 4, 4, 4, 4, 4, 4,
                                          4, 4, 4, 4, 4, 4, 4, 4, 4, 3};
  if (indices < Handler || indices - Handler != 0x1ac ||
      !Span(image, indices, sizeof(expected_indices), IMAGE_SCN_MEM_READ) ||
      std::memcmp(image.base + indices, expected_indices,
                  sizeof(expected_indices)) != 0)
    return false;
  *output = {root,    owner,   config,         window, input,
             current, prior,   viewport,       gate2,  gate3,
             manager, Sampler, Sampler + 0xa3, Main,   Main + 0x20b,
             Message, Handler, Handler + 0x1c, vtable, scene};
  return true;
}
}  // namespace fushi_voice_hook::siglus_eightarg_input_viewport
