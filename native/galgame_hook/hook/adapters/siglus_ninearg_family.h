#pragma once

#include "siglus_legacy_glyph_sites.h"
#include "siglus_legacy_input_viewport.h"

// Late FPO SiglusEngine generation (structural family, never a title list).
// It shares the legacy text body, iterator-proxy string and input-message ABI,
// but its glyph layout is a nine-DWORD __stdcall routine that never writes the
// laid-out position back into the glyph: the dialogue walker passes the owner
// origin as arguments 8/9 and the glyph keeps only its line-local offset at
// +0x14/+0x18. Glyphs stride 0x270, dialogue entries 0x114. The key sampler
// polls GetKeyState per key through a pointer slot (a protector may emulate it)
// instead of GetKeyboardState.
namespace fushi_voice_hook::siglus_ninearg {
using siglus_family::Signature;
namespace glyph = siglus_legacy_glyph;
namespace input = siglus_legacy_input_viewport;

// Masks cover relocated absolute addresses, the entry's disabled branch and
// direct CALL displacements only. Frame sizes, argument slots, strides, owner
// fields and epilogues stay exact.
inline constexpr Signature kGlyphEntry{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC D8 00 00 00 53 55 56 57 "
    "A1 ?? ?? ?? ?? 33 C4 50 8D 84 24 EC 00 00 00 64 A3 00 00 00 00 8B AC 24 "
    "FC 00 00 00 80 7D 1C 00 0F 84 ?? ?? ?? ?? C7 45 20 02 00 00 00 8B 0D ?? "
    "?? ?? ??"};
inline constexpr Signature kGlyphFont{
    "8B 4D 08 8B 55 04 33 C0 38 84 24 10 01 00 00 C6 44 24 17 FF 0F 95 C0 C6 "
    "44 24 16 FF C6 44 24 15 FF C6 44 24 14 FF 50 8B 44 24 18 50 8B 45 00 51 "
    "52 50 8D 4C 24 40 51 E8 ?? ?? ?? ??"};
inline constexpr Signature kGlyphCoordinates{
    "8B 55 18 03 94 24 1C 01 00 00 A1 ?? ?? ?? ?? 8B 80 8C 99 B6 00 8B BC 24 "
    "00 01 00 00 33 C9 89 4C 24 3C 8B 4D 14 03 8C 24 18 01 00 00 89 44 24 40 "
    "8B 84 24 04 01 00 00 89 4C 24 18 DB 44 24 18 89 54 24 18 8D 74 24 34 D9 "
    "5C 24 48 C7 44 24 34 01 00 00 00 DB 44 24 18 89 84 24 B0 00 00 00 D9 5C "
    "24 4C E8 ?? ?? ?? ??"};
inline constexpr Signature kGlyphReturn{
    "B0 01 8B 8C 24 EC 00 00 00 64 89 0D 00 00 00 00 59 5F 5E 5D 5B 81 C4 E4 "
    "00 00 00 C2 24 00"};
inline constexpr Signature kDialogue{
    "51 8B 86 08 01 00 00 85 C0 53 55 57 75 04 33 ED EB 1B 8B 8E 0C 01 00 00 "
    "2B C8 B8 D3 20 0D D2 F7 E9 03 D1 C1 FA 09 8B EA C1 ED 1F 03 EA 33 DB 85 "
    "ED 7E 74 33 FF 8B 86 08 01 00 00 85 C0 74 1F 8B 8E 0C 01 00 00 2B C8 B8 "
    "D3 20 0D D2 F7 E9 03 D1 C1 FA 09 8B C2 C1 E8 1F 03 C2 3B D8 72 05 E8 ?? "
    "?? ?? ?? 8B 4C 24 2C 8B 54 24 28 8B 86 08 01 00 00 51 8B 4C 24 28 52 8B "
    "54 24 28 51 8B 4C 24 28 52 8B 54 24 28 51 8B 4C 24 28 52 6A 00 03 C7 51 "
    "50 E8 ?? ?? ?? ?? 84 C0 74 16 83 C3 01 81 C7 70 02 00 00 3B DD 7C 8E B0 "
    "01 5F 5D 5B 59 C2 1C 00 5F 5D 32 C0 5B 59 C2 1C 00"};
inline constexpr Signature kRenderEntry{
    "81 EC 38 01 00 00 53 55 8B AC 24 44 01 00 00 56 57 55 E8 ?? ?? ?? ??"};
inline constexpr Signature kRenderFirstPass{
    "8B 85 B4 01 00 00 85 C0 74 19 8B 8D B8 01 00 00 2B C8 B8 DB 81 B9 76 F7 "
    "E9 C1 FA 07 8B C2 C1 E8 1F 03 C2 39 44 24 28 0F 8D AD 00 00 00 8B 44 24 "
    "5C 8B 54 24 70 8D 3C 18 8B 85 B4 01 00 00 03 F2 85 C0 C6 44 24 33 00 C6 "
    "44 24 32 00 C6 44 24 31 00 C6 44 24 30 00 74 1F 8B 8D B8 01 00 00 2B C8 "
    "B8 DB 81 B9 76 F7 E9 C1 FA 07 8B C2 C1 E8 1F 03 C2 39 44 24 28 72 05 E8 "
    "?? ?? ?? ?? 8B 8C 24 54 01 00 00 8B 94 24 50 01 00 00 8B 85 B4 01 00 00 "
    "03 44 24 18 57 56 51 8B 4C 24 3C 52 6A 00 51 8D 94 24 A0 00 00 00 52 8B "
    "F0 E8 ?? ?? ?? ?? 84 C0 74 19 83 44 24 28 01 81 44 24 18 14 01 00 00 8B "
    "B4 24 80 00 00 00 E9 35 FF FF FF 32 C0 5F 5E 5D 5B 81 C4 38 01 00 00 C2 "
    "0C 00"};
inline constexpr Signature kRenderSecondPass{
    "8B 85 B4 01 00 00 85 C0 74 19 8B 8D B8 01 00 00 2B C8 B8 DB 81 B9 76 F7 "
    "E9 C1 FA 07 8B C2 C1 E8 1F 03 C2 3B F8 0F 8D 97 00 00 00 8B 85 B4 01 00 "
    "00 85 C0 C6 44 24 2B 00 C6 44 24 2A 00 C6 44 24 29 00 C6 44 24 28 00 74 "
    "1D 8B 8D B8 01 00 00 2B C8 B8 DB 81 B9 76 F7 E9 C1 FA 07 8B C2 C1 E8 1F "
    "03 C2 3B F8 72 05 E8 ?? ?? ?? ?? 8B 44 24 34 8B 4C 24 30 8B 94 24 54 01 "
    "00 00 8B B5 B4 01 00 00 03 74 24 18 50 8B 84 24 54 01 00 00 51 8B 4C 24 "
    "30 52 50 6A 00 51 8D 94 24 A0 00 00 00 52 E8 ?? ?? ?? ?? 84 C0 0F 84 8D "
    "FE FF FF 8B B4 24 80 00 00 00 83 C7 01 81 44 24 18 14 01 00 00 E9 3E FF "
    "FF FF"};
inline constexpr Signature kRenderExit{
    "5F 5E 5D B0 01 5B 81 C4 38 01 00 00 C2 0C 00"};
inline constexpr Signature kGroupRender{
    "51 53 8B 5C 24 0C 8B 83 50 01 00 00 85 C0 55 56 57 75 04 33 FF EB 19"};
inline constexpr Signature kGroupOwnerLoop{
    "8B 83 D4 03 00 00 85 C0 75 04 33 FF EB 1B 8B 8B D8 03 00 00 2B C8 B8 E1 "
    "02 17 B8 F7 E9 03 D1 C1 FA 0C 8B FA C1 EF 1F 03 FA 33 F6 85 FF 7E 5F 33 "
    "ED 8D 9B 00 00 00 00 8B 83 D4 03 00 00 85 C0 74 1F 8B 8B D8 03 00 00 2B "
    "C8 B8 E1 02 17 B8 F7 E9 03 D1 C1 FA 0C 8B C2 C1 E8 1F 03 C2 3B F0 72 05 "
    "E8 ?? ?? ?? ?? 8B 54 24 20 8B 83 D4 03 00 00 8B 4C 24 1C 52 03 C5 51 50 "
    "E8 ?? ?? ?? ?? 84 C0 74 31 83 C6 01 81 C5 40 16 00 00 3B F7 7C A9 8B 54 "
    "24 20 8B 44 24 1C 52 50 8D 8B E8 03 00 00 51 E8 ?? ?? ?? ?? 8B 83 90 06 "
    "00 00 85 C0 75 0E 33 ED EB 23 32 C0 5F 5E 5D 5B 59 C2 10 00"};
inline constexpr Signature kNormalGroups{
    "8B 85 E8 1D 04 00 85 C0 74 1E 8B 8D EC 1D 04 00 2B C8 B8 69 6E 54 04 F7 "
    "E9 C1 FA 05 8B C2 C1 E8 1F 03 C2 83 F8 01 77 05 E8 ?? ?? ?? ?? 8B 8D E8 "
    "1D 04 00 6A 00 57 56 81 C1 64 07 00 00 51 E8 ?? ?? ?? ?? 83 BD C8 E5 03 "
    "00 00 7C 43 8B 85 E8 1D 04 00 85 C0 74 1E 8B 8D EC 1D 04 00 2B C8 B8 69 "
    "6E 54 04 F7 E9 C1 FA 05 8B C2 C1 E8 1F 03 C2 83 F8 02 77 05 E8 ?? ?? ?? "
    "?? 8B 95 E8 1D 04 00 6A 00 57 56 81 C2 C8 0E 00 00 52 E8 ?? ?? ?? ??"};
inline constexpr Signature kMessage{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 44 A1 ?? ?? ?? ?? 33 C4 "
    "89 44 24 40 53 55 56 57 A1 ?? ?? ?? ?? 33 C4 50 8D 44 24 58 64 A3 00 00 "
    "00 00 8B AC 24 88 00 00 00 8B 9C 24 84 00 00 00 8B F9 33 C0 3B F8 89 44 "
    "24 60 75 0D 83 BC 24 80 00 00 00 08 E9 84 01 00 00 C7 44 24 50 07 00 00 "
    "00 89 44 24 4C 66 89 44 24 3C C6 44 24 60 01 A1 ?? ?? ?? ?? 89 98 E8 02 "
    "00 00 89 A8 EC 02 00 00 E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 80 B8 B5 00 00 00 "
    "00 75 2B 8B 0D ?? ?? ?? ?? 80 79 01 00 74 1F 80 B8 E8 00 00 00 00 75 0F "
    "8B 15 ?? ?? ?? ?? 80 BA 12 01 00 00 00 74 07 B1 01 E8 ?? ?? ?? ?? 8D 4C "
    "24 68 C6 87 58 01 00 00 01 E8 ?? ?? ?? ?? 8D 44 24 68 E8 ?? ?? ?? ?? 8D "
    "44 24 38 50 8D 4C 24 6C 51 E8 ?? ?? ?? ?? 8B F7 E8 ?? ?? ?? ?? 83 7C 24 "
    "4C 00 74 14 55 53 8D 54 24 70 52 57 8D 4C 24 48 E8 ?? ?? ?? ?? 83 C4 10 "
    "8D 44 24 14 50 8D B7 70 01 00 00 89 5C 24 18 89 6C 24 1C E8 ?? ?? ?? ?? "
    "80 BC 24 8C 00 00 00 00 BE 08 00 00 00 74 4F 8B 0D ?? ?? ?? ?? 80 B9 3C "
    "03 00 00 00 75 40 8D 54 24 1C 52 E8 ?? ?? ?? ?? C6 44 24 60 02 8B 0D ?? "
    "?? ?? ?? 8B 51 7C 8B 49 78 52 51 50 8D 44 24 74 50 E8 ?? ?? ?? ?? C6 44 "
    "24 60 01 39 74 24 34 72 0D 8B 4C 24 20 51 E8 ?? ?? ?? ?? 83 C4 04 57 C6 "
    "87 59 01 00 00 01 E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 80 B8 21 03 00 00 00 75 "
    "17 80 B8 23 03 00 00 00 75 0E 83 7C 24 4C 00 75 07 8B CF E8 ?? ?? ?? ?? "
    "39 74 24 50 72 0D 8B 54 24 3C 52 E8 ?? ?? ?? ?? 83 C4 04 33 C0 39 B4 24 "
    "80 00 00 00 C7 44 24 50 07 00 00 00 89 44 24 4C 66 89 44 24 3C 72 0D 8B "
    "44 24 6C 50 E8 ?? ?? ?? ?? 83 C4 04 8B 4C 24 58 64 89 0D 00 00 00 00 59 "
    "5F 5E 5D 5B 8B 4C 24 40 33 CC E8 ?? ?? ?? ?? 83 C4 50 C3"};
inline constexpr Signature kSampler{
    "81 EC 14 01 00 00 A1 ?? ?? ?? ?? 33 C4 89 84 24 0C 01 00 00 53 55 56 8B "
    "35 ?? ?? ?? ?? 57 8D 44 24 10 33 FF 50 89 7C 24 14 89 7C 24 18 FF 15 ?? "
    "?? ?? ?? 8B 4C 24 10 8B 54 24 14 68 FF 00 00 00 8D 44 24 1D 57 50 89 8E "
    "40 10 00 00 89 96 44 10 00 00 C6 44 24 24 00 E8 ?? ?? ?? ?? 83 C4 0C FF "
    "15 ?? ?? ?? ?? 85 C0 8D 5F 01 74 1E 8B 2D ?? ?? ?? ?? 57 FF D5 C1 E8 08 "
    "24 80 88 44 3C 18 03 FB 81 FF 00 01 00 00 7C EA 33 FF 39 9E 48 10 00 00 "
    "BA 02 00 00 00 75 29 F6 44 24 19 80 75 22 39 BE 50 10 00 00 89 BE 48 10 "
    "00 00 75 06 89 9E 50 10 00 00 39 9E 54 10 00 00 75 06 89 96 54 10 00 00 "
    "39 9E 58 10 00 00 75 29 F6 44 24 1A 80 75 22 39 BE 60 10 00 00 89 BE 58 "
    "10 00 00 75 06 89 9E 60 10 00 00 39 9E 64 10 00 00 75 06 89 96 64 10 00 "
    "00 39 9E 68 10 00 00 75 29 F6 44 24 1C 80 75 22 39 BE 70 10 00 00 89 BE "
    "68 10 00 00 75 06 89 9E 70 10 00 00 39 9E 74 10 00 00 75 06 89 96 74 10 "
    "00 00 33 C9 8D 86 8C 10 00 00 8D 9B 00 00 00 00 39 58 F4 75 18 F6 44 0C "
    "18 80 75 11 39 78 FC 89 78 F4 75 03 89 58 FC 39 18 75 02 89 10 39 58 04 "
    "75 1A F6 44 0C 19 80 75 13 89 78 04 39 78 0C 75 03 89 58 0C 39 58 10 75 "
    "03 89 50 10 39 58 14 75 1A F6 44 0C 1A 80 75 13 89 78 14 39 78 1C 75 03 "
    "89 58 1C 39 58 20 75 03 89 50 20 39 58 24 75 1A F6 44 0C 1B 80 75 13 89 "
    "78 24 39 78 2C 75 03 89 58 2C 39 58 30 75 03 89 50 30 83 C1 04 83 C0 40 "
    "81 F9 00 01 00 00 0F 8C 74 FF FF FF E8 ?? ?? ?? ?? 8A 44 24 19 24 80 32 "
    "C9 3A C8 8A 44 24 1A 1B D2 F7 DA 24 80 3A C8 8A 44 24 1C 89 56 08 1B D2 "
    "F7 DA 24 80 3A C8 89 56 18 1B D2 F7 DA 89 56 28 33 C0 83 C6 40 0F B6 4C "
    "04 18 80 E1 80 32 D2 3A D1 1B C9 F7 D9 89 0E 03 C3 83 C6 10 3D 00 01 00 "
    "00 7C E2 8B 8C 24 1C 01 00 00 5F 5E 5D 5B 33 CC E8 ?? ?? ?? ?? 81 C4 14 "
    "01 00 00 C3"};
inline constexpr Signature kInputMessage{
    "56 8B 35 ?? ?? ?? ?? 57 8B 7C 24 0C 81 FF 01 02 00 00 77 66 74 36 8D 87 "
    "00 FF FF FF 83 F8 05 0F 87 C4 00 00 00 FF 24 85 ?? ?? ?? ?? 8D BE 80 10 "
    "00 00 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8D BE 80 10 00 00 E8 ?? ?? ?? ?? 5F "
    "5E C2 04 00 83 BE 4C 10 00 00 00 B8 01 00 00 00 89 86 48 10 00 00 75 06 "
    "89 86 4C 10 00 00 83 BE 54 10 00 00 00 75 7A 5F 89 86 54 10 00 00 5E C2 "
    "04 00 8D 87 FE FD FF FF 83 F8 08 77 64 FF 24 85 ?? ?? ?? ?? 8D 86 48 10 "
    "00 00 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8D 86 58 10 00 00 E8 ?? ?? ?? ?? 5F "
    "5E C2 04 00 8D 86 58 10 00 00 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8D 86 68 10 "
    "00 00 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8D 86 68 10 00 00 E8 ?? ?? ?? ?? 5F "
    "5E C2 04 00 8D BE 78 10 00 00 8B C2 E8 ?? ?? ?? ?? 5F 5E C2 04 00"};
inline constexpr Signature kNormalize{
    "68 40 10 00 00 8D BD B0 B7 03 00 8D 9D F0 C7 03 00 57 53 E8 ?? ?? ?? ?? "
    "83 C4 0C E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? BA 02 00 00 00 39 50 14 75 2F 83 "
    "BD 04 C8 03 00 00 75 26 83 78 08 00 8D 4A FF 75 17 39 48 10 75 12 39 50 "
    "14 75 0D 89 48 08 C7 40 10 00 00 00 00 89 48 14 89 88 48 10 00 00 8B F5 "
    "E8 ?? ?? ?? ?? E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 8B 08 8B 50 04 89 4C 24 34 "
    "8B 0D ?? ?? ?? ?? 8D 44 24 34 89 54 24 38 8B 51 04 50 52 FF 15 ?? ?? ?? "
    "?? 8B 44 24 34 8B 35 ?? ?? ?? ?? 89 06 8B 4C 24 38 89 4E 04 2B 85 88 D8 "
    "03 00 68 40 10 00 00 0F AF 85 80 D8 03 00 99 F7 BD 98 D8 03 00 56 57 89 "
    "06 8B C1 2B 85 8C D8 03 00 0F AF 85 84 D8 03 00 99 F7 BD 9C D8 03 00 89 "
    "46 04 E8 ?? ?? ?? ??"};
inline constexpr Signature kDesign{
    "A1 ?? ?? ?? ?? 88 9D 7B D8 03 00 89 BD 7C D8 03 00 8B 90 90 00 00 00 89 "
    "95 80 D8 03 00 8B 90 94 00 00 00 89 95 84 D8 03 00 33 D2 89 95 88 D8 03 "
    "00 89 95 90 D8 03 00 89 9D 8C D8 03 00 89 9D 94 D8 03 00 8B 90 90 00 00 "
    "00 89 95 98 D8 03 00 8B 90 94 00 00 00 89 95 9C D8 03 00 8B 90 90 00 00 "
    "00 89 95 A0 D8 03 00 8B 90 94 00 00 00 89 95 A4 D8 03 00 8B 90 90 00 00 "
    "00 89 95 A8 D8 03 00 8B 90 94 00 00 00 89 95 AC D8 03 00"};
inline constexpr Signature kOwner{
    "8B 84 24 9C 00 00 00 8D 88 64 8B B8 00 8D 90 80 8B B8 00 A3 ?? ?? ?? ?? "
    "05 10 8C B8 00 89 0D ?? ?? ?? ?? 89 15 ?? ?? ?? ?? 89 44 24 18 A3 ?? ?? "
    "?? ??"};
inline constexpr Signature kVisibility{
    "A1 ?? ?? ?? ?? 80 B8 B0 00 00 00 00 74 03 32 C0 C3 8B 0D ?? ?? ?? ?? 80 "
    "79 7D 00 75 F1 8B 15 ?? ?? ?? ?? 80 7A 02 00 75 E5 E8 ?? ?? ?? ?? 84 C0 "
    "0F 94 C0 C3"};
inline constexpr Signature kInputGate{
    "51 53 55 56 8B F0 80 BE 28 D9 03 00 00 57 0F 85 FC 00 00 00 80 BE 99 1E "
    "04 00 00 0F 85 EF 00 00 00 8D 86 3C 78 04 00 50 E8 ?? ?? ?? ?? 83 F8 02 "
    "0F 84 DA 00 00 00 83 F8 03 0F 84 D1 00 00 00 8B 0D ?? ?? ?? ?? 80 79 02 "
    "00 0F 85 C1 00 00 00 80 BE 67 E0 03 00 00 0F 85 B4 00 00 00 8B 0D ?? ?? "
    "?? ??"};

// Runtime object layout fixed by the signatures above (owner = config + kConfigOwner).
inline constexpr uint32_t kConfigOwner = 0xb88c10;
inline constexpr uint32_t kConfigWidth = 0x90;
inline constexpr uint32_t kConfigHeight = 0x94;
inline constexpr uint32_t kOwnerWindow = 0xf8;
inline constexpr uint32_t kOwnerInput = 0x39730;
inline constexpr uint32_t kOwnerModal = 0x3d878;      // Modal object; byte +0xb0.
inline constexpr uint32_t kOwnerHidden = 0x3dd04;     // Hidden-dialogue object; byte +2.
inline constexpr uint32_t kOwnerAuxiliary = 0x41e1c;  // Auxiliary object; byte +0x7d.
inline constexpr uint32_t kModalByte = 0xb0;
inline constexpr uint32_t kHiddenByte = 2;
inline constexpr uint32_t kAuxiliaryByte = 0x7d;
inline constexpr uint32_t kOwnerGateByte = 0x3e067;   // Read by the input gate.
inline constexpr uint32_t kOwnerDesignWidth = 0x3d880;
inline constexpr uint32_t kOwnerDesignHeight = 0x3d884;
inline constexpr uint32_t kOwnerViewportX = 0x3d888;
inline constexpr uint32_t kOwnerViewportY = 0x3d88c;
inline constexpr uint32_t kOwnerViewportWidth = 0x3d898;
inline constexpr uint32_t kOwnerViewportHeight = 0x3d89c;
// Owner -> normal group vector -> render owners -> dialogue entries -> glyphs.
// The renderer draws normal groups 1 and 2; the other group vector it draws
// is not admitted, matching the legacy auxiliary-group exclusion.
inline constexpr uint32_t kOwnerGroups = 0x41de8;
inline constexpr uint32_t kGroupStride = 0x764;
inline constexpr uint32_t kGroupOwners = 0x3d4;
inline constexpr uint32_t kOwnerStride = 0x1640;
inline constexpr uint32_t kOwnerEntries = 0x1b4;
inline constexpr uint32_t kEntryStride = 0x114;
inline constexpr uint32_t kEntryGlyphs = 0x108;
inline constexpr uint32_t kGlyphStride = 0x270;
// Glyph fields: code unit +4, extent +8, line-local position +0x14/+0x18.
inline constexpr uint32_t kGlyphRecordBytes = 0x1c;

struct Sites {
  uintptr_t glyph_entry = 0;
  uintptr_t dialogue_entry = 0;
  uintptr_t dialogue_glyph_return = 0;
  uintptr_t render_entry = 0;
  uintptr_t group_render = 0;
  uintptr_t text_entry = 0;
  uintptr_t message_entry = 0;
  uintptr_t message_text_return = 0;
  uintptr_t sampler = 0;
  uintptr_t key_state_return = 0;
  uintptr_t key_state_slot = 0;
  uintptr_t input_message = 0;
  uintptr_t main_message_handler = 0;
  uintptr_t main_message_return = 0;
  uintptr_t config_slot = 0;
  uintptr_t owner_slot = 0;
  uintptr_t input_slot = 0;
  uintptr_t window_slot = 0;
  uintptr_t modal_slot = 0;
  uintptr_t hidden_slot = 0;
  uintptr_t auxiliary_slot = 0;
};

// Static sites only. This proves neither the live owner layout, a visible
// dialogue, an input lease nor that the key slot really is GetKeyState; the
// caller must verify the slot live and read the runtime snapshot.
// This generation ships protector-merged images: data, imports and code share
// one executable section, so no section role separates a data slot from code.
// A slot is therefore only an aligned, readable image location here; the live
// owner aliases and the key slot's live target proof establish what it holds.
inline uintptr_t DataSlot(const exact_lookup::LoadedPeImage& image,
                          uintptr_t operand) {
  const auto slot = input::Address(image, operand);
  return slot != 0 && (slot & 3u) == 0 &&
                 input::Span(image, slot, 4, IMAGE_SCN_MEM_READ)
             ? slot
             : 0;
}

inline bool Resolve(const exact_lookup::LoadedPeImage& image, Sites* out) {
  using siglus_family::Unique;
  using siglus_family::ExecutableSpan;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 || image.size < 4 ||
      image.section_count > image.sections.size()) return false;
  uintptr_t entry = 0, font = 0, coordinates = 0, glyph_return = 0, dialogue = 0;
  uintptr_t render = 0, first = 0, second = 0, render_exit = 0, group = 0;
  uintptr_t group_owners = 0, normal = 0, message = 0, text_tail = 0;
  uintptr_t text_string = 0, text_return = 0;
  if (!Unique(image, kGlyphEntry.pattern(), &entry) ||
      !Unique(image, kGlyphFont.pattern(), &font) ||
      !Unique(image, kGlyphCoordinates.pattern(), &coordinates) ||
      !Unique(image, kGlyphReturn.pattern(), &glyph_return) ||
      !Unique(image, kDialogue.pattern(), &dialogue) ||
      !Unique(image, kRenderEntry.pattern(), &render) ||
      !Unique(image, kRenderFirstPass.pattern(), &first) ||
      !Unique(image, kRenderSecondPass.pattern(), &second) ||
      !Unique(image, kRenderExit.pattern(), &render_exit) ||
      !Unique(image, kGroupOwnerLoop.pattern(), &group_owners) ||
      !Unique(image, kNormalGroups.pattern(), &normal) ||
      !Unique(image, kMessage.pattern(), &message) ||
      !Unique(image, glyph::kTextTail.pattern(), &text_tail) ||
      !Unique(image, glyph::kTextString.pattern(), &text_string) ||
      !Unique(image, glyph::kTextReturn.pattern(), &text_return) ||
      text_tail < 7) return false;
  // One glyph body: its disabled branch lands on the RET 0x24 epilogue, and
  // the font fetch precedes the argument-8/9 coordinate computation.
  int32_t disabled = 0;
  std::memcpy(&disabled, image.base + entry + 58, 4);
  if (static_cast<int64_t>(entry) + 62 + disabled !=
          static_cast<int64_t>(glyph_return) ||
      glyph_return <= entry || glyph_return - entry > 0x1000 ||
      !ExecutableSpan(image, entry,
                      glyph_return + kGlyphReturn.bytes.size() - entry) ||
      font < entry + kGlyphEntry.bytes.size() ||
      coordinates < font + kGlyphFont.bytes.size() ||
      coordinates + kGlyphCoordinates.bytes.size() > glyph_return ||
      !glyph::AddressRole(image, entry + 3, IMAGE_SCN_MEM_EXECUTE, 0) ||
      !DataSlot(image, entry + 25)) return false;
  // The group renderer's entry is shared by a sibling routine, so it is
  // reached only through the normal-group draw and then matched in place.
  const auto group_pattern = kGroupRender.pattern();
  if (!glyph::CallTarget(image, normal + 62, &group) ||
      !ExecutableSpan(image, group, group_pattern.size) ||
      !exact_lookup::MatchesMaskedPattern(image.base + group, group_pattern))
    return false;
  // Dialogue walker -> glyph; both (mutually exclusive) render passes ->
  // walker; the group's owner loop -> renderer; the normal-group draw ->
  // group, twice. All bounds checks share one out-of-range helper.
  if (!glyph::Calls(image, dialogue + 145, entry) ||
      !(render < first && first < second && second < render_exit) ||
      render_exit - render > 0x1000 ||
      !ExecutableSpan(image, render,
                      render_exit + kRenderExit.bytes.size() - render) ||
      !glyph::Calls(image, first + 169, dialogue) ||
      !glyph::Calls(image, second + 158, dialogue) ||
      !(group < group_owners && group_owners - group < 0x400) ||
      !ExecutableSpan(image, group,
                      group_owners + kGroupOwnerLoop.bytes.size() - group) ||
      !glyph::Calls(image, group_owners + 120, render) ||
      !glyph::Calls(image, normal + 62, group) ||
      !glyph::Calls(image, normal + 138, group) ||
      !glyph::SameCall(image, dialogue + 94, first + 119) ||
      !glyph::SameCall(image, dialogue + 94, second + 102) ||
      !glyph::SameCall(image, dialogue + 94, group_owners + 96) ||
      !glyph::SameCall(image, dialogue + 94, normal + 40) ||
      !glyph::SameCall(image, dialogue + 94, normal + 116)) return false;
  uintptr_t ignored = 0;
  if (!glyph::CallTarget(image, font + 55, &ignored) ||
      !glyph::CallTarget(image, coordinates + 98, &ignored) ||
      !glyph::CallTarget(image, render + 18, &ignored) ||
      !glyph::CallTarget(image, group_owners + 159, &ignored)) return false;
  // Legacy text body, reached by this generation's dialogue message wrapper.
  const uintptr_t text = text_tail - 7;
  const uint32_t cookie = glyph::U32(image, entry + 25);
  if (!glyph::TextPrologue(image, text) || text_return <= text ||
      text_return - text > 0x1000 ||
      !ExecutableSpan(image, text, text_return + glyph::kTextReturn.bytes.size() - text) ||
      text_string < text_tail + glyph::kTextTail.bytes.size() ||
      text_string + glyph::kTextString.bytes.size() > text_return ||
      glyph::U32(image, text_tail + 14) != cookie ||
      glyph::U32(image, text_tail + 32) != cookie ||
      glyph::U32(image, message + 18) != cookie ||
      glyph::U32(image, message + 33) != cookie ||
      !glyph::Calls(image, message + 201, text) ||
      !glyph::AddressRole(image, message + 3, IMAGE_SCN_MEM_EXECUTE, 0)) return false;

  uintptr_t sampler = 0, input_message = 0, main = 0, normalize = 0;
  uintptr_t design = 0, owner = 0, visibility = 0, gate = 0;
  if (!Unique(image, kSampler.pattern(), &sampler) ||
      !Unique(image, kInputMessage.pattern(), &input_message) ||
      !Unique(image, input::kMainCall.pattern(), &main) ||
      !Unique(image, kNormalize.pattern(), &normalize) ||
      !Unique(image, kDesign.pattern(), &design) ||
      !Unique(image, kOwner.pattern(), &owner) ||
      !Unique(image, kVisibility.pattern(), &visibility) ||
      !Unique(image, kInputGate.pattern(), &gate)) return false;
  const auto input_slot = DataSlot(image, sampler + 25);
  const auto config = DataSlot(image, design + 1);
  const auto manager = DataSlot(image, owner + 46);
  const auto window = DataSlot(image, normalize + 122);
  const auto modal = DataSlot(image, visibility + 1);
  const auto auxiliary = DataSlot(image, visibility + 19);
  const auto hidden = DataSlot(image, visibility + 31);
  // The pointer slots the sampler calls through. Their live targets may be
  // protector stubs; only their image identity is proved here.
  const auto cursor = DataSlot(image, sampler + 47);
  const auto active = DataSlot(image, sampler + 97);
  const auto key_state = DataSlot(image, sampler + 110);
  const auto screen_to_client = DataSlot(image, normalize + 141);
  if (!input_slot || !config || !manager || !window || !modal || !auxiliary ||
      !hidden || !cursor || !active || !key_state || !screen_to_client ||
      key_state == cursor || key_state == active || cursor == active ||
      DataSlot(image, input_message + 3) != input_slot ||
      DataSlot(image, normalize + 33) != input_slot ||
      DataSlot(image, normalize + 107) != input_slot ||
      DataSlot(image, normalize + 151) != input_slot ||
      DataSlot(image, owner + 20) != config ||
      DataSlot(image, gate + 65) != hidden ||
      DataSlot(image, gate + 94) != config ||
      DataSlot(image, coordinates + 11) != config ||
      DataSlot(image, message + 134) != modal ||
      DataSlot(image, message + 149) != hidden ||
      !DataSlot(image, owner + 31) || !DataSlot(image, owner + 37) ||
      input::Call(image, main + 22) != input_message ||
      input::Call(image, normalize + 28) != sampler)
    return false;
  // Relocated jump tables dispatch to exact instruction boundaries inside the
  // same input-message routine; a borrowed table is rejected.
  constexpr uint32_t kTableOffsets[] = {0x2c, 0x3c, 0xe9, 0xe9, 0x2c, 0x3c,
                                        0x8c, 0xe9, 0x9c, 0xac, 0xe9,
                                        0xbc, 0xcc, 0xe9, 0xdc};
  const auto table = input::Address(image, input_message + 40);
  if (!table || input::Address(image, input_message + 136) != table + 24 ||
      !input::Span(image, table, sizeof(kTableOffsets), IMAGE_SCN_MEM_READ))
    return false;
  const uintptr_t base = image.absolute_base != 0
                             ? image.absolute_base
                             : reinterpret_cast<uintptr_t>(image.base);
  for (size_t i = 0; i < std::size(kTableOffsets); ++i) {
    if (static_cast<uint64_t>(base) + input_message + kTableOffsets[i] > UINT32_MAX ||
        glyph::U32(image, table + i * 4) != base + input_message + kTableOffsets[i])
      return false;
  }
  // Every wildcard CALL is an in-image executable edge; both button-up cases
  // share one transition helper, as do both button-down cases.
  for (const size_t at : {88u, 445u, 545u})
    if (!input::Call(image, sampler + at)) return false;
  for (const size_t at : {51u, 67u, 147u, 163u, 179u, 195u, 211u, 229u})
    if (!input::Call(image, input_message + at)) return false;
  if (input::Call(image, input_message + 147) != input::Call(image, input_message + 179) ||
      input::Call(image, input_message + 163) != input::Call(image, input_message + 195) ||
      !input::Call(image, visibility + 42) || !input::Call(image, gate + 41) ||
      !input::Call(image, normalize + 20) ||
      input::Call(image, normalize + 20) != input::Call(image, normalize + 219))
    return false;
  *out = {entry, dialogue, dialogue + 150, render, group, text, message,
          message + 206, sampler, sampler + 117, key_state, input_message,
          main, main + 26, config, manager, input_slot, window, modal,
          hidden, auxiliary};
  return true;
}

}  // namespace fushi_voice_hook::siglus_ninearg
