#pragma once

#include "siglus_resource_mapping.h"
#include "siglus_legacy_glyph_sites.h"
#include "siglus_voice_source.h"

namespace fushi_voice_hook {
// Static FPO / iterator-proxy string ABI proof, not an event-pairing or playback
// claim. Only the source worker may resolve canonical file identity and verify
// the archive member/range. No installed game path or hash admits this profile.
struct SiglusLegacyResourceMappingProfile {
  uintptr_t voice_entry_rva = 0;
  uintptr_t play_entry_rva = 0;
  uintptr_t resource_entry_rva = 0;
  uintptr_t resource_return_rva = 0;
  uintptr_t ogg_open_rva = 0;
  uintptr_t payload_return_rva = 0;
  uintptr_t ogg_vtable_rva = 0;
  static constexpr uint32_t kVoiceKeyRadix = 100000;
  static constexpr uint32_t ogg_callee_cleanup_bytes = 12;
};
namespace siglus_legacy_resource {
using siglus_family::Signature;
// Bounded instruction spans for one complete compiler family. Splitting long
// routines is solely a constexpr compilation bound: every byte from Resource
// entry to RET 0xC remains covered, including loose-file alternatives, failure
// edges, the archive branch, 16-byte member loop and slot-4 payload call.
// Only relocated image addresses and direct CALL operands are masked. No
// branch, register, stack displacement, divisor or string-layout field varies.
inline constexpr Signature kVoice0{
    "A1 ?? ?? ?? ?? 53 56 C6 80 61 01 00 00 01 E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? "
    "?? 83 C4 04 80 B9 EF 01 00 00 00 8A D8 A1 ?? ?? ?? ?? 75 09 80 B8 AD 00 "
    "00 00 00 74 09 80 B8 B9 00 00 00 00 EB 07 80 B8 B8 00 00 00 00 74 08 8B "
    "80 BC 00 00 00 EB 05 B8 64 00 00 00 8B 4C 24 0C 84 DB 0F 94 C2 52 8B 54 "
    "24 0C 6A 00 51 52 50 A1 ?? ?? ?? ?? 56 57 05 98 00 00 00 E8 ?? ?? ?? ?? "
    "A1 ?? ?? ?? ?? 83 C9 FF 88 98 A4 01 00 00 89 B8 9C 01 00 00 89 B0 A0 01 "
    "00 00 89 88 A8 01 00 00 89 88 AC 01 00 00 5B C3"};

inline constexpr Signature kPlay0{
    "53 8B 5C 24 08 55 8B 6C 24 10 56 8B F0 8B 46 64 85 C0 57 74 18 8B 4E 68 "
    "2B C8 B8 61 60 60 60 F7 E9 C1 FA 07 8B C2 C1 E8 1F 03 C2 75 05 E8 ?? ?? "
    "?? ?? 8B 4E 64 6A 01 E8 ?? ?? ?? ?? 80 7C 24 28 00 55 74 0E 8B 0D ?? ?? "
    "?? ?? 8B B9 00 01 00 00 EB 0C 8B 15 ?? ?? ?? ?? 8B BA FC 00 00 00 E8 ?? "
    "?? ?? ?? 8B C8 0F AF CF B8 81 80 80 80 F7 E9 03 D1 C1 FA 07 8B C2 C1 E8 "
    "1F 83 C4 04 03 C2 50 E8 ?? ?? ?? ?? 8B 46 64 85 C0 74 18 8B 4E 68 2B C8 "
    "B8 61 60 60 60 F7 E9 C1 FA 07 8B C2 C1 E8 1F 03 C2 75 05 E8 ?? ?? ?? ?? "
    "8B 54 24 2C 8B 44 24 1C 8B 4E 64 52 50 53 E8 ?? ?? ?? ??"};

inline constexpr Signature kResource0{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 00 01 00 00 A1 ?? ?? ?? "
    "?? 33 C4 89 84 24 F8 00 00 00 53 55 56 57 A1 ?? ?? ?? ?? 33 C4 50 8D 84 "
    "24 14 01 00 00 64 A3 00 00 00 00 8B F1 6A 01 89 B4 24 80 00 00 00 E8 ?? "
    "?? ?? ?? 83 CF FF 8D 86 34 01 00 00 89 BE 28 01 00 00 89 BE 2C 01 00 00 "
    "89 BE 30 01 00 00 E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 33 DB 89 BE 50 01 00 00 "
    "38 18 75 0D 38 9C 24 2C 01 00 00 0F 85 DE 0B 00 00 8B 8C 24 24 01 00 00 "
    "3B CB 0F 8C CF 0B 00 00 B8 89 B5 F8 14 F7 E9 C1 FA 0D 8B FA C1 EF 1F 03 "
    "FA 8B D7 69 D2 A0 86 01 00 8B C1 2B C2 BD 07 00 00 00 89 44 24 38 89 AC "
    "24 EC 00 00 00 89 9C 24 E8 00 00 00 66 89 9C 24 D8 00 00 00 89 9C 24 1C "
    "01 00 00 89 AC 24 D0 00 00 00 89 9C 24 CC 00 00 00 66 89 9C 24 BC 00 00 "
    "00 51 C6 84 24 20 01 00 00 01 83 EC 1C 8B F4 89 64 24 38 6A 09 89 6E 18 "
    "89 5E 14 68 ?? ?? ?? ?? 89 5C 24 44 66 89 5E 04 E8 ?? ?? ?? ?? 8D 4C 24 "
    "60 E8 ?? ?? ?? ?? 83 C4 20 6A FF 53 50 8D 84 24 E0 00 00 00 C6 84 24 28 "
    "01 00 00 02 E8 ?? ?? ?? ?? C6 84 24 1C 01 00 00 01 83 7C 24 58 08 72 0D "
    "8B 44 24 44 50 E8 ?? ?? ?? ?? 83 C4 04 8D 8C 24 D4 00 00 00 51 57 83 EC "
    "1C 8B F4 89 64 24 3C 6A 06 89 6E 18 89 5E 14 68 ?? ?? ?? ?? 66 89 5E 04 "
    "E8 ?? ?? ?? ?? 8D 8C 24 14 01 00 00 E8 ?? ?? ?? ?? C6 84 24 40 01 00 00 "
    "03 8B 0D ?? ?? ?? ?? 50 81 C1 E0 00 00 00 8D B4 24 84 00 00 00 E8 ?? ?? "
    "?? ?? 83 C4 24 8B C8 8D 74 24 44 C6 84 24 20 01 00 00 04 E8 ?? ?? ?? ?? "
    "83 C4 04 6A FF 53 50 8D 84 24 C4 00 00 00 C6 84 24 28 01 00 00 05 E8 ?? "
    "?? ?? ?? BE 08 00 00 00 39 74 24 58 72 0D 8B 54 24 44 52 E8 ?? ?? ?? ?? "
    "83 C4 04 39 74 24 74 89 6C 24 58 89 5C 24 54 66 89 5C 24 44 72 0D 8B 44 "
    "24 60 50 E8 ?? ?? ?? ?? 83 C4 04 C6 84 24 1C 01 00 00 01 39 B4 24 08 01 "
    "00 00 89 6C 24 74 89 5C 24 70"};

inline constexpr Signature kResource1{
    "66 89 5C 24 60 72 10 8B 8C 24 F4 00 00 00 51 E8 ?? ?? ?? ?? 83 C4 04 39 "
    "B4 24 D0 00 00 00 8B 84 24 BC 00 00 00 73 07 8D 84 24 BC 00 00 00 50 FF "
    "15 ?? ?? ?? ?? 83 F8 FF 74 08 A8 10 0F 84 E6 01 00 00 57 83 EC 1C BA ?? "
    "?? ?? ?? 8B C4 C7 44 24 3C 01 00 00 00 89 64 24 38 E8 ?? ?? ?? ?? 8D 4C "
    "24 60 E8 ?? ?? ?? ?? 83 C4 20 6A FF 53 50 8D 84 24 E0 00 00 00 C6 84 24 "
    "28 01 00 00 06 E8 ?? ?? ?? ?? C6 84 24 1C 01 00 00 01 39 74 24 58 72 0D "
    "8B 54 24 44 52 E8 ?? ?? ?? ?? 83 C4 04 8B 0D ?? ?? ?? ?? 68 ?? ?? ?? ?? "
    "81 C1 E0 00 00 00 8D BC 24 F4 00 00 00 89 6C 24 5C 89 5C 24 58 66 89 5C "
    "24 48 E8 ?? ?? ?? ?? 83 C4 04 8D 8C 24 D4 00 00 00 51 8B C8 8D 74 24 60 "
    "C6 84 24 20 01 00 00 07 E8 ?? ?? ?? ?? 83 C4 04 6A FF 53 50 8D 84 24 C4 "
    "00 00 00 C6 84 24 28 01 00 00 08 E8 ?? ?? ?? ?? BE 08 00 00 00 39 74 24 "
    "74 72 0D 8B 54 24 60 52 E8 ?? ?? ?? ?? 83 C4 04 C6 84 24 1C 01 00 00 01 "
    "39 B4 24 08 01 00 00 89 6C 24 74 89 5C 24 70 66 89 5C 24 60 72 10 8B 84 "
    "24 F4 00 00 00 50 E8 ?? ?? ?? ?? 83 C4 04 39 B4 24 D0 00 00 00 8B 84 24 "
    "BC 00 00 00 73 07 8D 84 24 BC 00 00 00 50 FF 15 ?? ?? ?? ?? 83 F8 FF 74 "
    "08 A8 10 0F 84 B7 00 00 00 8B 8C 24 24 01 00 00 51 83 EC 1C BA ?? ?? ?? "
    "?? 8B C4 89 64 24 38 E8 ?? ?? ?? ?? 8D 8C 24 10 01 00 00 E8 ?? ?? ?? ?? "
    "8D 94 24 10 01 00 00 52 BA ?? ?? ?? ?? 8D B4 24 80 00 00 00 C6 84 24 40 "
    "01 00 00 09 E8 ?? ?? ?? ?? 83 C4 24 68 ?? ?? ?? ?? 8B C8 8D 7C 24 44 C6 "
    "84 24 20 01 00 00 0A E8 ?? ?? ?? ?? 83 C4 04 50 C6 84 24 20 01 00 00 0B "
    "A1 ?? ?? ?? ?? 6A 0C 50 E8 ?? ?? ?? ?? 8B CF 8A D8 E8 ?? ?? ?? ?? 8B CE "
    "E8 ?? ?? ?? ?? 8D 8C 24 F0 00 00 00 E8 ?? ?? ?? ?? 8D 8C 24 B8 00 00 00 "
    "E8 ?? ?? ?? ?? 8D 8C 24 D4 00 00 00 E8 ?? ?? ?? ?? 8A C3 E9 0F 08 00 00 "
    "38 9C 24 2C 01 00 00 74 51"};

inline constexpr Signature kResource2{
    "39 B4 24 D0 00 00 00 72 10 8B 8C 24 BC 00 00 00 51 E8 ?? ?? ?? ?? 83 C4 "
    "04 39 B4 24 EC 00 00 00 89 AC 24 D0 00 00 00 89 9C 24 CC 00 00 00 66 89 "
    "9C 24 BC 00 00 00 0F 82 C8 07 00 00 8B 94 24 D8 00 00 00 52 E8 ?? ?? ?? "
    "?? 83 C4 04 E9 B3 07 00 00 6A 20 E8 ?? ?? ?? ?? 83 C4 04 89 44 24 18 3B "
    "C3 C6 84 24 1C 01 00 00 0C 74 0B 8B F8 E8 ?? ?? ?? ?? 8B F0 EB 02 33 F6 "
    "C6 84 24 1C 01 00 00 01 56 8D 4C 24 30 89 74 24 2C E8 ?? ?? ?? ?? 56 8D "
    "44 24 2C 56 50 E8 ?? ?? ?? ?? 83 C4 0C 6A 20 C6 84 24 20 01 00 00 0D E8 "
    "?? ?? ?? ?? 83 C4 04 3B C3 74 1F 89 58 04 89 58 08 89 58 0C 89 58 10 C7 "
    "00 ?? ?? ?? ?? 89 58 14 89 58 18 89 58 1C 8B F0 EB 02 33 F6 56 8D 4C 24 "
    "28 89 74 24 24 E8 ?? ?? ?? ?? 56 8D 4C 24 24 56 51 E8 ?? ?? ?? ?? 83 C4 "
    "0C C6 84 24 1C 01 00 00 0E 8B 44 24 1C 3B C3 0F 85 7F 01 00 00 68 B4 00 "
    "00 00 E8 ?? ?? ?? ?? 83 C4 04 89 44 24 18 3B C3 C6 84 24 1C 01 00 00 0F "
    "74 0A 50 E8 ?? ?? ?? ?? 8B F0 EB 02 33 F6 C6 84 24 1C 01 00 00 0E 56 8D "
    "4C 24 40 89 74 24 3C E8 ?? ?? ?? ?? 56 8D 54 24 3C 56 52 E8 ?? ?? ?? ?? "
    "83 C4 0C C6 84 24 1C 01 00 00 10 8B 4C 24 38 8B 01 8B 40 04 53 53 8D 94 "
    "24 C0 00 00 00 52 FF D0 84 C0 0F 85 9D 00 00 00 8D 8C 24 D4 00 00 00 51 "
    "BA ?? ?? ?? ?? 8D 74 24 44 E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B C8 "
    "8D BC 24 F4 00 00 00 C6 84 24 20 01 00 00 11 E8 ?? ?? ?? ?? 83 C4 04 50 "
    "C6 84 24 20 01 00 00 12 6A 0C 8B 15 ?? ?? ?? ?? 52 E8 ?? ?? ?? ?? 8D 8C "
    "24 F0 00 00 00 8A D8 E8 ?? ?? ?? ?? 8D 4C 24 40 E8 ?? ?? ?? ?? 8D 44 24 "
    "38 C6 84 24 1C 01 00 00 0E E8 ?? ?? ?? ?? 8D 44 24 20 C6 84 24 1C 01 00 "
    "00 0D E8 ?? ?? ?? ?? 8D 44 24 28 C6 84 24 1C 01 00 00 01 E8 ?? ?? ?? ?? "
    "E9 C3 FD FF FF 8B 44 24 38 8B 7C 24 28 50 E8 ?? ?? ?? ?? 84 C0 75 47 8D "
    "8C 24 D4 00 00 00 51 BA ?? ?? ?? ??"};

inline constexpr Signature kResource3{
    "8D 74 24 44 E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B C8 8D BC 24 F4 00 "
    "00 00 C6 84 24 20 01 00 00 13 E8 ?? ?? ?? ?? 83 C4 04 50 C6 84 24 20 01 "
    "00 00 14 6A 02 E9 4C FF FF FF 8D 44 24 38 C6 84 24 1C 01 00 00 0E E8 ?? "
    "?? ?? ?? E9 B9 03 00 00 83 F8 01 0F 85 B0 03 00 00 89 5C 24 5C 89 5C 24 "
    "64 89 5C 24 68 BA ?? ?? ?? ?? 8D 84 24 F0 00 00 00 C6 84 24 1C 01 00 00 "
    "15 E8 ?? ?? ?? ?? 8D 84 24 F0 00 00 00 50 8D 8C 24 BC 00 00 00 51 8D 74 "
    "24 64 C6 84 24 24 01 00 00 16 E8 ?? ?? ?? ?? 84 C0 8D 8C 24 F0 00 00 00 "
    "0F 94 44 24 17 C6 84 24 1C 01 00 00 15 E8 ?? ?? ?? ?? 38 5C 24 17 74 73 "
    "8D 94 24 D4 00 00 00 52 BA ?? ?? ?? ?? 8D 74 24 44 E8 ?? ?? ?? ?? 83 C4 "
    "04 68 ?? ?? ?? ?? 8B C8 8D BC 24 F4 00 00 00 C6 84 24 20 01 00 00 17 E8 "
    "?? ?? ?? ?? 83 C4 04 50 C6 84 24 20 01 00 00 18 A1 ?? ?? ?? ?? 6A 0C 50 "
    "E8 ?? ?? ?? ?? 8B CF 8A D8 E8 ?? ?? ?? ?? 8B CE E8 ?? ?? ?? ?? 8D 74 24 "
    "5C C6 84 24 1C 01 00 00 0E E8 ?? ?? ?? ?? E9 87 FE FF FF 8B 4C 24 5C 51 "
    "8D 54 24 20 33 ED 52 8D 4D 04 83 CF FF 89 5C 24 24 E8 ?? ?? ?? ?? 8B 44 "
    "24 24 83 C4 08 3B C3 0F 86 2C 01 00 00 89 5C 24 44 89 5C 24 48 89 5C 24 "
    "4C C1 E0 04 50 8D 44 24 44 C6 84 24 20 01 00 00 19 E8 ?? ?? ?? ?? 8B 7C "
    "24 1C 8D 74 24 40 C1 E7 04 E8 ?? ?? ?? ?? 8B 4C 24 5C 51 50 8B CF E8 ?? "
    "?? ?? ?? 83 C4 08 E8 ?? ?? ?? ?? 8B 54 24 1C 33 C9 3B D3 7E 23 8B 74 24 "
    "38 39 70 08 74 0C 83 C1 01 83 C0 10 3B CA 7C ED EB 0E 8B 78 04 83 FF FF "
    "8B 28 0F 85 A3 00 00 00 8B 94 24 24 01 00 00 52 8D 8C 24 84 00 00 00 E8 "
    "?? ?? ?? ?? 83 C4 04 50 BA ?? ?? ?? ?? 8D B4 24 A0 00 00 00 C6 84 24 20 "
    "01 00 00 1A E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B C8 8D BC 24 F4 00 "
    "00 00 C6 84 24 20 01 00 00 1B E8 ?? ?? ?? ?? 83 C4 04 50 C6 84 24 20 01 "
    "00 00 1C A1 ?? ?? ?? ??"};

inline constexpr Signature kResource4{
    "6A 0C 50 E8 ?? ?? ?? ?? 8B CF 8A D8 E8 ?? ?? ?? ?? 8B CE E8 ?? ?? ?? ?? "
    "8D 8C 24 80 00 00 00 E8 ?? ?? ?? ?? 8D 74 24 40 E8 ?? ?? ?? ?? 8D 74 24 "
    "5C C6 84 24 1C 01 00 00 0E E8 ?? ?? ?? ?? E9 47 FD FF FF 8D 74 24 40 E8 "
    "?? ?? ?? ?? C6 84 24 1C 01 00 00 15 E8 ?? ?? ?? ?? 6A 20 E8 ?? ?? ?? ?? "
    "83 C4 04 89 44 24 18 3B C3 C6 84 24 1C 01 00 00 1D 74 0A 50 E8 ?? ?? ?? "
    "?? 8B F0 EB 02 33 F6 C6 84 24 1C 01 00 00 15 56 8D 4C 24 38 89 74 24 34 "
    "E8 ?? ?? ?? ?? 56 8D 4C 24 34 56 51 E8 ?? ?? ?? ?? 83 C4 0C C6 84 24 1C "
    "01 00 00 1E 8B 4C 24 30 8B 11 8B 52 04 55 57 8D 84 24 C0 00 00 00 50 FF "
    "D2 84 C0 0F 85 92 00 00 00 8D 84 24 D4 00 00 00 50 BA ?? ?? ?? ?? 8D B4 "
    "24 A0 00 00 00 E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B C8 8D BC 24 84 "
    "00 00 00 C6 84 24 20 01 00 00 1F E8 ?? ?? ?? ?? 83 C4 04 50 C6 84 24 20 "
    "01 00 00 20 6A 0C 8B 0D ?? ?? ?? ?? 51 E8 ?? ?? ?? ?? 8D 8C 24 80 00 00 "
    "00 8A D8 E8 ?? ?? ?? ?? 8D 8C 24 9C 00 00 00 E8 ?? ?? ?? ?? 8D 44 24 30 "
    "C6 84 24 1C 01 00 00 15 E8 ?? ?? ?? ?? 8D 74 24 5C C6 84 24 1C 01 00 00 "
    "0E E8 ?? ?? ?? ?? E9 2F FC FF FF 8B 54 24 30 8B 7C 24 28 52 E8 ?? ?? ?? "
    "?? 84 C0 75 4A 8D 84 24 D4 00 00 00 50 BA ?? ?? ?? ?? 8D B4 24 A0 00 00 "
    "00 E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B C8 8D BC 24 84 00 00 00 C6 "
    "84 24 20 01 00 00 21 E8 ?? ?? ?? ?? 83 C4 04 50 C6 84 24 20 01 00 00 22 "
    "6A 02 E9 57 FF FF FF 8D 44 24 30 C6 84 24 1C 01 00 00 15 E8 ?? ?? ?? ?? "
    "8D 74 24 5C C6 84 24 1C 01 00 00 0E E8 ?? ?? ?? ?? 83 BC 24 28 01 00 00 "
    "64 0F 84 FC 00 00 00 6A 20 E8 ?? ?? ?? ?? 83 C4 04 89 44 24 18 3B C3 C6 "
    "84 24 1C 01 00 00 23 74 09 8B F8 E8 ?? ?? ?? ?? EB 02 33 C0 8B F0 8D 7C "
    "24 30 C6 84 24 1C 01 00 00 0E E8 ?? ?? ?? ?? C6 84 24 1C 01 00 00 24 8B "
    "44 24 28 8B 48 0C 8B 50 08"};

inline constexpr Signature kResource5{
    "8B 70 04 8B 00 8B 7C 24 30 51 52 56 50 E8 ?? ?? ?? ?? 8B 44 24 28 8B 48 "
    "0C 8B 50 08 8B 78 04 8B 28 8D 70 14 89 4C 24 1C 8B 0E 3B CB 89 54 24 38 "
    "74 07 8B 40 18 2B C1 75 04 33 F6 EB 0B 3B C3 77 05 E8 ?? ?? ?? ?? 8B 36 "
    "8B 94 24 28 01 00 00 8B 44 24 30 52 57 8B 7C 24 40 55 56 83 C0 10 50 8D "
    "4C 24 2B 51 8B 4C 24 34 E8 ?? ?? ?? ?? 8B 4C 24 30 8B 41 14 3B C3 75 04 "
    "33 D2 EB 05 8B 51 18 2B D0 83 EC 08 89 51 0C 8D 4C 24 38 8B C4 89 64 24 "
    "20 E8 ?? ?? ?? ?? 8B 4C 24 28 E8 ?? ?? ?? ?? 8D 44 24 30 C6 84 24 1C 01 "
    "00 00 0E E8 ?? ?? ?? ?? EB 1B 83 EC 08 8D 4C 24 30 8B C4 89 64 24 20 E8 "
    "?? ?? ?? ?? 8B 4C 24 28 E8 ?? ?? ?? ?? 8B 54 24 20 83 EC 08 8B C4 89 10 "
    "8B 4C 24 2C 89 48 04 8B 44 24 2C 3B C3 89 64 24 20 74 0C 83 C0 04 BA 01 "
    "00 00 00 F0 0F C1 10 8B B4 24 84 00 00 00 6A 01 8B CE E8 ?? ?? ?? ?? 53 "
    "8B FE E8 ?? ?? ?? ?? 53 6A FF 33 C9 E8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8B 84 "
    "24 24 01 00 00 89 86 30 01 00 00 8D 44 24 20 C7 86 28 01 00 00 01 00 00 "
    "00 C6 84 24 1C 01 00 00 0D E8 ?? ?? ?? ?? 8D 44 24 28 C6 84 24 1C 01 00 "
    "00 01 E8 ?? ?? ?? ?? 8D 8C 24 B8 00 00 00 E8 ?? ?? ?? ?? 8D 8C 24 D4 00 "
    "00 00 E8 ?? ?? ?? ?? B0 01 8B 8C 24 14 01 00 00 64 89 0D 00 00 00 00 59 "
    "5F 5E 5D 5B 8B 8C 24 F8 00 00 00 33 CC E8 ?? ?? ?? ?? 81 C4 0C 01 00 00 "
    "C2 0C 00"};

inline constexpr Signature kFormatter0{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 08 08 00 00 A1 ?? ?? ?? "
    "?? 33 C4 89 84 24 04 08 00 00 56 57 A1 ?? ?? ?? ?? 33 C4 50 8D 84 24 14 "
    "08 00 00 64 A3 00 00 00 00 33 FF 8B F1 89 7C 24 0C 89 BC 24 1C 08 00 00 "
    "83 BC 24 3C 08 00 00 08 8B 84 24 28 08 00 00 73 07 8D 84 24 28 08 00 00 "
    "8D 8C 24 40 08 00 00 51 50 8D 54 24 18 68 00 04 00 00 52 E8 ?? ?? ?? ?? "
    "8D 44 24 20 C7 46 18 07 00 00 00 89 7E 14 83 C4 10 66 89 7E 04 8D 50 02 "
    "66 8B 08 83 C0 02 66 3B CF 75 F5 2B C2 D1 F8 50 8D 44 24 14 50 E8 ?? ?? "
    "?? ?? 83 BC 24 3C 08 00 00 08 72 10 8B 8C 24 28 08 00 00 51 E8 ?? ?? ?? "
    "?? 83 C4 04 8B C6 8B 8C 24 14 08 00 00 64 89 0D 00 00 00 00 59 5F 5E 8B "
    "8C 24 04 08 00 00 33 CC E8 ?? ?? ?? ?? 81 C4 14 08 00 00 C3"};

inline constexpr Signature kStringCtor0{
    "56 8B F0 8B C2 57 C7 46 18 07 00 00 00 C7 46 14 00 00 00 00 66 C7 46 04 "
    "00 00 8D 78 02 8D 49 00 66 8B 08 83 C0 02 66 85 C9 75 F5 2B C7 D1 F8 50 "
    "52 E8 ?? ?? ?? ?? 5F 8B C6 5E C3"};

inline constexpr Signature kOggCtor0{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 10 53 55 56 57 A1 ?? ?? "
    "?? ?? 33 C4 50 8D 44 24 24 64 A3 00 00 00 00 8B 74 24 34 33 DB 89 5E 04 "
    "89 5E 08 89 5E 0C 89 5E 10 89 5C 24 2C 8D 7E 14 C7 06 ?? ?? ?? ?? 89 1F "
    "89 5F 04"};

inline constexpr Signature kOggOpen0{
    "83 EC 20 53 55 8B D9 8B 03 8B 50 08 56 57 FF D2 8B 43 14 8B 4C 24 38 89 "
    "88 D4 02 00 00 8B 44 24 34 83 78 18 08 72 05 8B 40 04 EB 03 83 C0 04 8B "
    "53 14 68 ?? ?? ?? ?? 50 81 C2 D0 02 00 00 52 E8 ?? ?? ?? ?? 8B 43 14 83 "
    "C4 0C 83 B8 D0 02 00 00 00 0F 84 A1 00 00 00 8B 4C 24 3C 89 88 D8 02 00 "
    "00 8B 43 14 8B 90 D4 02 00 00 8B 80 D0 02 00 00 6A 00 52 50 E8 ?? ?? ?? "
    "?? 8B 4B 14 51 8B C4 BA ?? ?? ?? ?? 89 10 BE ?? ?? ?? ?? 89 70 04 33 F6 "
    "56 56 51 81 C1 D0 02 00 00 BF ?? ?? ?? ?? BD ?? ?? ?? ?? 89 78 08 51 89 "
    "68 0C E8 ?? ?? ?? ?? 83 C4 20 85 C0 7D 4E 8B 4B 14 8B 91 D0 02 00 00 52 "
    "E8 ?? ?? ?? ?? 8B 43 14 68 D0 02 00 00 56 50 E8 ?? ?? ?? ?? 8B 4B 14 89 "
    "B1 D0 02 00 00 8B 53 14 89 B2 D4 02 00 00 83 C4 10 89 73 1C 89 73 04 89 "
    "73 08 89 73 0C 89 73 10 32 C0 5F 5E 5D 5B 83 C4 20 C2 0C 00 8B 43 14 50 "
    "E8 ?? ?? ?? ?? 83 C4 04 85 C0 75 15 8B 03 8B 50 08 8B CB FF D2 32 C0 5F "
    "5E 5D 5B 83 C4 20 C2 0C 00 8B 43 14 6A FF 50 E8 ?? ?? ?? ?? 8B F0 8B 43 "
    "14 6A FF B9 08 00 00 00 8D 7C 24 1C 50 F3 A5 E8 ?? ?? ?? ?? 8B 4C 24 24 "
    "8B 54 24 28 89 4B 04 0F AF C8 83 C4 10 5F 5E 03 C9 5D C7 43 08 10 00 00 "
    "00 89 53 0C 89 4B 10 B0 01 5B 83 C4 20 C2 0C 00"};

inline constexpr Signature kCrtFormatter0{
    "FF 74 24 10 6A 00 FF 74 24 14 FF 74 24 14 FF 74 24 14 E8 ?? ?? ?? ?? 83 "
    "C4 14 C3"};

inline constexpr Signature kArchiveOpen0{
    "8B 06 57 50 E8 ?? ?? ?? ?? 83 C4 04 84 C0 74 52 8B 4C 24 08 51 8B 4C 24 "
    "10 8B D6 C7 06 00 00 00 00 C7 46 08 00 00 00 00 C7 46 0C 00 00 00 00 E8 "
    "?? ?? ?? ?? 83 C4 04 84 C0 74 27 8B 16 6A 02 6A 00 6A 00 52 E8 ?? ?? ?? "
    "?? 83 C4 10 84 C0 74 12 8B 3E E8 ?? ?? ?? ?? 85 FF 75 0D E8 ?? ?? ?? ?? "
    "EB 0F 32 C0 5F C2 08 00"};

inline constexpr Signature kArchiveRead0{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 54 53 55 56 57 A1 ?? ?? "
    "?? ?? 33 C4 50 8D 44 24 68 64 A3 00 00 00 00 8B 5C 24 7C 8B F1 8B 6C 24 "
    "78 E8 ?? ?? ?? ?? 33 FF 3B DF 0F 85 A5 00 00 00"};

struct Part { uintptr_t offset; exact_lookup::MaskedPattern pattern; };
inline bool At(const exact_lookup::LoadedPeImage& image, uintptr_t entry,
               const Part& part) {
  if (entry > UINTPTR_MAX - part.offset ||
      !siglus_family::ExecutableSpan(image, entry + part.offset, part.pattern.size)) return false;
  for (size_t i=0;i<part.pattern.size;++i)
    if ((image.base[entry+part.offset+i]&part.pattern.mask[i]) !=
        (part.pattern.bytes[i]&part.pattern.mask[i])) return false;
  return true;
}
inline bool FindVoice(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kVoice0.pattern(), rva)) return false;
  return true;
}
inline bool FindPlay(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kPlay0.pattern(), rva)) return false;
  return true;
}
inline bool FindResource(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kResource0.pattern(), rva)) return false;
  if (!At(image, *rva, {0x232, kResource1.pattern()})) return false;
  if (!At(image, *rva, {0x463, kResource2.pattern()})) return false;
  if (!At(image, *rva, {0x697, kResource3.pattern()})) return false;
  if (!At(image, *rva, {0x8c7, kResource4.pattern()})) return false;
  if (!At(image, *rva, {0xaf8, kResource5.pattern()})) return false;
  return true;
}
inline bool FindFormatter(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kFormatter0.pattern(), rva)) return false;
  return true;
}
inline bool FindStringCtor(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kStringCtor0.pattern(), rva)) return false;
  return true;
}
inline bool FindOggCtor(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kOggCtor0.pattern(), rva)) return false;
  return true;
}
inline bool FindOggOpen(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kOggOpen0.pattern(), rva)) return false;
  return true;
}
inline bool FindCrtFormatter(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kCrtFormatter0.pattern(), rva)) return false;
  return true;
}
inline bool FindArchiveOpen(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kArchiveOpen0.pattern(), rva)) return false;
  return true;
}
inline bool FindArchiveRead(const exact_lookup::LoadedPeImage& image, uintptr_t* rva) {
  if (!siglus_family::Unique(image, kArchiveRead0.pattern(), rva)) return false;
  return true;
}

} // namespace siglus_legacy_resource

inline bool ResolveSiglusLegacyResourceMappingProfile(
    const exact_lookup::LoadedPeImage& image, uintptr_t proved_voice_entry,
    SiglusLegacyResourceMappingProfile* out) {
  using namespace siglus_legacy_resource;
  using siglus_resource::Calls;
  using siglus_resource::ImagePointer;
  using siglus_resource::WideLiteral;
  if (!out) return false;
  *out = {};
  if (!image.base || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 || !proved_voice_entry) return false;
  uintptr_t voice=0, play=0, resource=0, formatter=0, string_ctor=0;
  uintptr_t ogg_ctor=0, ogg=0, crt=0, archive=0, archive_read=0;
  if (!FindVoice(image, &voice) || voice != proved_voice_entry ||
      !FindPlay(image, &play) || !FindResource(image, &resource) ||
      !FindFormatter(image, &formatter) || !FindStringCtor(image, &string_ctor) ||
      !FindOggOpen(image, &ogg) || !FindArchiveOpen(image, &archive) ||
      !FindArchiveRead(image, &archive_read)) return false;
  // Several classes share this constructor prefix; CRT forwarding wrappers
  // can also be folded or duplicated. Follow the proved caller's actual edge,
  // validate that target ABI, then bind the constructor's vtable to unique Ogg.
  if (!siglus_legacy_glyph::CallTarget(image,resource+0x93b,&ogg_ctor) ||
      !At(image,ogg_ctor,{0,kOggCtor0.pattern()}) ||
      !siglus_legacy_glyph::CallTarget(image,formatter+0x73,&crt) ||
      !At(image,crt,{0,kCrtFormatter0.pattern()})) return false;
  // Instruction positions within independently found compiler routines. These
  // are neither old-image RVAs nor searches near a caller-supplied address.
  if (!Calls(image, voice+0x73, play) ||
      !Calls(image, play+0xb6, resource) ||
      !Calls(image, resource+0x28b, string_ctor) ||
      !Calls(image, resource+0x294, formatter) ||
      !Calls(image, formatter+0x73, crt) ||
      !Calls(image, resource+0x710, string_ctor) ||
      !Calls(image, resource+0x731, archive) ||
      !Calls(image, resource+0x7e0, archive_read) ||
      !Calls(image, resource+0x82d, archive_read) ||
      !Calls(image, resource+0x93b, ogg_ctor) ||
      !WideLiteral(image, resource+0x279, L"z%04d.ovk") ||
      !WideLiteral(image, resource+0x6fd, L"rb") ||
      !WideLiteral(image, ogg+0x33, L"rb")) return false;
  uintptr_t vtable=0, method=0;
  if (!ImagePointer(image, ogg_ctor+0x42, &vtable) ||
      !exact_lookup::SectionHasRole(
          exact_lookup::FindSectionForRva(image, vtable, 8),
          IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE) ||
      !ImagePointer(image, vtable+4, &method) || method != ogg) return false;
  out->voice_entry_rva=voice;
  out->play_entry_rva=play;
  out->resource_entry_rva=resource;
  out->resource_return_rva=play+0xbb;
  out->ogg_open_rva=ogg;
  out->payload_return_rva=resource+0x988;
  out->ogg_vtable_rva=vtable;
  return true;
}

struct SiglusLegacyVoiceSourceLayout {
  uint32_t payload_return = 0;
  uint32_t resource_return = 0;
  uint32_t ogg_vtable = 0;
};
struct SiglusLegacyVoiceSourceCall {
  uint32_t reader = 0;
  uint32_t entry_esp = 0;
  uint32_t original_edi = 0;
  uint32_t original_ebp = 0;
};
namespace siglus_legacy_resource {
struct SourceMetadata {
  // Every field is read twice across the bounded path copy. The callback must
  // report false for incomplete reads; no retry or previous snapshot is used.
  uint32_t values[12] = {};
  uint32_t text_union[7] = {};
};
template <typename Reader>
bool ReadMetadata(const SiglusLegacyVoiceSourceLayout& layout,
                  const SiglusLegacyVoiceSourceCall& call, Reader& read,
                  SourceMetadata* out) {
  auto& v=out->values;
  // Resource uses FPO: fixed 0x120-byte frame, then 3 pushes + CALL.
  // Saved Play EBX is a second key copy, only trusted when the Resource caller
  // is the independently proved Play call. EBP is payload length, not a frame.
  constexpr int32_t slots[]={0,0x130,0x134,0x20,0x48,0x40,4,8,12};
  for (size_t i=0;i<9;++i)
    if (!ReadSiglusVoiceSourceWord(read,call.entry_esp,slots[i],&v[i]))
      return false;
  if (v[0]!=layout.payload_return || v[1]!=layout.resource_return ||
      v[2]>INT32_MAX || v[2]!=v[3] || v[4]!=v[2]%100000u ||
      v[5]!=call.reader || v[6]!=call.entry_esp+0xc8u ||
      v[7]!=call.original_edi || v[8]!=call.original_ebp ||
      !v[7] || !v[8] || v[8]>UINT32_MAX-v[7] ||
      !ReadSiglusVoiceSourceWord(read,call.reader,0,&v[9]) ||
      v[9]!=layout.ogg_vtable) return false;
  // Record the original argument's path length/capacity and both pointer forms.
  if (!read(v[6],out->text_union,sizeof(out->text_union))) return false;
  v[10]=out->text_union[5];
  const uint32_t capacity=out->text_union[6];
  if (!v[10] || v[10]>=kSiglusVoiceSourcePathUnits ||
      v[10]>capacity || capacity<7 || capacity>INT32_MAX) return false;
  v[11]=capacity<8 ? v[6]+4 : out->text_union[1];
  const uint32_t bytes=(v[10]+1u)*sizeof(wchar_t);
  return v[11] && !(v[11]&1u) && v[11]<=UINT32_MAX-bytes;
}
} // namespace siglus_legacy_resource

// A source candidate from exactly the proved Resource -> OggOpen scope. This
// does not prove OggOpen succeeded, audio was played or any text occurrence.
// IO, canonical file/member verification and publication belong to the worker.
template <typename Reader>
bool CaptureSiglusLegacyVoiceSource(const SiglusLegacyVoiceSourceLayout& layout,
                                    const SiglusLegacyVoiceSourceCall& call,
                                    Reader& read, SiglusVoiceSourceTask* out) {
  static_assert(sizeof(wchar_t)==2,"Windows UTF-16 paths required");
  if (!out) return false;
  *out={};
  if (!layout.payload_return || !layout.resource_return || !layout.ogg_vtable ||
      !call.reader || !call.entry_esp || ((call.reader|call.entry_esp)&3u) ||
      call.entry_esp>UINT32_MAX-0x137u) return false;
  siglus_legacy_resource::SourceMetadata before{}, after{};
  if (!siglus_legacy_resource::ReadMetadata(layout,call,read,&before)) return false;
  SiglusVoiceSourceTask task;
  const auto& v=before.values;
  const uint32_t bytes=(v[10]+1u)*sizeof(wchar_t);
  if (!read(v[11],task.path,bytes) || task.path[v[10]]!=L'\0') return false;
  for (uint32_t i=0;i<v[10];++i) if (!task.path[i]) return false;
  if (!IsStableSiglusVoiceSourcePath(task.path,v[10])) return false;
  wchar_t final_path[kSiglusVoiceSourcePathUnits]={};
  if (!read(v[11],final_path,bytes) ||
      std::memcmp(task.path,final_path,bytes)!=0 ||
      !siglus_legacy_resource::ReadMetadata(layout,call,read,&after) ||
      std::memcmp(&before,&after,sizeof(before))!=0) return false;
  task.key=v[2]; task.offset=v[7]; task.length=v[8];
  *out=task;
  return true;
}
} // namespace fushi_voice_hook
