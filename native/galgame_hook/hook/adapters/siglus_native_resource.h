#pragma once

#include "siglus_resource_mapping.h"
#include "siglus_voice_source.h"

namespace fushi_voice_hook {
// This is a static source ABI capability. Actual path, file identity, archive
// member/range and bytes still need the worker's independent verification.
struct SiglusNativeResourceMappingProfile {
  uintptr_t voice_entry_rva = 0;
  uintptr_t resource_entry_rva = 0;
  uintptr_t archive_builder_rva = 0;
  uintptr_t ogg_open_rva = 0;
  uintptr_t payload_return_rva = 0;
  uintptr_t ogg_vtable_rva = 0;
  static constexpr uint32_t kVoiceKeyRadix = 100000u;
  static constexpr uint32_t kOvkResourceKind = 3u;
  static constexpr uint32_t ogg_callee_cleanup_bytes = 12u;
};
namespace siglus_native_resource {
using siglus_family::Signature;
// One independently measured NativeEcx compiler ABI. Only image addresses and
// direct call operands vary; registers, stack locals, arithmetic and branches
// remain exact. The request key's quotient formats z%04d.ovk, while remainder
// matches [row+8] in 16-byte rows; [row+4]/[row] supply offset/length.
// Signatures contain bounded instruction spans, not a module-RVA allowlist.
// Incoming EDX survives in EBX through Play and the owner+1f8 store.
inline constexpr Signature kVoice{
    "55 8B EC 83 EC 0C 89 4D F8 53 8B DA 56 57 85 C9 0F 84 29 01 00 00 8B 35 "
    "?? ?? ?? ?? 8B 45 0C 89 86 40 03 00 00 8B 45 10 89 86 44 03 00 00 E8 ?? "
    "?? ?? ?? E8 ?? ?? ?? ?? 8B 7D 08 8B CF E8 ?? ?? ?? ?? 84 C0 74 0A 80 7D "
    "24 00 75 04 B2 01 EB 02 32 D2 80 BE 55 03 00 00 00 A1 ?? ?? ?? ?? 88 55 "
    "FF 75 12 80 B8 41 01 00 00 00 75 09 80 B8 54 01 00 00 00 EB 07 80 B8 55 "
    "01 00 00 00 74 08 8B 88 58 01 00 00 EB 05 B9 64 00 00 00 80 F2 01 0F B6 "
    "C2 50 6A 00 FF 75 20 FF 75 18 FF 75 14 6A 00 51 8B 0D ?? ?? ?? ?? 57 53 "
    "8D 89 D8 00 00 00 E8 ?? ?? ?? ?? 8B 4D F8 8A 45 FF 8B 55 0C 8B 75 10 88 "
    "81 FC 01 00 00 8A 45 1C 88 81 FD 01 00 00 A1 ?? ?? ?? ?? 89 99 F8 01 00 "
    "00"};
inline constexpr Signature kPlay{
    "55 8B EC 83 E4 F8 51 80 7D 28 00 53 56 57 8B D9 75 0D 8B 8B A0 00 00 00 "
    "6A 01 E8 ?? ?? ?? ?? 8B 45 0C 32 C9 8B 75 08 89 83 B0 00 00 00 8A 45 24 "
    "89 B3 AC 00 00 00 88 83 B8 00 00 00 E8 ?? ?? ?? ?? FF 75 28 8B 8B A0 00 "
    "00 00 6A 00 FF 75 14 FF 75 10 6A 00 56 E8 ?? ?? ?? ??"};
// Dynamic aligned frame, saved original stack, key double copy, nonnegative
// key check and exact modulo 100000 arithmetic precede the path builder call.
inline constexpr Signature kResource{
    "53 8B DC 83 EC 08 83 E4 F8 83 C4 04 55 8B 6B 04 89 6C 24 04 8B EC 6A FF "
    "68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 53 81 EC 20 01 00 00 A1 ?? ?? ?? ?? "
    "33 C5 89 45 EC 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B F1 89 B5 DC FE FF "
    "FF 8A 4B 1C 8B 7B 08 89 BD 00 FF FF FF 84 C9 75 0A 8B CE E8 ?? ?? ?? ?? "
    "8A 4B 1C A1 ?? ?? ?? ?? 80 38 00 75 04 84 C9 75 04 85 FF 79 07 B0 01 E9 "
    "E7 10 00 00 B8 8F 58 8B 4F C7 85 FC FE FF FF 00 00 00 00 F7 E7 8B C7 8B "
    "CF 2B C2 D1 E8 03 C2 C1 E8 10 69 C0 A0 86 01 00 2B C8 A1 ?? ?? ?? ?? 83 "
    "C0 18 89 4D AC 50 8D 8D 08 FF FF FF E8 ?? ?? ?? ?? C7 45 FC 00 00 00 00 "
    "8D 4D 80 6A 03 0F 57 C0 C7 45 90 00 00 00 00 68 ?? ?? ?? ?? 0F 11 45 80 "
    "C7 45 94 00 00 00 00 E8 ?? ?? ?? ?? 8D 85 FC FE FF FF C6 45 FC 01 50 8D "
    "45 80 57 50 8D 95 08 FF FF FF 8D 8D 38 FF FF FF E8 ?? ?? ?? ?? 83 C4 0C"};
inline constexpr Signature kKind1{
    "8B 85 FC FE FF FF 83 F8 01 0F 85 36 01 00 00"};
inline constexpr Signature kKind2{"83 F8 02 0F 85 3B 01 00 00"};
inline constexpr Signature kArchive{
    "83 F8 03 0F 85 A2 03 00 00 0F 57 C0 C7 45 88 00 00 00 00 66 0F 13 45 90 "
    "68 ?? ?? ?? ?? 8D 4D B0 C6 45 FC 18 E8 ?? ?? ?? ?? 8D 45 B0 C6 45 FC 19 "
    "50 8D 85 38 FF FF FF 50 8D 4D 88 E8 ?? ?? ?? ?? 8D 4D B0 88 85 07 FF FF "
    "FF C6 45 FC 18 E8 ?? ?? ?? ?? 80 BD 07 FF FF FF 00 75 75"};
// Read count, allocate/read count*16, compare [row+8] with key remainder.
// The conditional equality edge leads to kMember in this same Resource body.
inline constexpr Signature kRows{
    "FF 75 88 BA 04 00 00 00 C7 85 7C FF FF FF FF FF FF FF 8D 8D FC FE FF FF "
    "C7 85 F8 FE FF FF 00 00 00 00 C7 85 FC FE FF FF 00 00 00 00 E8 ?? ?? ?? "
    "?? 8B 85 FC FE FF FF 83 C4 04 85 C0 0F 84 32 01 00 00 C7 45 BC 00 00 00 "
    "00 C7 45 C0 00 00 00 00 C7 45 C4 00 00 00 00 C1 E0 04 8D 4D BC 50 C6 45 "
    "FC 1E E8 ?? ?? ?? ?? 8B 95 FC FE FF FF 8B 45 BC FF 75 88 C1 E2 04 3B 45 "
    "C0 75 0E 33 C9 E8 ?? ?? ?? ?? 83 C4 04 33 C0 EB 0D 8B C8 E8 ?? ?? ?? ?? "
    "8B 45 BC 83 C4 04 8B 95 FC FE FF FF 33 C9 85 D2 7E 1C 66 90 8B 75 AC 39 "
    "70 08 8B B5 DC FE FF FF 0F 84 8B 00 00 00 41 83 C0 10 3B CA 7C E6"};
// Matched row offset/length locals feed the observed virtual slot-4 call.
// A prefetch request skips this call entirely; it cannot produce a source task.
inline constexpr Signature kMember{
    "8B 48 04 8B 00 89 8D 7C FF FF FF 89 85 F8 FE FF FF 83 F9 FF 0F 84 63 FF "
    "FF FF 8B 45 C0 8D 4D BC 39 45 BC 0F 45 45 BC 89 45 C0 C6 45 FC 18 E8 ?? "
    "?? ?? ?? 80 7B 1C 00 74 0C C6 85 07 FF FF FF 01 E9 29 01 00 00 6A 20 E8 "
    "?? ?? ?? ?? 83 C4 04 89 45 AC 6A 00 8B C8 C6 45 FC 24 E8 ?? ?? ?? ?? 50 "
    "8D 8D E4 FE FF FF C6 45 FC 18 E8 ?? ?? ?? ?? C6 45 FC 25 8D 95 38 FF FF "
    "FF 8B 8D E4 FE FF FF FF B5 F8 FE FF FF FF B5 7C FF FF FF 8B 01 52 8B 40 "
    "04 FF D0 84 C0 75 43 6A 0A 8B D7"};
// Capture output/root/key/type destinations and compute quotient /100000.
inline constexpr Signature kBuilder{
    "53 8B DC 83 EC 08 83 E4 F8 83 C4 04 55 8B 6B 04 89 6C 24 04 8B EC 6A FF "
    "68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 53 81 EC B0 00 00 00 A1 ?? ?? ?? ?? "
    "33 C5 89 45 EC 56 57 50 8D 45 F4 64 A3 00 00 00 00 89 95 4C FF FF FF 8B "
    "F1 89 B5 58 FF FF FF 89 B5 70 FF FF FF 8B 43 08 0F 57 C0 8B 53 0C B9 07 "
    "00 00 00 89 85 50 FF FF FF 8B 43 10 89 B5 44 FF FF FF 89 85 44 FF FF FF "
    "33 C0 0F 11 45 BC 89 95 48 FF FF FF C7 45 CC 00 00 00 00 89 8D 68 FF FF "
    "FF 89 4D D0 66 89 45 BC 89 45 FC 0F 11 45 D4 89 45 E4 89 4D E8 66 89 45 "
    "D4 B8 89 B5 F8 14 C6 45 FC 01 F7 EA C7 85 5C FF FF FF 00 00 00 00 C1 FA "
    "0D 8B C2 C1 E8 1F 03 C2 89 85 54 FF FF FF"};
// The complete kind-3 formatting and string-copy path, including inline/heap
// TextUnion copies, leads to the checked kind output and result copy below.
inline constexpr Signature kOvkBuild{
    "FF B5 54 FF FF FF 0F 57 C0 C7 85 60 FF FF FF 03 00 00 00 83 EC 18 8B CC "
    "89 8D 70 FF FF FF 6A 05 0F 11 01 68 ?? ?? ?? ?? C7 41 10 00 00 00 00 C7 "
    "41 14 00 00 00 00 E8 ?? ?? ?? ?? 8D 85 74 FF FF FF 50 E8 ?? ?? ?? ?? 83 "
    "C4 20 8D 4D BC C6 45 FC 09 3B C8 0F 84 1D 01 00 00 83 78 14 07 8B C8 89 "
    "85 6C FF FF FF 76 08 8B 08 89 8D 6C FF FF FF 8B 40 10 8B 7D D0 89 85 64 "
    "FF FF FF 89 BD 70 FF FF FF 3B C7 77 2A 83 BD 70 FF FF FF 07 8D 34 00 56 "
    "8D 7D BC 89 45 CC 0F 47 7D BC 51 57 E8 ?? ?? ?? ?? 83 C4 0C 33 C0 66 89 "
    "04 37 E9 C7 00 00 00 3D FE FF FF 7F 0F 87 A0 03 00 00 8B F0 83 CE 07 81 "
    "FE FE FF FF 7F 76 07 BE FE FF FF 7F EB 1E 8B CF B8 FE FF FF 7F D1 E9 2B "
    "C1 3B F8 76 07 BE FE FF FF 7F EB 08 8D 04 0F 3B F0 0F 42 F0 8D 46 01 89 "
    "85 70 FF FF FF 8D 85 70 FF FF FF 50 8D 45 BC 50 E8 ?? ?? ?? ?? 8B 8D 64 "
    "FF FF FF 89 75 D0 89 85 68 FF FF FF 89 4D CC 8D 34 09 56 FF B5 6C FF FF "
    "FF 50 E8 ?? ?? ?? ?? 8B 85 68 FF FF FF 33 C9 83 C4 14 66 89 0C 30 83 FF "
    "07 76 38 8B 4D BC 8D 3C 7D 02 00 00 00 8B C1 81 FF 00 10 00 00 72 14 8B "
    "48 FC 83 C7 23 2B C1 83 C0 FC 83 F8 1F 0F 87 F2 02 00 00 57 51 E8 ?? ?? "
    "?? ?? 8B 85 68 FF FF FF 83 C4 08 89 45 BC 8D 8D 74 FF FF FF C6 45 FC 02 "
    "E8 ?? ?? ?? ?? 6A 03 0F 57 C0 C7 45 B4 00 00 00 00 68 ?? ?? ?? ?? 8D 4D "
    "A4 C7 45 B8 00 00 00 00 0F 11 45 A4 E8 ?? ?? ?? ?? 8B 95 4C FF FF FF 8D "
    "45 A4 50 8D 45 BC C6 45 FC 0A 50 FF B5 50 FF FF FF 8D 45 8C 50 8D 8D 74 "
    "FF FF FF E8 ?? ?? ?? ?? 83 C4 10 8D 4D D4 C6 45 FC 0B 3B C8 0F 84 1D 01 "
    "00 00 83 78 14 07 8B C8 89 85 6C FF FF FF 76 08 8B 08 89 8D 6C FF FF FF "
    "8B 40 10 8B 7D E8 89 85 64 FF FF FF 89 BD 70 FF FF FF 3B C7 77 2A 83 BD "
    "70 FF FF FF 07 8D 34 00 56 8D 7D D4 89 45 E4 0F 47 7D D4 51 57 E8 ?? ?? "
    "?? ?? 83 C4 0C 33 C0 66 89 04 3E E9 C7 00 00 00 3D FE FF FF 7F 0F 87 17 "
    "02 00 00 8B F0 83 CE 07 81 FE FE FF FF 7F 76 07 BE FE FF FF 7F EB 1E 8B "
    "CF B8 FE FF FF 7F D1 E9 2B C1 3B F8 76 07 BE FE FF FF 7F EB 08 8D 04 0F "
    "3B F0 0F 42 F0 8D 46 01 89 85 70 FF FF FF 8D 85 70 FF FF FF 50 8D 45 D4 "
    "50 E8 ?? ?? ?? ?? 8B 8D 64 FF FF FF 89 75 E8 89 85 68 FF FF FF 89 4D E4 "
    "8D 34 09 56 FF B5 6C FF FF FF 50 E8 ?? ?? ?? ?? 8B 85 68 FF FF FF 33 C9 "
    "83 C4 14 66 89 0C 30 83 FF 07 76 38 8B 4D D4 8D 3C 7D 02 00 00 00 8B C1 "
    "81 FF 00 10 00 00 72 14 8B 48 FC 83 C7 23 2B C1 83 C0 FC 83 F8 1F 0F 87 "
    "69 01 00 00 57 51 E8 ?? ?? ?? ?? 8B 85 68 FF FF FF 83 C4 08 89 45 D4 8D "
    "8D 74 FF FF FF E8 ?? ?? ?? ?? C6 45 FC 02 8B 4D B8 83 F9 07 76 32 8B 55 "
    "A4 8D 0C 4D 02 00 00 00 8B C2 81 F9 00 10 00 00 72 14 8B 50 FC 83 C1 23 "
    "2B C2 83 C0 FC 83 F8 1F 0F 87 17 01 00 00 51 52 E8 ?? ?? ?? ?? 83 C4 08 "
    "83 7D E8 07 8D 45 D4 0F 47 45 D4 50 FF 15 ?? ?? ?? ?? 83 F8 FF 74 04 A8 "
    "10 74 7C"};
inline constexpr Signature kBuilderResult{
    "8B 8D 44 FF FF FF 85 C9 74 08 8B 85 60 FF FF FF 89 01 8B 8D 58 FF FF FF "
    "8D 45 D4 50 E8 ?? ?? ?? ??"};
inline constexpr Signature kConcat{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC BC 00 00 00 A1 "
    "?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B C1 "
    "89 85 40 FF FF FF 89 85 3C FF FF FF 8B 75 08 8D 8D 48 FF FF FF 8B 7D 0C "
    "8B 5D 10 89 85 3C FF FF FF 8B 45 14 68 ?? ?? ?? ?? 89 85 44 FF FF FF E8 "
    "?? ?? ?? ?? 83 C4 04 56 8B D0 C7 45 FC 00 00 00 00 8D 8D 60 FF FF FF E8 "
    "?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 01 8D 8D 78 FF FF FF "
    "E8 ?? ?? ?? ?? 83 C4 04 57 8B D0 C6 45 FC 02 8D 4D 90 E8 ?? ?? ?? ?? 83 "
    "C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 03 8D 4D A8 E8 ?? ?? ?? ?? 83 C4 04 "
    "53 8B D0 C6 45 FC 04 8D 4D C0 E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B "
    "D0 C6 45 FC 05 8D 4D D8 E8 ?? ?? ?? ?? 83 C4 04 FF B5 44 FF FF FF 8B 8D "
    "40 FF FF FF 8B D0 C6 45 FC 06 E8 ?? ?? ?? ?? 83 C4 04"};
inline constexpr Signature kFormatter{
    "53 8B DC 83 EC 08 83 E4 F8 83 C4 04 55 8B 6B 04 89 6C 24 04 8B EC 6A FF "
    "68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 53 81 EC 14 08 00 00 A1 ?? ?? ?? ?? "
    "33 C5 89 45 EC 56 50 8D 45 F4 64 A3 00 00 00 00 8B 73 08 89 B5 E4 F7 FF "
    "FF C7 45 FC 00 00 00 00 8D 4B 24 83 7B 20 07 8D 43 0C 51 0F 47 43 0C 6A "
    "00 50 8D 85 E8 F7 FF FF 68 00 04 00 00 50 E8 ?? ?? ?? ?? 0F 57 C0 8D 8D "
    "E8 F7 FF FF 0F 11 06 83 C4 14 C7 46 10 00 00 00 00 C7 46 14 00 00 00 00 "
    "8D 51 02 66 8B 01 83 C1 02 66 85 C0 75 F5 2B CA 8D 85 E8 F7 FF FF D1 F9 "
    "51 50 8B CE E8 ?? ?? ?? ?? 8D 4B 0C E8 ?? ?? ?? ?? 8B C6 8B 4D F4 64 89 "
    "0D 00 00 00 00 59 5E 8B 4D EC 33 CD E8 ?? ?? ?? ?? 8B E5 5D 8B E3 5B C3"};
inline constexpr Signature kCrtFormat{
    "55 8B EC 83 E4 F8 FF 75 18 FF 75 14 FF 75 10 FF 75 0C FF 75 08 E8 ?? ?? "
    "?? ?? FF 70 04 FF 30 E8 ?? ?? ?? ?? 83 C9 FF 83 C4 1C 85 C0 0F 48 C1 8B "
    "E5 5D C3"};
inline constexpr Signature kAssign{
    "55 8B EC 51 53 8B 5D 0C 56 57 8B F9 89 7D FC 81 FB FE FF FF 7F 0F 87 88 "
    "00 00 00 83 FB 07 77 29 8D 34 1B 89 5F 10 56 FF 75 08 C7 47 14 07 00 00 "
    "00 57 E8 ?? ?? ?? ?? 83 C4 0C 33 C0 66 89 04 3E 5F 5E 5B 8B E5 5D C2 08 "
    "00 8B F3 83 CE 07 81 FE FE FF FF 7F 76 07 BE FE FF FF 7F EB 0A B8 0A 00 "
    "00 00 3B F0 0F 42 F0 8D 46 01 89 45 0C 8D 45 0C 50 57 E8 ?? ?? ?? ?? 8B "
    "F8 8B 45 FC 89 70 14 8D 34 1B 56 FF 75 08 89 38 57 89 58 10 E8 ?? ?? ?? "
    "?? 83 C4 14 33 C0 66 89 04 3E 5F 5E 5B 8B E5 5D C2 08 00 E8 ?? ?? ?? ??"};
inline constexpr Signature kOggCtor{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 18 53 56 57 A1 "
    "?? ?? ?? ?? 33 C5 50 8D 45 F4 64 A3 00 00 00 00 8B F1 89 75 E4 C7 46 04 "
    "00 00 00 00 C7 46 08 00 00 00 00 C7 46 0C 00 00 00 00 C7 46 10 00 00 00 "
    "00 C7 45 FC 00 00 00 00 C7 06 ?? ?? ?? ??"};
// Complete thiscall open body: path TextUnion, offset/length state, FILE
// stream, Ogg callbacks, error paths and ret 0xc. Existing detours fail this
// install gate.
inline constexpr Signature kOggOpen{
    "55 8B EC 83 EC 30 56 8B F1 8B 06 FF 50 08 8B 56 14 8B 45 0C 89 82 D4 02 "
    "00 00 8B 45 08 83 78 14 07 76 02 8B 00 68 ?? ?? ?? ?? 50 8B 46 14 05 D0 "
    "02 00 00 50 E8 ?? ?? ?? ?? 8B 4E 14 83 C4 0C 83 B9 D0 02 00 00 00 74 78 "
    "8B 45 10 89 81 D8 02 00 00 8B 46 14 6A 00 FF B0 D4 02 00 00 FF B0 D0 02 "
    "00 00 E8 ?? ?? ?? ?? 8B 4E 14 51 8B C4 C7 45 F0 ?? ?? ?? ?? C7 45 F4 ?? "
    "?? ?? ?? C7 45 F8 ?? ?? ?? ?? C7 45 FC ?? ?? ?? ?? 0F 10 45 F0 6A 00 6A "
    "00 0F 11 00 51 8D 81 D0 02 00 00 50 E8 ?? ?? ?? ?? 8B 4E 14 83 C4 20 85 "
    "C0 79 1E FF B1 D0 02 00 00 E8 ?? ?? ?? ?? 83 C4 04 8B CE E8 ?? ?? ?? ?? "
    "32 C0 5E 8B E5 5D C2 0C 00 51 E8 ?? ?? ?? ?? 83 C4 04 85 C0 75 10 8B 06 "
    "8B CE FF 50 08 32 C0 5E 8B E5 5D C2 0C 00 6A FF FF 76 14 E8 ?? ?? ?? ?? "
    "6A FF FF 76 14 0F 10 00 0F 11 45 F0 0F 10 40 10 0F 11 45 E0 E8 ?? ?? ?? "
    "?? 0F 10 4D F0 83 C4 10 C7 46 08 10 00 00 00 0F 28 C1 66 0F 73 D9 08 66 "
    "0F 73 D8 04 66 0F 7E C2 66 0F 7E 4E 0C 89 56 04 0F AF D0 B0 01 03 D2 89 "
    "56 10 5E 8B E5 5D C2 0C 00"};
// Full scalar/SIMD byte transform and count-return ABI of the actual callback.
inline constexpr Signature kOggRead{
    "55 8B EC 53 8B 5D 14 56 8B 75 08 57 FF 33 8B 7D 0C FF 75 10 57 56 E8 ?? "
    "?? ?? ?? 8B C8 89 45 14 0F AF CF 83 C4 10 33 D2 85 C9 0F 8E 91 00 00 00 "
    "83 F9 40 72 73 0F BE 43 0C 8D 7B 0C 66 0F 6E C0 8D 46 FF 66 0F 60 C0 03 "
    "C1 66 0F 61 C0 66 0F 70 C8 00 3B F7 77 04 3B C7 73 4E 8B C1 25 3F 00 00 "
    "80 79 05 48 83 C8 C0 40 8B F9 2B F8 0F 1F 40 00 0F 10 06 83 C2 40 0F 57 "
    "C1 0F 11 06 0F 10 46 10 0F 57 C1 0F 11 46 10 0F 10 46 20 0F 57 C1 0F 11 "
    "46 20 0F 10 46 30 0F 57 C1 0F 11 46 30 83 C6 40 3B D7 7C CC 3B D1 7D 16 "
    "2B CA 66 0F 1F 44 00 00 8A 43 0C 8D 76 01 30 46 FF 83 E9 01 75 F2 8B 45 "
    "14 5F 5E 5B 5D C3"};
inline constexpr Signature kArchiveOpen{
    "53 8B DC 83 EC 08 83 E4 F8 83 C4 04 55 8B 6B 04 89 6C 24 04 8B EC 6A FF "
    "68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 53 83 EC 58 A1 ?? ?? ?? ?? 33 C5 89 "
    "45 EC 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B F1 8B 43 0C 8B 7B 08 89 45 "
    "A0 E8 ?? ?? ?? ?? 84 C0 74 73"};
inline constexpr Signature kArchiveRead{
    "53 8B DC 83 EC 08 83 E4 F8 83 C4 04 55 8B 6B 04 89 6C 24 04 8B EC 6A FF "
    "68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 53 83 EC 38 A1 ?? ?? ?? ?? 33 C5 89 "
    "45 EC 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B F2 89 4D B8 8B 7B 08 E8 ?? "
    "?? ?? ?? 85 FF"};

inline constexpr Signature kCopyUnion{
    "55 8B EC 51 53 8B 5D 08 0F 57 C0 56 8B F1 89 5D 08 89 75 FC 8B C3 0F 11 "
    "06 C7 46 10 00 00 00 00 C7 46 14 00 00 00 00 83 7B 14 07 76 05 8B 03 89 "
    "45 08 8B 5B 10 81 FB FE FF FF 7F 77 75 83 FB 07 77 1A 89 5E 10 C7 46 14 "
    "07 00 00 00 0F 10 00 8B C6 0F 11 06 5E 5B 8B E5 5D C2 04 00 57 8B FB 83 "
    "CF 07 81 FF FE FF FF 7F 76 07 BF FE FF FF 7F EB 0A B8 0A 00 00 00 3B F8 "
    "0F 42 F8 8D 47 01 89 45 FC 8D 45 FC 50 56 E8 ?? ?? ?? ?? 8D 0C 5D 02 00 "
    "00 00 89 06 51 FF 75 08 89 5E 10 50 89 7E 14 E8 ?? ?? ?? ?? 83 C4 14 8B "
    "C6 5F 5E 5B 8B E5 5D C2 04 00 E8 ?? ?? ?? ??"};
inline bool At(const exact_lookup::LoadedPeImage &image, uintptr_t start,
               uintptr_t offset, const exact_lookup::MaskedPattern &pattern) {
  return offset <= image.size && start < image.size - offset &&
         siglus_family::ExecutableSpan(image, start + offset, pattern.size) &&
         exact_lookup::MatchesMaskedPattern(image.base + start + offset,
                                            pattern);
}
} // namespace siglus_native_resource

// The independent NativeEcx message proof supplies voice_entry. No filename,
// module hash or previously observed RVA can admit this optional audio source.
inline bool ResolveSiglusNativeResourceMappingProfile(
    const exact_lookup::LoadedPeImage &image, uintptr_t voice_entry,
    SiglusNativeResourceMappingProfile *out) {
  using namespace siglus_native_resource;
  using siglus_family::Unique;
  using siglus_resource::Calls;
  using siglus_resource::WideLiteral;
  if (out == nullptr)
    return false;
  *out = {};
  if (!image.base || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u || voice_entry == 0)
    return false;
  uintptr_t voice = 0, play = 0, resource = 0, builder = 0, concat = 0,
            formatter = 0;
  uintptr_t crt = 0, assign = 0, ctor = 0, ogg = 0, read = 0, archive = 0,
            archive_read = 0, copy = 0;
  if (!Unique(image, kVoice.pattern(), &voice) || voice != voice_entry ||
      !Unique(image, kPlay.pattern(), &play) ||
      !Unique(image, kResource.pattern(), &resource) ||
      !Unique(image, kBuilder.pattern(), &builder) ||
      !Unique(image, kConcat.pattern(), &concat) ||
      !Unique(image, kFormatter.pattern(), &formatter) ||
      !Unique(image, kAssign.pattern(), &assign) ||
      !Unique(image, kCopyUnion.pattern(), &copy) ||
      !Unique(image, kOggCtor.pattern(), &ctor) ||
      !Unique(image, kOggOpen.pattern(), &ogg) ||
      !Unique(image, kOggRead.pattern(), &read) ||
      !Unique(image, kArchiveOpen.pattern(), &archive) ||
      !Unique(image, kArchiveRead.pattern(), &archive_read))
    return false;
  // The linker can retain two identical CRT forwarding thunks. Follow this
  // formatter's actual call, then require its whole thunk ABI at that target.
  uintptr_t crt_address = 0;
  if (!exact_lookup::DecodeRel32CallTarget(image.base + formatter + 0x6e,
                                           &crt_address) ||
      crt_address < reinterpret_cast<uintptr_t>(image.base))
    return false;
  crt = crt_address - reinterpret_cast<uintptr_t>(image.base);
  if (!At(image, crt, 0, kCrtFormat.pattern()))
    return false;
  // These offsets are instruction positions in the independently located
  // compiler ABI, never offsets from an old module address. The three kind
  // dispatch branches are exact and lead to the checked kind-3 archive body.
  if (!At(image, resource, 0x2a3, kKind1.pattern()) ||
      !At(image, resource, 0x3e8, kKind2.pattern()) ||
      !At(image, resource, 0x52c, kArchive.pattern()) ||
      !At(image, resource, 0x5fc, kRows.pattern()) ||
      !At(image, resource, 0x73d, kMember.pattern()) ||
      !At(image, builder, 0x961, kOvkBuild.pattern()) ||
      !At(image, builder, 0xd7a, kBuilderResult.pattern()) ||
      !Calls(image, voice + 0xae, play) ||
      !Calls(image, play + 0x55, resource) ||
      !Calls(image, resource + 0x100, builder) ||
      !Calls(image, resource + 0xdf, assign) ||
      !Calls(image, resource + 0xb4, copy) ||
      !Calls(image, builder + 0xd96, copy) ||
      !Calls(image, builder + 0x997, assign) ||
      !Calls(image, builder + 0xb05, assign) ||
      !Calls(image, builder + 0x9a3, formatter) ||
      !Calls(image, builder + 0xb2c, concat) ||
      !Calls(image, formatter + 0x6e, crt) ||
      !Calls(image, formatter + 0xac, assign) ||
      !Calls(image, resource + 0x567, archive) ||
      !Calls(image, resource + 0x628, archive_read) ||
      !Calls(image, resource + 0x679, archive_read) ||
      !Calls(image, resource + 0x687, archive_read) ||
      !Calls(image, resource + 0x797, ctor) ||
      !WideLiteral(image, resource + 0xd0, L"koe") ||
      !WideLiteral(image, builder + 0x985, L"z%04d") ||
      !WideLiteral(image, builder + 0xaf3, L"ovk") ||
      !WideLiteral(image, concat + 0x55, L"\\") ||
      !WideLiteral(image, concat + 0x80, L"\\") ||
      !WideLiteral(image, concat + 0xab, L"\\") ||
      !WideLiteral(image, concat + 0xd3, L".") ||
      !WideLiteral(image, resource + 0x545, L"rb") ||
      !WideLiteral(image, ogg + 0x26, L"rb"))
    return false;
  uintptr_t vtable = 0, method = 0, callback = 0;
  if (!siglus_resource::ImagePointer(image, ctor + 0x52, &vtable) ||
      !exact_lookup::SectionHasRole(
          exact_lookup::FindSectionForRva(image, vtable, 8), IMAGE_SCN_MEM_READ,
          IMAGE_SCN_MEM_EXECUTE) ||
      !siglus_resource::ImagePointer(image, vtable + 4, &method) ||
      method != ogg ||
      !siglus_resource::ImagePointer(image, ogg + 0x70, &callback) ||
      callback != read)
    return false;
  out->voice_entry_rva = voice;
  out->resource_entry_rva = resource;
  out->archive_builder_rva = builder;
  out->ogg_open_rva = ogg;
  out->payload_return_rva = resource + 0x7d0;
  out->ogg_vtable_rva = vtable;
  return true;
}

struct SiglusNativeVoiceSourceLayout {
  uint32_t payload_return = 0;
  uint32_t ogg_vtable = 0;
};
struct SiglusNativeVoiceSourceCall {
  uint32_t reader = 0;
  uint32_t entry_esp = 0;
  uint32_t caller_ebp = 0;
  uint32_t original_ebx = 0;
};

// original EBX is Resource's saved entry stack, not the payload length.
// EBP=(Resource entryESP-12)&~7, [EBP-10]=EBX=entryESP-4.
// Both legal original stack alignments are accepted, without caching an owner,
// caller address, stack address, voice ID, elapsed time or current directory.
template <typename Reader>
bool CaptureSiglusNativeVoiceSource(const SiglusNativeVoiceSourceLayout &layout,
                                    const SiglusNativeVoiceSourceCall &call,
                                    Reader &read, SiglusVoiceSourceTask *out) {
  static_assert(sizeof(wchar_t) == 2, "Windows UTF-16 paths required");
  if (!out || !layout.payload_return || !layout.ogg_vtable || !call.reader ||
      !call.entry_esp || call.entry_esp >= call.caller_ebp ||
      call.original_ebx < 8 || call.original_ebx > UINT32_MAX - 12 ||
      ((call.entry_esp | call.caller_ebp | call.original_ebx) & 3u) != 0 ||
      call.caller_ebp != ((call.original_ebx - 8u) & ~7u))
    return false;
  uint32_t caller = 0, saved_stack = 0, key = 0, copy = 0, reader = 0,
           vtable = 0;
  uint32_t path = 0, expected_path = 0, offset = 0, length = 0,
           frame_offset = 0, frame_length = 0;
  if (!ReadSiglusVoiceSourceWord(read, call.entry_esp, 0, &caller) ||
      caller != layout.payload_return ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp, -0x10, &saved_stack) ||
      saved_stack != call.original_ebx ||
      !ReadSiglusVoiceSourceWord(read, call.original_ebx, 8, &key) ||
      key > INT32_MAX ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp, -0x100, &copy) ||
      copy != key ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp, -0x11c, &reader) ||
      reader != call.reader ||
      !ReadSiglusVoiceSourceWord(read, reader, 0, &vtable) ||
      vtable != layout.ogg_vtable ||
      !ReadSiglusVoiceSourceWord(read, call.entry_esp, 4, &path) ||
      !SiglusVoiceSourceAddress(call.caller_ebp, -0xc8, &expected_path) ||
      path != expected_path ||
      !ReadSiglusVoiceSourceWord(read, call.entry_esp, 8, &offset) ||
      !ReadSiglusVoiceSourceWord(read, call.entry_esp, 12, &length) ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp, -0x84, &frame_offset) ||
      !ReadSiglusVoiceSourceWord(read, call.caller_ebp, -0x108,
                                 &frame_length) ||
      offset != frame_offset || length != frame_length || offset == 0 ||
      length == 0 || length > UINT32_MAX - offset)
    return false;
  uint32_t text_union[6] = {};
  if (path > UINT32_MAX - sizeof(text_union) ||
      !read(path, text_union, sizeof(text_union)))
    return false;
  const uint32_t units = text_union[4], capacity = text_union[5];
  if (!units || units >= kSiglusVoiceSourcePathUnits || units > capacity)
    return false;
  const uint32_t characters = capacity < 8 ? path : text_union[0];
  const uint32_t bytes = (units + 1) * sizeof(wchar_t);
  if (!characters || characters > UINT32_MAX - bytes)
    return false;
  SiglusVoiceSourceTask task;
  if (!read(characters, task.path, bytes) || task.path[units] != L'\0')
    return false;
  for (uint32_t i = 0; i < units; ++i)
    if (task.path[i] == L'\0')
      return false;
  if (!IsStableSiglusVoiceSourcePath(task.path, units))
    return false;
  uint32_t final_union[6] = {};
  if (!read(path, final_union, sizeof(final_union)) ||
      std::memcmp(text_union, final_union, sizeof(text_union)) != 0)
    return false;
  task.key = key;
  task.offset = offset;
  task.length = length;
  *out = task;
  return true;
}
} // namespace fushi_voice_hook
