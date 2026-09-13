#pragma once

#include "siglus_legacy_glyph_sites.h"

namespace fushi_voice_hook {

struct SiglusLegacyMessageProfile {
  uintptr_t message_entry_rva = 0;
  uintptr_t text_entry_rva = 0;
  uintptr_t text_return_rva = 0;
  uintptr_t voice_entry_rva = 0;
  uintptr_t script_slot_rva = 0;
  uint32_t owner_voice_key_offset = 0;
  uint32_t owner_voice_flag_offset = 0;
  uint32_t script_voice_key_offset = 0;
  uint32_t script_voice_second_offset = 0;
  uint32_t script_voice_flag_offset = 0;
};

namespace siglus_legacy_message {
using siglus_family::Signature;
// Complete independent FPO compiler bodies. Only absolute image addresses and
// direct CALL displacements are masked. All branches, stack allocation, value
// argument layout, script fields, owner writes and epilogues remain exact.
// In particular this is not the modern dynamic-alignment/0x1f8 owner ABI.
inline constexpr Signature kMessage{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 44 A1 ?? ?? ?? ?? 33 C4 89 44 24 40 53 55 56 57 "
    "A1 ?? ?? ?? ?? 33 C4 50 8D 44 24 58 64 A3 00 00 00 00 8B AC 24 88 00 00 00 8B 9C 24 84 00 00 00 "
    "8B F9 33 F6 3B FE 89 74 24 60 75 18 83 BC 24 80 00 00 00 08 0F 82 F6 01 00 00 8B 44 24 6C 50 E9 "
    "E4 01 00 00 C7 44 24 50 07 00 00 00 89 74 24 4C 66 89 74 24 3C C6 44 24 60 01 8B 0D ?? ?? ?? ?? "
    "C6 81 61 01 00 00 01 8D 4C 24 68 E8 ?? ?? ?? ?? 8D 44 24 68 E8 ?? ?? ?? ?? 8D 54 24 38 52 8D 44 "
    "24 6C 50 E8 ?? ?? ?? ?? 39 74 24 4C 74 14 55 53 8D 4C 24 70 51 57 8D 4C 24 48 E8 ?? ?? ?? ?? 83 "
    "C4 10 A1 ?? ?? ?? ?? 8A 88 A4 01 00 00 8B 80 9C 01 00 00 8D 54 24 14 52 8D B7 10 01 00 00 89 87 "
    "20 01 00 00 88 8F 24 01 00 00 89 5C 24 18 89 6C 24 1C E8 ?? ?? ?? ?? 80 BC 24 8C 00 00 00 00 A1 "
    "?? ?? ?? ?? 74 77 80 B8 EE 01 00 00 00 75 6E 8D 44 24 1C 50 E8 ?? ?? ?? ?? C6 44 24 60 02 8B 0D "
    "?? ?? ?? ?? 8B 51 7C 8B 49 78 52 51 50 A1 ?? ?? ?? ?? 8B 90 A0 01 00 00 8B 80 9C 01 00 00 8D 4C "
    "24 74 51 52 50 E8 ?? ?? ?? ?? C6 44 24 60 01 83 7C 24 34 08 72 0D 8B 4C 24 20 51 E8 ?? ?? ?? ?? "
    "83 C4 04 A1 ?? ?? ?? ?? 33 F6 C7 44 24 34 07 00 00 00 89 74 24 30 66 89 74 24 20 EB 02 33 F6 8B "
    "90 9C 01 00 00 8B 88 A0 01 00 00 89 90 A8 01 00 00 89 88 AC 01 00 00 89 98 B0 01 00 00 89 A8 B4 "
    "01 00 00 E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 80 B8 B1 00 00 00 00 75 2A 8B 15 ?? ?? ?? ?? 80 7A 01 00 "
    "74 1E 80 B8 E4 00 00 00 00 75 0E A1 ?? ?? ?? ?? 80 B8 0E 01 00 00 00 74 07 B1 01 E8 ?? ?? ?? ?? "
    "57 C6 87 FC 00 00 00 01 E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 80 B8 F5 01 00 00 00 75 16 80 B8 F6 01 00 "
    "00 00 75 0D 39 74 24 4C 75 07 8B CF E8 ?? ?? ?? ?? BF 08 00 00 00 39 7C 24 50 72 0D 8B 4C 24 3C "
    "51 E8 ?? ?? ?? ?? 83 C4 04 39 BC 24 80 00 00 00 C7 44 24 50 07 00 00 00 89 74 24 4C 66 89 74 24 "
    "3C 72 0D 8B 54 24 6C 52 E8 ?? ?? ?? ?? 83 C4 04 8B 4C 24 58 64 89 0D 00 00 00 00 59 5F 5E 5D 5B "
    "8B 4C 24 40 33 CC E8 ?? ?? ?? ?? 83 C4 50 C3"};
inline constexpr Signature kVoice{
    "A1 ?? ?? ?? ?? 53 56 C6 80 61 01 00 00 01 E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 83 C4 04 80 B9 EF 01 "
    "00 00 00 8A D8 A1 ?? ?? ?? ?? 75 09 80 B8 AD 00 00 00 00 74 09 80 B8 B9 00 00 00 00 EB 07 80 B8 "
    "B8 00 00 00 00 74 08 8B 80 BC 00 00 00 EB 05 B8 64 00 00 00 8B 4C 24 0C 84 DB 0F 94 C2 52 8B 54 "
    "24 0C 6A 00 51 52 50 A1 ?? ?? ?? ?? 56 57 05 98 00 00 00 E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 83 C9 FF "
    "88 98 A4 01 00 00 89 B8 9C 01 00 00 89 B0 A0 01 00 00 89 88 A8 01 00 00 89 88 AC 01 00 00 5B C3"};
inline constexpr size_t kTextCall = 139;
inline constexpr size_t kMessageCalls[] =
    {139,148,163,186,242,276,325,347,419,475,488,524,545,584,614};
inline constexpr size_t kMessageGlobals[] =
    {18,33,124,195,256,288,302,356,425,440,460,494};
inline constexpr size_t kScriptReferences[] = {195,256,302,356,494};
inline constexpr size_t kVoiceGlobals[] = {1,21,38,104,121};
static_assert(kMessage.bytes.size() == 623 && kVoice.bytes.size() == 160);
static_assert(kMessage.bytes[kTextCall] == 0xe8);

inline bool Global(const exact_lookup::LoadedPeImage& image, uintptr_t operand) {
  return (siglus_legacy_glyph::U32(image, operand) & 3u) == 0 &&
      siglus_legacy_glyph::AddressRole(image, operand,
          IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE, IMAGE_SCN_MEM_EXECUTE);
}
}  // namespace siglus_legacy_message

// The caller has admitted the legacy lookup lane and its complete glyph sites.
// This independently proves the message/voice wrappers and their script-key
// contract; it neither installs hooks nor proves an OVK source or audio role.
inline bool ResolveSiglusLegacyMessageProfile(
    const exact_lookup::LoadedPeImage& image, const SiglusLookupProfile& lane,
    const LegacyGlyphSites& admitted, SiglusLegacyMessageProfile* out) {
  using namespace siglus_legacy_message;
  using siglus_legacy_glyph::U32;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 || lane.pe_machine != IMAGE_FILE_MACHINE_I386 ||
      lane.pointer_bits != 32 ||
      lane.text_feed != SiglusLookupTextFeed::kLunaScenarioLane ||
      lane.glyph_abi != SiglusGlyphLayoutAbi::kStackSixteenArguments ||
      admitted.text_entry_rva == 0 || admitted.glyph_entry_rva == 0 ||
      lane.exact_text_rva != admitted.text_entry_rva ||
      lane.glyph_layout_rva != admitted.glyph_entry_rva) return false;
  uintptr_t message = 0, voice = 0;
  if (!siglus_family::Unique(image, kMessage.pattern(), &message) ||
      !siglus_family::Unique(image, kVoice.pattern(), &voice) ||
      !siglus_legacy_glyph::TextPrologue(image, admitted.text_entry_rva) ||
      !siglus_family::ExecutableSpan(image, admitted.text_entry_rva + 7,
          siglus_legacy_glyph::kTextTail.bytes.size())) return false;
  const auto tail = siglus_legacy_glyph::kTextTail.pattern();
  for (size_t n = 0; n < tail.size; ++n)
    if ((image.base[admitted.text_entry_rva + 7 + n] & tail.mask[n]) !=
        (tail.bytes[n] & tail.mask[n])) return false;
  if (!siglus_legacy_glyph::AddressRole(image, message + 3,
          IMAGE_SCN_MEM_EXECUTE, 0)) return false;
  for (size_t n : kMessageGlobals) if (!Global(image, message + n)) return false;
  for (size_t n : kVoiceGlobals) if (!Global(image, voice + n)) return false;
  const uint32_t script = U32(image, message + 195);
  for (size_t n : kScriptReferences)
    if (U32(image, message + n) != script) return false;
  if (script != U32(image, voice + 21) || script != U32(image, voice + 121) ||
      U32(image, message + 18) != U32(image, message + 33) ||
      U32(image, message + 124) != U32(image, message + 425) ||
      U32(image, message + 124) != U32(image, voice + 1) ||
      U32(image, message + 460) != U32(image, voice + 38)) return false;
  for (size_t n : kMessageCalls) {
    uintptr_t target = 0;
    if (!siglus_legacy_glyph::CallTarget(image, message + n, &target) ||
        ((target == admitted.text_entry_rva) != (n == kTextCall))) return false;
  }
  uintptr_t ignored = 0;
  if (!siglus_legacy_glyph::CallTarget(image, voice + 14, &ignored) ||
      !siglus_legacy_glyph::CallTarget(image, voice + 115, &ignored) ||
      !siglus_legacy_glyph::SameCall(image, message + 347, message + 545) ||
      !siglus_legacy_glyph::SameCall(image, message + 347, message + 584))
    return false;
  uintptr_t absolute = 0, script_rva = 0;
  if (!exact_lookup::DecodeAbsolute32ImageAddress(
          image, image.base + message + 195, &absolute, &script_rva)) return false;
  out->message_entry_rva = message;
  out->text_entry_rva = admitted.text_entry_rva;
  out->text_return_rva = message + kTextCall + 5;
  out->voice_entry_rva = voice;
  out->script_slot_rva = script_rva;
  out->owner_voice_key_offset = 0x120;
  out->owner_voice_flag_offset = 0x124;
  out->script_voice_key_offset = 0x19c;
  out->script_voice_second_offset = 0x1a0;
  out->script_voice_flag_offset = 0x1a4;
  return true;
}
}  // namespace fushi_voice_hook
