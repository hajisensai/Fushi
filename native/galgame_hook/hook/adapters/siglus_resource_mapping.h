#pragma once

#include "siglus_autoprofile.h"

namespace fushi_voice_hook {

// Static mapping capability only. A request can still select a loose WAV/NWA.
// Callers must bind only an actually observed OVK canonical file + file identity;
// never derive a resource root from the installation path or basename alone.
struct SiglusResourceMappingProfile {
  uintptr_t voice_entry_rva = 0;
  uintptr_t resource_entry_rva = 0;
  uintptr_t archive_builder_rva = 0;
  uintptr_t ovk_path_return_rva = 0;
  uintptr_t archive_open_rva = 0;
  uintptr_t archive_open_return_rva = 0;
  uintptr_t archive_read_rva = 0;
  uintptr_t archive_header_return_rva = 0;
  uintptr_t archive_table_return_rva = 0;
  uintptr_t ogg_open_rva = 0;
  uintptr_t payload_return_rva = 0;
  uintptr_t ogg_vtable_rva = 0;
  uintptr_t ogg_read_rva = 0;
  // Caller EBP belongs to Resource, callee entryESP belongs to OggOpen.
  // The path is a pointer to a 0x18-byte UTF-16 TextUnion, not wchar_t*.
  static constexpr int32_t resource_key_frame_offset = 8;
  static constexpr int32_t resource_key_copy_frame_displacement = -0x128;
  static constexpr int32_t resource_path_frame_displacement = -0xb8;
  static constexpr int32_t resource_reader_frame_displacement = -0x30;
  static constexpr uint32_t ogg_path_argument_offset = 4u;
  static constexpr uint32_t ogg_offset_argument_offset = 8u;
  static constexpr uint32_t ogg_length_argument_offset = 12u;
  static constexpr uint32_t ogg_callee_cleanup_bytes = 12u;
  static constexpr uint32_t kVoiceKeyRadix = 100000u;
  static constexpr uint32_t kOvkResourceKind = 3u;
};

namespace siglus_resource {
using siglus_family::Signature;
// These are complete instruction spans for one measured x86 compiler family.
// Only relocatable addresses/calls are masked. Branches, registers, locals and
// arithmetic stay exact: isolated divisor/string hits cannot admit a profile.
// Unknown layouts and duplicate candidates fail closed. No title/hash/RVA gate.

// ECX owner is saved; incoming EDX key is saved in EBX, passed unchanged to
// Play and finally stored at owner+1f8. The whole intervening branch body is checked.
inline constexpr Signature kVoiceRequest{
    "55 8B EC 83 EC 10 89 4D F4 53 8B DA 56 57 85 C9 0F 84 03 01 00 00 8B 35 "
    "?? ?? ?? ?? 8B 45 0C 89 86 40 03 00 00 8B 45 10 89 86 44 03 00 00 E8 ?? "
    "?? ?? ?? E8 ?? ?? ?? ?? 8B 7D 08 8B CF E8 ?? ?? ?? ?? 80 BE 55 03 00 00 "
    "00 8B 0D ?? ?? ?? ?? 88 45 FB 75 12 80 B9 41 01 00 00 00 75 09 80 B9 54 "
    "01 00 00 00 EB 07 80 B9 55 01 00 00 00 74 08 8B 89 58 01 00 00 EB 05 B9 "
    "64 00 00 00 84 C0 0F 94 C0 0F B6 C0 50 6A 00 FF 75 20 FF 75 18 FF 75 14 "
    "6A 00 51 8B 0D ?? ?? ?? ?? 57 53 8D 89 D8 00 00 00 E8 ?? ?? ?? ?? 8B 4D "
    "F4 8A 45 FB 88 81 FC 01 00 00 8A 45 1C 88 81 FD 01 00 00 A1 ?? ?? ?? ?? "
    "89 99 F8 01 00 00"};

// The first stack argument is preserved in ESI and passed to Resource.
inline constexpr Signature kPlay{
    "55 8B EC 51 56 57 8B F9 6A 01 8B 8F A0 00 00 00 E8 ?? ?? ?? ?? 8B 45 0C "
    "32 C9 8B 75 08 89 87 B0 00 00 00 8A 45 24 89 B7 AC 00 00 00 88 87 B8 00 "
    "00 00 E8 ?? ?? ?? ?? FF 75 28 8B 8F A0 00 00 00 6A 00 FF 75 14 FF 75 10 "
    "6A 00 56 E8 ?? ?? ?? ??"};

// Entry through the OVK member match, including intervening loose-type branches:
// EDI=input key; signed key rejection; key - (key/100000)*100000 -> [ebp-104].
// Builder writes kind to [ebp-108]; ESI retains that kind through dispatch.
// Only kind 3 reaches archive table [row+8]==remainder with stride 0x10.
// The found row supplies offset [row+4] and length [row]. No fourth-DWORD ID.
inline constexpr Signature kResource{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 1C 01 00 00 A1 "
    "?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 89 8D "
    "DC FE FF FF 8B 7D 08 89 BD D8 FE FF FF E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 8A "
    "5D 1C 80 38 00 75 0B 84 DB 74 07 B0 01 E9 8B 0E 00 00 85 FF 78 F5 B8 89 "
    "B5 F8 14 C7 85 F8 FE FF FF 00 00 00 00 F7 EF 8B CF C7 85 14 FF FF FF 07 "
    "00 00 00 C1 FA 0D 8B C2 C7 85 10 FF FF FF 00 00 00 00 C1 E8 1F 03 C2 69 "
    "C0 A0 86 01 00 6A FF 2B C8 A1 ?? ?? ?? ?? 89 8D FC FE FF FF 83 C0 18 33 "
    "C9 51 66 89 8D 00 FF FF FF 8D 8D 00 FF FF FF 50 E8 ?? ?? ?? ?? C7 45 FC "
    "00 00 00 00 8D 8D 30 FF FF FF 6A 03 33 C0 C7 85 44 FF FF FF 07 00 00 00 "
    "68 ?? ?? ?? ?? C7 85 40 FF FF FF 00 00 00 00 66 89 85 30 FF FF FF E8 ?? "
    "?? ?? ?? 8D 85 F8 FE FF FF C6 45 FC 01 50 8D 85 30 FF FF FF 57 50 8D 95 "
    "00 FF FF FF 8D 8D 48 FF FF FF E8 ?? ?? ?? ?? 83 C4 0C C6 45 FC 03 83 BD "
    "44 FF FF FF 08 72 0E FF B5 30 FF FF FF E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 "
    "85 44 FF FF FF 07 00 00 00 C7 85 40 FF FF FF 00 00 00 00 66 89 85 30 FF "
    "FF FF 39 85 58 FF FF FF 0F 85 AD 00 00 00 51 8B D7 8D 4D C0 E8 ?? ?? ?? "
    "?? 83 C4 04 50 BA ?? ?? ?? ?? C6 45 FC 04 8D 4D D8 E8 ?? ?? ?? ?? 83 C4 "
    "04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 05 8D 4D A8 E8 ?? ?? ?? ?? 83 C4 04 50 "
    "C6 45 FC 06 8B 0D ?? ?? ?? ?? 6A 0C E8 ?? ?? ?? ?? 83 7D BC 08 72 0B FF "
    "75 A8 E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 45 BC 07 00 00 00 83 7D EC 08 C7 "
    "45 B8 00 00 00 00 66 89 45 A8 72 0B FF 75 D8 E8 ?? ?? ?? ?? 83 C4 04 33 "
    "C0 C7 45 EC 07 00 00 00 83 7D D4 08 C7 45 E8 00 00 00 00 66 89 45 D8 72 "
    "0B FF 75 C0 E8 ?? ?? ?? ?? 83 C4 04 32 DB E9 8D 0C 00 00 8B B5 F8 FE FF "
    "FF 83 FE 03 74 0B 84 DB 74 07 B3 01 E9 77 0C 00 00 6A 28 E8 ?? ?? ?? ?? "
    "83 C4 04 85 C0 74 09 8B C8 E8 ?? ?? ?? ?? EB 02 33 C0 89 85 E8 FE FF FF "
    "C7 85 EC FE FF FF 00 00 00 00 8D 8D EC FE FF FF C6 45 FC 07 51 8B D0 8D "
    "8D E8 FE FF FF E8 ?? ?? ?? ?? 83 C4 04 6A 20 C6 45 FC 08 E8 ?? ?? ?? ?? "
    "83 C4 04 85 C0 74 09 8B C8 E8 ?? ?? ?? ?? EB 02 33 C0 89 85 E0 FE FF FF "
    "C7 85 E4 FE FF FF 00 00 00 00 8D 8D E4 FE FF FF C6 45 FC 09 51 8B D0 8D "
    "8D E0 FE FF FF E8 ?? ?? ?? ?? 83 C4 04 C6 45 FC 0A 83 FE 01 0F 85 3D 01 "
    "00 00 68 AC 00 00 00 E8 ?? ?? ?? ?? 83 C4 04 85 C0 74 09 8B C8 E8 ?? ?? "
    "?? ?? EB 02 33 C0 50 8D 4D D0 E8 ?? ?? ?? ?? C6 45 FC 0B 8D 95 48 FF FF "
    "FF 8B 4D D0 6A 00 6A 00 52 8B 01 8B 40 04 FF D0 84 C0 75 62 51 8B D7 8D "
    "4D 90 E8 ?? ?? ?? ?? 83 C4 04 50 BA ?? ?? ?? ?? C6 45 FC 0C 8D 4D D8 E8 "
    "?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 0D 8D 4D A8 E8 ?? ?? "
    "?? ?? 83 C4 04 50 C6 45 FC 0E 8B 0D ?? ?? ?? ?? 6A 0C E8 ?? ?? ?? ?? 8D "
    "4D A8 8A D8 E8 ?? ?? ?? ?? 8D 4D D8 E8 ?? ?? ?? ?? 8D 4D 90 EB 72 FF 75 "
    "D0 8B 8D E8 FE FF FF E8 ?? ?? ?? ?? 84 C0 75 76 51 8B D7 8D 4D D8 E8 ?? "
    "?? ?? ?? 83 C4 04 50 BA ?? ?? ?? ?? C6 45 FC 0F 8D 4D A8 E8 ?? ?? ?? ?? "
    "83 C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 10 8D 4D 90 E8 ?? ?? ?? ?? 83 C4 "
    "04 50 C6 45 FC 11 8B 0D ?? ?? ?? ?? 6A 02 E8 ?? ?? ?? ?? 8D 4D 90 8A D8 "
    "E8 ?? ?? ?? ?? 8D 4D A8 E8 ?? ?? ?? ?? 8D 4D D8 E8 ?? ?? ?? ?? 8D 4D D0 "
    "C6 45 FC 0A E8 ?? ?? ?? ?? E9 4C 0A 00 00 8D 4D D0 C6 45 FC 0A E8 ?? ?? "
    "?? ?? E9 C4 04 00 00 83 FE 02 0F 85 28 01 00 00 6A 1C E8 ?? ?? ?? ?? 83 "
    "C4 04 89 85 FC FE FF FF C6 45 FC 12 85 C0 74 09 8B C8 E8 ?? ?? ?? ?? EB "
    "02 33 C0 50 8D 4D D0 C6 45 FC 0A E8 ?? ?? ?? ?? C6 45 FC 13 8D 95 48 FF "
    "FF FF 8B 4D D0 6A 00 6A 00 52 8B 01 8B 40 04 FF D0 84 C0 75 42 51 8B D7 "
    "8D 4D D8 E8 ?? ?? ?? ?? 83 C4 04 50 BA ?? ?? ?? ?? C6 45 FC 14 8D 4D A8 "
    "E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 15 8D 4D 90 E8 ?? "
    "?? ?? ?? 83 C4 04 50 C6 45 FC 16 6A 0C EB 52 FF 75 D0 8B 8D E8 FE FF FF "
    "E8 ?? ?? ?? ?? 84 C0 75 76 51 8B D7 8D 4D D8 E8 ?? ?? ?? ?? 83 C4 04 50 "
    "BA ?? ?? ?? ?? C6 45 FC 17 8D 4D A8 E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? "
    "?? 8B D0 C6 45 FC 18 8D 4D 90 E8 ?? ?? ?? ?? 83 C4 04 50 C6 45 FC 19 6A "
    "02 8B 0D ?? ?? ?? ?? E8 ?? ?? ?? ?? 8D 4D 90 8A D8 E8 ?? ?? ?? ?? 8D 4D "
    "A8 E8 ?? ?? ?? ?? 8D 4D D8 E8 ?? ?? ?? ?? 8D 4D D0 C6 45 FC 0A E8 ?? ?? "
    "?? ?? E9 1B 09 00 00 8D 4D D0 C6 45 FC 0A E8 ?? ?? ?? ?? E9 93 03 00 00 "
    "83 FE 03 0F 85 8A 03 00 00 0F 57 C0 C7 45 B0 00 00 00 00 66 0F 13 45 B8 "
    "C6 45 FC 1A 8D 4D D8 6A 02 33 C0 C7 45 EC 07 00 00 00 68 ?? ?? ?? ?? C7 "
    "45 E8 00 00 00 00 66 89 45 D8 E8 ?? ?? ?? ?? 8D 45 D8 C6 45 FC 1B 50 8D "
    "85 48 FF FF FF 50 8D 4D B0 E8 ?? ?? ?? ?? 84 C0 C6 45 FC 1A 8D 4D D8 0F "
    "94 C3 E8 ?? ?? ?? ?? 84 DB 74 7C 51 8B D7 8D 8D 60 FF FF FF E8 ?? ?? ?? "
    "?? 83 C4 04 50 BA ?? ?? ?? ?? C6 45 FC 1C 8D 4D D8 E8 ?? ?? ?? ?? 83 C4 "
    "04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 1D 8D 4D 90 E8 ?? ?? ?? ?? 83 C4 04 50 "
    "C6 45 FC 1E 8B 0D ?? ?? ?? ?? 6A 0C E8 ?? ?? ?? ?? 8D 4D 90 8A D8 E8 ?? "
    "?? ?? ?? 8D 4D D8 E8 ?? ?? ?? ?? 8D 8D 60 FF FF FF E8 ?? ?? ?? ?? 8D 4D "
    "B0 C6 45 FC 0A E8 ?? ?? ?? ?? E9 23 08 00 00 FF 75 B0 33 DB 8D 8D F8 FE "
    "FF FF 83 CE FF 89 9D F8 FE FF FF 8D 53 04 E8 ?? ?? ?? ?? 8B 85 F8 FE FF "
    "FF 83 C4 04 85 C0 0F 84 18 01 00 00 89 5D E4 89 5D E8 89 5D EC C1 E0 04 "
    "8D 4D E4 50 C6 45 FC 1F E8 ?? ?? ?? ?? 8B 5D E4 33 C0 3B 5D E8 8B CB 8B "
    "95 F8 FE FF FF FF 75 B0 0F 44 C8 C1 E2 04 E8 ?? ?? ?? ?? 8B B5 F8 FE FF "
    "FF 33 C9 83 C4 04 8B C3 3B 5D E8 0F 44 C1 85 F6 7E 17 8B 95 FC FE FF FF "
    "39 50 08 0F 84 92 00 00 00 41 83 C0 10 3B CE 7C EF 51 8B D7 8D 8D 78 FF "
    "FF FF E8 ?? ?? ?? ?? 83 C4 04 50 BA ?? ?? ?? ?? C6 45 FC 20 8D 4D 90 E8 "
    "?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 21 8D 8D 60 FF FF FF "
    "E8 ?? ?? ?? ?? 83 C4 04 50 C6 45 FC 22 8B 0D ?? ?? ?? ?? 6A 0C E8 ?? ?? "
    "?? ?? 8D 8D 60 FF FF FF 8A D8 E8 ?? ?? ?? ?? 8D 4D 90 E8 ?? ?? ?? ?? 8D "
    "8D 78 FF FF FF E8 ?? ?? ?? ?? 8D 4D E4 E8 ?? ?? ?? ?? 8D 4D B0 C6 45 FC "
    "0A E8 ?? ?? ?? ?? E9 07 07 00 00 8B 70 04 8B 00 89 85 FC FE FF FF 83 FE "
    "FF 0F 84 62 FF FF FF 8D 4D E4 89 5D E8 C6 45 FC 1A E8 ?? ?? ?? ?? 8B 9D "
    "FC FE FF FF 80 7D 1C 00 74 13 8D 4D B0 C6 45 FC 0A B3 01 E8 ?? ?? ?? ?? "
    "E9 C5 06 00 00 6A 20 E8 ?? ?? ?? ?? 83 C4 04 89 85 FC FE FF FF C6 45 FC "
    "23 85 C0 74 0B 6A 00 8B C8 E8 ?? ?? ?? ?? EB 02 33 C0 50 8D 4D D0 C6 45 "
    "FC 1A E8 ?? ?? ?? ?? C6 45 FC 24 8D 95 48 FF FF FF 8B 4D D0 53 56 52 8B "
    "01 8B 40 04 FF D0"};

// Entire archive-name builder including both returns and configured-root loop.
// [ebp+c]/100000 -> [ebp-98]; WAV/NWA use kinds 1/2 and a different format.
// Only the kind-3 branch formats z%04d with the quotient, then appends ovk.
// Success copies the resolved path and stores ESI kind to the supplied pointer.
// The loop only changes the root/prefix; it cannot rewrite the stem or extension.
inline constexpr Signature kBuilder{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC A8 00 00 00 A1 "
    "?? ?? ?? ?? 33 C5 89 45 EC 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 89 95 "
    "6C FF FF FF 89 8D 60 FF FF FF 8B 45 08 8B 4D 0C 89 85 64 FF FF FF 8B 45 "
    "10 89 85 54 FF FF FF 33 C0 89 8D 5C FF FF FF C7 85 50 FF FF FF 00 00 00 "
    "00 C7 45 A0 07 00 00 00 C7 45 9C 00 00 00 00 66 89 45 8C 89 45 FC C7 45 "
    "E8 07 00 00 00 89 45 E4 66 89 45 D4 B8 89 B5 F8 14 C6 45 FC 01 8B 35 ?? "
    "?? ?? ?? F7 E9 33 C9 C1 FA 0D 8B C2 89 8D 70 FF FF FF 8B 4E 04 2B 0E C1 "
    "E8 1F 03 C2 89 85 68 FF FF FF B8 AB AA AA 2A F7 E9 C1 FA 03 8B C2 C1 E8 "
    "1F 03 C2 85 C0 7E 5D 8B 3D ?? ?? ?? ?? 33 DB 90 8B 0E 03 CB 83 BF 8C 00 "
    "00 00 08 72 05 8B 47 78 EB 03 8D 47 78 FF B7 88 00 00 00 50 FF 71 10 51 "
    "E8 ?? ?? ?? ?? 85 C0 0F 84 8D 00 00 00 8B 4E 04 B8 AB AA AA 2A 2B 0E 83 "
    "C3 30 FF 85 70 FF FF FF F7 E9 C1 FA 03 8B C2 C1 E8 1F 03 C2 39 85 70 FF "
    "FF FF 7C AC 8B B5 60 FF FF FF 8B CE 68 ?? ?? ?? ?? E8 ?? ?? ?? ?? 83 7D "
    "E8 08 72 0B FF 75 D4 E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 45 E8 07 00 00 00 "
    "83 7D A0 08 C7 45 E4 00 00 00 00 66 89 45 D4 72 0B FF 75 8C E8 ?? ?? ?? "
    "?? 83 C4 04 8B C6 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B 4D EC 33 "
    "CD E8 ?? ?? ?? ?? 8B E5 5D C3 8B 9D 70 FF FF FF 85 DB 78 90 8B 4E 04 B8 "
    "AB AA AA 2A 2B 0E F7 E9 C1 FA 03 8B C2 C1 E8 1F 03 C2 3B D8 0F 8D 72 FF "
    "FF FF 8B 3D ?? ?? ?? ?? 8D 0C 5B C1 E1 04 89 8D 70 FF FF FF 8B 06 03 C1 "
    "C7 45 88 07 00 00 00 33 C9 C7 45 84 00 00 00 00 6A FF 51 66 89 8D 74 FF "
    "FF FF 8D 8D 74 FF FF FF 50 E8 ?? ?? ?? ?? FF B5 5C FF FF FF C6 45 FC 02 "
    "33 C0 FF B5 68 FF FF FF BE 01 00 00 00 83 EC 18 8B CC 6A 0A C7 41 14 07 "
    "00 00 00 C7 41 10 00 00 00 00 68 ?? ?? ?? ?? 66 89 01 E8 ?? ?? ?? ?? 8D "
    "45 BC 50 E8 ?? ?? ?? ?? 83 C4 24 8D 4D 8C C6 45 FC 03 3B C8 74 0A 6A FF "
    "6A 00 50 E8 ?? ?? ?? ?? C6 45 FC 02 83 7D D0 08 72 0B FF 75 BC E8 ?? ?? "
    "?? ?? 83 C4 04 6A 03 33 C0 C7 45 B8 07 00 00 00 68 ?? ?? ?? ?? 8D 4D A4 "
    "C7 45 B4 00 00 00 00 66 89 45 A4 E8 ?? ?? ?? ?? 8B 95 6C FF FF FF 8D 45 "
    "A4 50 8D 45 8C C6 45 FC 04 50 FF B5 64 FF FF FF 8D 85 74 FF FF FF 50 8D "
    "4D BC E8 ?? ?? ?? ?? 83 C4 10 8D 4D D4 C6 45 FC 05 3B C8 74 0A 6A FF 6A "
    "00 50 E8 ?? ?? ?? ?? 83 7D D0 08 72 0B FF 75 BC E8 ?? ?? ?? ?? 83 C4 04 "
    "33 C0 C6 45 FC 02 83 7D B8 08 C7 45 D0 07 00 00 00 C7 45 CC 00 00 00 00 "
    "66 89 45 BC 72 0B FF 75 A4 E8 ?? ?? ?? ?? 83 C4 04 83 7D E8 08 8D 45 D4 "
    "0F 43 45 D4 50 FF D7 83 F8 FF 74 08 A8 10 0F 84 85 02 00 00 FF B5 5C FF "
    "FF FF 33 C0 BE 02 00 00 00 FF B5 68 FF FF FF 83 EC 18 8B CC 6A 0A C7 41 "
    "14 07 00 00 00 C7 41 10 00 00 00 00 68 ?? ?? ?? ?? 66 89 01 E8 ?? ?? ?? "
    "?? 8D 45 BC 50 E8 ?? ?? ?? ?? 83 C4 24 8D 4D 8C C6 45 FC 06 3B C8 74 0A "
    "6A FF 6A 00 50 E8 ?? ?? ?? ?? C6 45 FC 02 83 7D D0 08 72 0B FF 75 BC E8 "
    "?? ?? ?? ?? 83 C4 04 6A 03 33 C0 C7 45 B8 07 00 00 00 68 ?? ?? ?? ?? 8D "
    "4D A4 C7 45 B4 00 00 00 00 66 89 45 A4 E8 ?? ?? ?? ?? 8B 95 6C FF FF FF "
    "8D 45 A4 50 8D 45 8C C6 45 FC 07 50 FF B5 64 FF FF FF 8D 85 74 FF FF FF "
    "50 8D 4D BC E8 ?? ?? ?? ?? 83 C4 10 8D 4D D4 C6 45 FC 08 3B C8 74 0A 6A "
    "FF 6A 00 50 E8 ?? ?? ?? ?? 83 7D D0 08 72 0B FF 75 BC E8 ?? ?? ?? ?? 83 "
    "C4 04 33 C0 C6 45 FC 02 83 7D B8 08 C7 45 D0 07 00 00 00 C7 45 CC 00 00 "
    "00 00 66 89 45 BC 72 0B FF 75 A4 E8 ?? ?? ?? ?? 83 C4 04 83 7D E8 08 8D "
    "45 D4 0F 43 45 D4 50 FF D7 83 F8 FF 74 08 A8 10 0F 84 63 01 00 00 FF B5 "
    "68 FF FF FF 33 C0 BE 03 00 00 00 83 EC 18 8B CC 6A 05 C7 41 14 07 00 00 "
    "00 C7 41 10 00 00 00 00 68 ?? ?? ?? ?? 66 89 01 E8 ?? ?? ?? ?? 8D 45 BC "
    "50 E8 ?? ?? ?? ?? 83 C4 20 8D 4D 8C C6 45 FC 09 3B C8 74 0A 6A FF 6A 00 "
    "50 E8 ?? ?? ?? ?? C6 45 FC 02 83 7D D0 08 72 0B FF 75 BC E8 ?? ?? ?? ?? "
    "83 C4 04 6A 03 33 C0 C7 45 B8 07 00 00 00 68 ?? ?? ?? ?? 8D 4D A4 C7 45 "
    "B4 00 00 00 00 66 89 45 A4 E8 ?? ?? ?? ?? 8B 95 6C FF FF FF 8D 45 A4 50 "
    "8D 45 8C C6 45 FC 0A 50 FF B5 64 FF FF FF 8D 85 74 FF FF FF 50 8D 4D BC "
    "E8 ?? ?? ?? ?? 83 C4 10 8D 4D D4 C6 45 FC 0B 3B C8 74 0A 6A FF 6A 00 50 "
    "E8 ?? ?? ?? ?? 83 7D D0 08 72 0B FF 75 BC E8 ?? ?? ?? ?? 83 C4 04 33 C0 "
    "C7 45 D0 07 00 00 00 83 7D B8 08 C7 45 CC 00 00 00 00 66 89 45 BC 72 0B "
    "FF 75 A4 E8 ?? ?? ?? ?? 83 C4 04 83 7D E8 08 8D 45 D4 0F 43 45 D4 50 FF "
    "D7 83 F8 FF 74 04 A8 10 74 4F C6 45 FC 01 83 7D 88 08 72 0E FF B5 74 FF "
    "FF FF E8 ?? ?? ?? ?? 83 C4 04 8B 35 ?? ?? ?? ?? B8 AB AA AA 2A 83 85 70 "
    "FF FF FF 30 43 8B 4E 04 2B 0E F7 E9 C1 FA 03 8B C2 C1 E8 1F 03 C2 3B D8 "
    "0F 8D 96 FB FF FF 8B 8D 70 FF FF FF E9 2B FC FF FF C6 45 FC 01 83 7D 88 "
    "08 72 0E FF B5 74 FF FF FF E8 ?? ?? ?? ?? 83 C4 04 8B 85 54 FF FF FF 85 "
    "C0 74 02 89 30 8B 9D 60 FF FF FF 33 C0 6A FF 50 8B CB C7 43 14 07 00 00 "
    "00 C7 43 10 00 00 00 00 66 89 03 8D 45 D4 50 E8 ?? ?? ?? ?? 83 7D E8 08 "
    "72 0B FF 75 D4 E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 45 E8 07 00 00 00 83 7D "
    "A0 08 C7 45 E4 00 00 00 00 66 89 45 D4 72 0B FF 75 8C E8 ?? ?? ?? ?? 83 "
    "C4 04 8B C3 E9 4D FB FF FF"};

// Entire path concatenation wrapper: root, prefix, category, basename, extension
// are appended in order, with three backslashes and one dot. No alias lookup.
inline constexpr Signature kConcat{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC BC 00 00 00 A1 "
    "?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 89 8D "
    "44 FF FF FF 8B 45 14 8D 8D 48 FF FF FF 8B 75 08 8B 7D 0C 8B 5D 10 68 ?? "
    "?? ?? ?? 89 85 40 FF FF FF C7 85 3C FF FF FF 00 00 00 00 E8 ?? ?? ?? ?? "
    "83 C4 04 56 8B D0 C7 45 FC 00 00 00 00 8D 8D 78 FF FF FF E8 ?? ?? ?? ?? "
    "83 C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC 01 8D 8D 60 FF FF FF E8 ?? ?? ?? "
    "?? 83 C4 04 57 8B D0 C6 45 FC 02 8D 4D A8 E8 ?? ?? ?? ?? 83 C4 04 68 ?? "
    "?? ?? ?? 8B D0 C6 45 FC 03 8D 4D C0 E8 ?? ?? ?? ?? 83 C4 04 53 8B D0 C6 "
    "45 FC 04 8D 4D D8 E8 ?? ?? ?? ?? 83 C4 04 68 ?? ?? ?? ?? 8B D0 C6 45 FC "
    "05 8D 4D 90 E8 ?? ?? ?? ?? 83 C4 04 FF B5 40 FF FF FF 8B 9D 44 FF FF FF "
    "8B D0 8B CB C6 45 FC 06 E8 ?? ?? ?? ?? 83 C4 04 83 7D A4 08 72 0B FF 75 "
    "90 E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 45 A4 07 00 00 00 83 7D EC 08 C7 45 "
    "A0 00 00 00 00 66 89 45 90 72 0B FF 75 D8 E8 ?? ?? ?? ?? 83 C4 04 33 C0 "
    "C7 45 EC 07 00 00 00 83 7D D4 08 C7 45 E8 00 00 00 00 66 89 45 D8 72 0B "
    "FF 75 C0 E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 45 D4 07 00 00 00 83 7D BC 08 "
    "C7 45 D0 00 00 00 00 66 89 45 C0 72 0B FF 75 A8 E8 ?? ?? ?? ?? 83 C4 04 "
    "33 C0 C7 45 BC 07 00 00 00 83 BD 74 FF FF FF 08 C7 45 B8 00 00 00 00 66 "
    "89 45 A8 72 0E FF B5 60 FF FF FF E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 85 74 "
    "FF FF FF 07 00 00 00 83 7D 8C 08 C7 85 70 FF FF FF 00 00 00 00 66 89 85 "
    "60 FF FF FF 72 0E FF B5 78 FF FF FF E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 45 "
    "8C 07 00 00 00 83 BD 5C FF FF FF 08 C7 45 88 00 00 00 00 66 89 85 78 FF "
    "FF FF 72 0E FF B5 48 FF FF FF E8 ?? ?? ?? ?? 83 C4 04 8B C3 8B 4D F4 64 "
    "89 0D 00 00 00 00 59 5F 5E 5B 8B 4D F0 33 CD E8 ?? ?? ?? ?? 8B E5 5D C3"};

// Complete UTF-16 formatter wrapper: one vararg at [ebp+24], format TextUnion
// at [ebp+c], bounded 0x400 wide buffer, result copied to the output TextUnion.
inline constexpr Signature kFormatter{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 08 08 00 00 A1 "
    "?? ?? ?? ?? 33 C5 89 45 F0 56 50 8D 45 F4 64 A3 00 00 00 00 8B 75 08 C7 "
    "85 EC F7 FF FF 00 00 00 00 C7 45 FC 00 00 00 00 8D 4D 24 83 7D 20 08 8D "
    "45 0C 51 0F 43 45 0C 50 8D 85 F0 F7 FF FF 68 00 04 00 00 50 E8 ?? ?? ?? "
    "?? 83 C4 10 8D 85 F0 F7 FF FF 8B CE 50 E8 ?? ?? ?? ?? 83 7D 20 08 72 0B "
    "FF 75 0C E8 ?? ?? ?? ?? 83 C4 04 8B C6 8B 4D F4 64 89 0D 00 00 00 00 59 "
    "5E 8B 4D F0 33 CD E8 ?? ?? ?? ?? 8B E5 5D C3"};

// Complete measured CRT bounded wide-format call wrapper and its parameter
// checks. The upper wrapper calls the final cdecl entry, which forwards locale=0.
inline constexpr Signature kCrtFormat{
    "55 8B EC 83 7D 10 00 75 15 E8 ?? ?? ?? ?? C7 00 16 00 00 00 E8 ?? ?? ?? "
    "?? 83 C8 FF 5D C3 56 8B 75 08 85 F6 74 3B 83 7D 0C 00 76 35 FF 75 18 FF "
    "75 14 FF 75 10 FF 75 0C 56 68 ?? ?? ?? ?? E8 ?? ?? ?? ?? 83 C4 18 85 C0 "
    "79 05 33 C9 66 89 0E 83 F8 FE 75 20 E8 ?? ?? ?? ?? C7 00 22 00 00 00 EB "
    "0B E8 ?? ?? ?? ?? C7 00 16 00 00 00 E8 ?? ?? ?? ?? 83 C8 FF 5E 5D C3 55 "
    "8B EC FF 75 14 6A 00 FF 75 10 FF 75 0C FF 75 08 E8 ?? ?? ?? ?? 83 C4 14 "
    "5D C3"};

// Independently resolved WideAssign ABI.
inline constexpr Signature kWideAssign{
    "55 8B EC 53 8B 5D 08 56 8B F1 85 DB 74 48 8B 4E 14 83 F9 08 72 04 8B 06 "
    "EB 02 8B C6 3B D8 72 36 83 F9 08 72 04 8B 16 EB 02 8B D6 8B 46 10 8D 04 "
    "42 3B C3 76 21 83 F9 08 72 04 8B 06 EB 02 8B C6 FF 75 0C 2B D8 8B CE D1 "
    "FB 53 56 E8 ?? ?? ?? ?? 5E 5B 5D C2 08 00 57 8B 7D 0C 81 FF FE FF FF 7F "
    "0F 87 89 00 00 00 8B 46 14 3B C7 73 19 FF 76 10 8B CE 57 E8 ?? ?? ?? ?? "
    "85 FF 74 6A 83 7E 14 08 72 2E 8B 0E EB 2C 85 FF 75 F2 89 7E 10 83 F8 08 "
    "72 10 8B 06 33 C9 5F 66 89 08 8B C6 5E 5B 5D C2 08 00 8B C6 33 C9 5F 5E "
    "5B 66 89 08 5D C2 08 00 8B CE 85 FF 74 0E 8D 04 3F 50 53 51 E8 ?? ?? ?? "
    "?? 83 C4 0C 83 7E 14 08 89 7E 10 72 11 8B 06 33 C9 66 89 0C 78 8B C6 5F "
    "5E 5B 5D C2 08 00 8B C6 33 C9 66 89 0C 78 5F 8B C6 5E 5B 5D C2 08 00 68 "
    "?? ?? ?? ?? E8 ?? ?? ?? ??"};

// Independently resolved ArchiveOpen ABI.
inline constexpr Signature kArchiveOpen{
    "55 8B EC 51 53 8B 5D 0C 56 8B F1 57 8B 7D 08 8B 0E E8 ?? ?? ?? ?? 84 C0 "
    "74 7A 53 8B D7 C7 06 00 00 00 00 8B CE C7 46 08 00 00 00 00 C7 46 0C 00 "
    "00 00 00 E8 ?? ?? ?? ?? 83 C4 04 84 C0 74 55 8B 0E BA 02 00 00 00 6A 00 "
    "6A 00 E8 ?? ?? ?? ?? 83 C4 08 84 C0 74 3E 8B 3E E8 ?? ?? ?? ?? 85 FF 75 "
    "07 E8 ?? ?? ?? ?? EB 09 57 E8 ?? ?? ?? ?? 83 C4 04 8B 0E 89 56 0C 33 D2 "
    "6A 00 6A 00 89 46 08 E8 ?? ?? ?? ?? 83 C4 08 84 C0 0F 95 C0 5F 5E 5B 59 "
    "5D C2 08 00 5F 5E 32 C0 5B 59 5D C2 08 00"};

// Independently resolved ArchiveRead ABI.
inline constexpr Signature kArchiveRead{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 50 A1 ?? ?? ?? "
    "?? 33 C5 89 45 EC 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B F2 8B D9 8B "
    "7D 08 E8 ?? ?? ?? ?? 85 FF 0F 85 8D 00 00 00 6A 09 33 C0 C7 45 E8 07 00 "
    "00 00 68 ?? ?? ?? ?? 8D 4D D4 89 7D E4 66 89 45 D4 E8 ?? ?? ?? ?? 89 7D "
    "FC 8D 4D BC 6A 0E 33 C0 C7 45 D0 07 00 00 00 68 ?? ?? ?? ?? 89 7D CC 66 "
    "89 45 BC E8 ?? ?? ?? ?? 8D 55 D4 C6 45 FC 01 8D 4D BC E8 ?? ?? ?? ?? 83 "
    "7D D0 08 72 0B FF 75 BC E8 ?? ?? ?? ?? 83 C4 04 33 C0 C7 45 D0 07 00 00 "
    "00 C7 45 CC 00 00 00 00 66 89 45 BC 83 7D E8 08 72 0B FF 75 D4 E8 ?? ?? "
    "?? ?? 83 C4 04 33 C0 E9 CC 00 00 00 85 DB 75 3C 6A 09 33 C0 C7 45 E8 07 "
    "00 00 00 68 ?? ?? ?? ?? 8D 4D D4 89 5D E4 66 89 45 D4 E8 ?? ?? ?? ?? C7 "
    "45 FC 02 00 00 00 BA 16 00 00 00 8D 45 D4 50 8D 4A EB E8 ?? ?? ?? ?? 83 "
    "C4 04 EB A8 85 F6 79 2C 6A 09 33 C0 C7 45 E8 07 00 00 00 68 ?? ?? ?? ?? "
    "8D 4D D4 C7 45 E4 00 00 00 00 66 89 45 D4 E8 ?? ?? ?? ?? C7 45 FC 03 00 "
    "00 00 EB BA 57 56 6A 01 53 E8 ?? ?? ?? ?? 8B D8 83 C4 10 3B DE 7D 47 57 "
    "E8 ?? ?? ?? ?? 83 C4 04 85 C0 74 3A 6A 05 33 C0 C7 45 B8 07 00 00 00 68 "
    "?? ?? ?? ?? 8D 4D A4 C7 45 B4 00 00 00 00 66 89 45 A4 E8 ?? ?? ?? ?? 8D "
    "4D A4 C7 45 FC 04 00 00 00 E8 ?? ?? ?? ?? 8D 4D A4 E8 ?? ?? ?? ?? 8B C3 "
    "8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B 4D EC 33 CD E8 ?? ?? ?? ?? "
    "8B E5 5D C3"};

// Independently resolved OggCtor ABI.
inline constexpr Signature kOggCtor{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 10 53 56 57 A1 "
    "?? ?? ?? ?? 33 C5 50 8D 45 F4 64 A3 00 00 00 00 8B F1 89 75 EC C7 46 04 "
    "00 00 00 00 C7 46 08 00 00 00 00 C7 46 0C 00 00 00 00 C7 46 10 00 00 00 "
    "00 C7 45 FC 00 00 00 00 C7 06 ?? ?? ?? ??"};

// Independently resolved OggOpen ABI.
inline constexpr Signature kOggOpen{
    "55 8B EC 83 EC 30 56 8B F1 8B 06 FF 50 08 8B 56 14 8B 45 0C 89 82 D4 02 "
    "00 00 8B 45 08 83 78 14 08 72 02 8B 00 68 ?? ?? ?? ?? 50 8B 46 14 05 D0 "
    "02 00 00 50 E8 ?? ?? ?? ?? 8B 4E 14 83 C4 0C 83 B9 D0 02 00 00 00 74 7A "
    "8B 45 10 89 81 D8 02 00 00 8B 46 14 6A 00 FF B0 D4 02 00 00 FF B0 D0 02 "
    "00 00 E8 ?? ?? ?? ?? 8B 4E 14 51 8B C4 C7 45 F0 ?? ?? ?? ?? C7 45 F4 ?? "
    "?? ?? ?? C7 45 F8 ?? ?? ?? ?? C7 45 FC ?? ?? ?? ?? F3 0F 6F 45 F0 6A 00 "
    "6A 00 F3 0F 7F 00 51 8D 81 D0 02 00 00 50 E8 ?? ?? ?? ?? 83 C4 20 85 C0 "
    "79 21 8B 46 14 FF B0 D0 02 00 00 E8 ?? ?? ?? ?? 83 C4 04 8B CE E8 ?? ?? "
    "?? ?? 32 C0 5E 8B E5 5D C2 0C 00 FF 76 14 E8 ?? ?? ?? ?? 83 C4 04 85 C0 "
    "75 10 8B 06 8B CE FF 50 08 32 C0 5E 8B E5 5D C2 0C 00 6A FF FF 76 14 E8 "
    "?? ?? ?? ?? 6A FF FF 76 14 F3 0F 6F 00 F3 0F 7F 45 F0 F3 0F 6F 40 10 F3 "
    "0F 7F 45 E0 E8 ?? ?? ?? ?? F3 0F 6F 4D F0 83 C4 10 C7 46 08 10 00 00 00 "
    "66 0F 6F C1 66 0F 73 D9 08 66 0F 73 D8 04 66 0F 7E C2 66 0F 7E 4E 0C 89 "
    "56 04 0F AF D0 B0 01 03 D2 89 56 10 5E 8B E5 5D C2 0C 00"};

// Independently resolved OggRead ABI.
inline constexpr Signature kOggRead{
    "55 8B EC 53 8B 5D 14 56 8B 75 08 FF 33 FF 75 10 FF 75 0C 56 E8 ?? ?? ?? "
    "?? 8B D0 83 C4 10 8B CA 0F AF 4D 0C 85 C9 7E 16 EB 06 8D 9B 00 00 00 00 "
    "8A 43 0C 8D 76 01 30 46 FF 49 75 F4 8B C2 5E 5B 5D C3"};

// Decode data through the image's actual/preferred base. The measured family
// also places literals in merged writable data; section WRITE is not a literal
// identity. Require readable non-executable image data and its exact value.
template <size_t N>
inline bool WideLiteral(const exact_lookup::LoadedPeImage& image,
                        uintptr_t operand, const wchar_t (&literal)[N]) {
  if (!siglus_family::ExecutableSpan(image, operand, 4u)) return false;
  uintptr_t address = 0, rva = 0;
  return exact_lookup::DecodeAbsolute32ImageAddress(
             image, image.base + operand, &address, &rva) &&
         exact_lookup::SectionHasRole(
             exact_lookup::FindSectionForRva(image, rva, N * sizeof(wchar_t)),
             IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE) &&
         exact_lookup::IsReadableSpan(image.base + rva, N * sizeof(wchar_t)) &&
         std::memcmp(image.base + rva, literal, N * sizeof(wchar_t)) == 0;
}
inline bool Calls(const exact_lookup::LoadedPeImage& image, uintptr_t call,
                  uintptr_t target) {
  return exact_lookup::MatchesRel32CallEndingAt(image, call + 5u, target);
}
inline bool ImagePointer(const exact_lookup::LoadedPeImage& image,
                         uintptr_t operand, uintptr_t* rva) {
  uintptr_t ignored = 0;
  return operand < image.size && image.size - operand >= 4u &&
         exact_lookup::DecodeAbsolute32ImageAddress(
             image, image.base + operand, &ignored, rva);
}
}  // namespace siglus_resource

// voice_entry must come from the independently complete message profile.
// This function also resolves the complete voice request body independently;
// passing an arbitrary nonzero entry cannot turn the optional gate on.
inline bool ResolveSiglusResourceMappingProfile(
    const exact_lookup::LoadedPeImage& image, uintptr_t voice_entry,
    SiglusResourceMappingProfile* out) {
  using namespace siglus_resource;
  using siglus_family::Unique;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u || voice_entry == 0u) return false;
  uintptr_t voice = 0, play = 0, resource = 0, builder = 0;
  uintptr_t concat = 0, formatter = 0, crt = 0;
  uintptr_t assign = 0, archive_open = 0, archive_read = 0;
  uintptr_t ogg_ctor = 0, ogg_open = 0, ogg_read = 0;
  if (!Unique(image, kVoiceRequest.pattern(), &voice) || voice != voice_entry ||
      !Unique(image, kPlay.pattern(), &play) ||
      !Unique(image, kResource.pattern(), &resource) ||
      !Unique(image, kBuilder.pattern(), &builder) ||
      !Unique(image, kConcat.pattern(), &concat) ||
      !Unique(image, kFormatter.pattern(), &formatter) ||
      !Unique(image, kCrtFormat.pattern(), &crt) ||
      !Unique(image, kWideAssign.pattern(), &assign) ||
      !Unique(image, kArchiveOpen.pattern(), &archive_open) ||
      !Unique(image, kArchiveRead.pattern(), &archive_read) ||
      !Unique(image, kOggCtor.pattern(), &ogg_ctor) ||
      !Unique(image, kOggOpen.pattern(), &ogg_open) ||
      !Unique(image, kOggRead.pattern(), &ogg_read)) return false;
  // Offsets name instruction boundaries within the checked ABI spans; none is
  // a module RVA. Each component is independently located and connected here.
  if (!Calls(image, voice + 0xa1u, play) ||
      !Calls(image, play + 0x4bu, resource) ||
      !Calls(image, resource + 0x112u, builder) ||
      !Calls(image, builder + 0x2a2u, concat) ||
      !Calls(image, builder + 0x3c4u, concat) ||
      !Calls(image, builder + 0x4e0u, concat) ||
      !Calls(image, builder + 0x22bu, formatter) ||
      !Calls(image, builder + 0x34du, formatter) ||
      !Calls(image, builder + 0x469u, formatter) ||
      !Calls(image, formatter + 0x5cu, crt + 0x77u) ||
      !Calls(image, crt + 0x88u, crt) ||
      !Calls(image, resource + 0xeeu, assign) ||
      !Calls(image, builder + 0x222u, assign) ||
      !Calls(image, builder + 0x27bu, assign) ||
      !Calls(image, builder + 0x344u, assign) ||
      !Calls(image, builder + 0x39du, assign) ||
      !Calls(image, builder + 0x460u, assign) ||
      !Calls(image, builder + 0x4b9u, assign) ||
      !Calls(image, resource + 0x579u, archive_open) ||
      !Calls(image, resource + 0x626u, archive_read) ||
      !Calls(image, resource + 0x66eu, archive_read) ||
      !Calls(image, resource + 0x789u, ogg_ctor) ||
      !WideLiteral(image, resource + 0xd9u, L"koe") ||
      !WideLiteral(image, builder + 0x21bu, L"%04d\\z%09d") ||
      !WideLiteral(image, builder + 0x33du, L"%04d\\z%09d") ||
      !WideLiteral(image, builder + 0x269u, L"wav") ||
      !WideLiteral(image, builder + 0x38bu, L"nwa") ||
      !WideLiteral(image, builder + 0x459u, L"z%04d") ||
      !WideLiteral(image, builder + 0x4a7u, L"ovk") ||
      !WideLiteral(image, concat + 0x47u, L"\\") ||
      !WideLiteral(image, concat + 0x7cu, L"\\") ||
      !WideLiteral(image, concat + 0xa7u, L"\\") ||
      !WideLiteral(image, concat + 0xcfu, L".")) return false;
  uintptr_t vtable = 0, method = 0, read_callback = 0;
  if (!ImagePointer(image, ogg_ctor + 0x52u, &vtable) ||
      !exact_lookup::SectionHasRole(
          exact_lookup::FindSectionForRva(image, vtable, 8u),
          IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE) ||
      !ImagePointer(image, vtable + 4u, &method) || method != ogg_open ||
      !ImagePointer(image, ogg_open + 0x70u, &read_callback) ||
      read_callback != ogg_read ||
      !WideLiteral(image, ogg_open + 0x26u, L"rb")) return false;
  out->voice_entry_rva = voice;
  out->resource_entry_rva = resource;
  out->archive_builder_rva = builder;
  out->ovk_path_return_rva = builder + 0x4e5u;
  out->archive_open_rva = archive_open;
  out->archive_open_return_rva = resource + 0x57eu;
  out->archive_read_rva = archive_read;
  out->archive_header_return_rva = resource + 0x62bu;
  out->archive_table_return_rva = resource + 0x673u;
  out->ogg_open_rva = ogg_open;
  out->payload_return_rva = resource + 0x7b6u;
  out->ogg_vtable_rva = vtable;
  out->ogg_read_rva = ogg_read;
  return true;
}
}  // namespace fushi_voice_hook
