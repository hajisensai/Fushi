#pragma once

#include "siglus_autoprofile.h"

namespace fushi_voice_hook::siglus_native_family {
using siglus_family::Signature;

// Independent compiler/layout family: ECX points to a 24-byte UTF-16 string,
// unlike the scenario function's stack argument in the older family.
inline constexpr Signature kTextTail{
    "57 8B F9 8B 47 10 85 C0 75 05 5F 32 C0 5B C3 83 7F 14 07 76 02 8B 0F 56 50 8D 73 68 51 8B CE E8 ?? ?? ?? ?? 81 7B 78 00 01 00 00"};
inline constexpr Signature kTextCopy{
    "83 7F 14 07 8B C7 76 02 8B 07 FF 77 10 8D B3 80 00 00 00 50 8B CE E8 ?? ?? ?? ?? 81 BB 90 00 00 00 00 01 00 00"};
inline constexpr Signature kTextReturn{"5F B0 01 5B C3 CC"};
inline constexpr Signature kTextCaller{
    "8D 4B 10 E8 ?? ?? ?? ?? 8D 4B 10 E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 8D 43 10 39 73 24 FF 73 20 0F 47 43 10 8D 89 FC 02 00 00 50 E8 ?? ?? ?? ??"};
inline constexpr size_t kTextCallOffset = 11u;
inline constexpr Signature kDialogueCall{
    "8B 45 F8 FF 75 28 8B 5D CC FF 75 E0 8B 55 F4 FF 75 20 69 CB B4 03 00 00 FF 75 1C 56 57 03 8A AC 01 00 00 50 FF 75 DC 6A 00 FF 75 D8 E8 ?? ?? ?? ?? 84 C0 0F 84 ?? ?? ?? ?? 43 8B D3 89 5D CC"};
inline constexpr size_t kDialogueCallOffset = 44u;
inline constexpr Signature kGlyphFontArguments{
    "8D 45 D8 FF 76 08 FF 76 04 FF 36 50 E8 ?? ?? ?? ?? C7 45 FC 00 00 00 00"};
inline constexpr Signature kGlyphReturn{
    "8A 45 27 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B E5 5D C2 28 00"};
inline constexpr Signature kGlyphCoordinates{
    "8D 46 28 50 8D 96 44 01 00 00 8D 8D 18 FF FF FF E8 ?? ?? ?? ?? 8B 3E 83 C4 04 C6 46 29 01"};
inline constexpr Signature kCoordinateWriter{
    "55 8B EC 8B 41 08 56 8B 71 0C 89 02 89 72 04 8B 41 10 89 42 08 83 39 00 8B 55 08 0F 95 C0 88 02 C6 42 03 00 F3 0F 10 41 14 F3 0F 58 41 2C F3 0F 11 42 18 F3 0F 10 41 18 F3 0F 58 41 30 F3 0F 11 42 1C"};
inline constexpr Signature kMainInputCall{
    "8B 43 10 8B 73 08 50 FF 73 0C 89 85 48 FF FF FF 56 E8 ?? ?? ?? ?? 81 FE 12 01 00 00"};
inline constexpr size_t kMainInputCallOffset = 17u;
// The full loop proves the call's register source and VK_LBUTTON (index 1).
// Protected images may remove USER32's import descriptor; the recovered slot
// must still contain the caller's independently resolved USER32 export.
inline constexpr Signature kKeyboardLoop{
    "8B 1D ?? ?? ?? ?? 33 F6 BF 00 80 00 00 90 56 FF D3 66 85 C7 0F 97 C0 88 84 35 D8 FD FF FF 46 81 FE 00 01 00 00 7C E7"};
inline constexpr Signature kLeftButtonConsumer{
    "83 BF 58 C1 00 00 01 75 17 80 BD D9 FD FF FF 00 75 0E 83 EC 08 8D 8F 58 C1 00 00 E8 ?? ?? ?? ??"};
inline constexpr Signature kInputReturn{"5E 8B E5 5D C2 0C 00"};

inline bool ReadableDataSlot(const exact_lookup::LoadedPeImage& image,
                            uintptr_t instruction_operand,
                            uintptr_t* slot_rva) {
  uintptr_t address = 0u;
  return exact_lookup::DecodeAbsolute32ImageAddress(
             image, image.base + instruction_operand, &address, slot_rva) &&
         exact_lookup::SectionHasRole(
             exact_lookup::FindSectionForRva(image, *slot_rva, 4u),
             IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE) &&
         exact_lookup::IsReadableSpan(image.base + *slot_rva, 4u);
}
}  // namespace fushi_voice_hook::siglus_native_family

namespace fushi_voice_hook {

// This pure resolver neither follows external code nor installs a hook. The
// caller supplies GetProcAddress(USER32, "GetKeyState") from its own process.
inline bool ResolveSiglusNativeFamilyProfile(
    const exact_lookup::LoadedPeImage& image, uintptr_t bound_get_key_state,
    SiglusLookupProfile* out) {
  using namespace siglus_native_family;
  using siglus_family::BoundedFunctionEnd;
  using siglus_family::Unique;
  using siglus_family::UniqueWithin;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u || bound_get_key_state == 0u ||
      bound_get_key_state > UINT32_MAX) return false;

  uintptr_t glyph = 0u, dialogue = 0u, text_tail = 0u, text_caller = 0u;
  uintptr_t input = 0u, main_call = 0u, keyboard = 0u;
  uintptr_t coordinates = 0u, writer = 0u;
  if (!Unique(image, siglus_exact::kGlyphLayoutEntryPattern, &glyph) ||
      image.base[glyph + siglus_exact::kGlyphLayoutStackByteOffset] != 0xdcu ||
      !Unique(image, kDialogueCall.pattern(), &dialogue) ||
      !Unique(image, kTextTail.pattern(), &text_tail) || text_tail < 7u ||
      !Unique(image, kTextCaller.pattern(), &text_caller) ||
      !Unique(image, siglus_exact::kAnemoiInputMessageEntryPattern, &input) ||
      !Unique(image, kMainInputCall.pattern(), &main_call) ||
      !Unique(image, kKeyboardLoop.pattern(), &keyboard) ||
      !Unique(image, kGlyphCoordinates.pattern(), &coordinates) ||
      !Unique(image, kCoordinateWriter.pattern(), &writer)) return false;

  const uintptr_t text = text_tail - 7u;
  uintptr_t text_end = 0u, glyph_end = 0u, ignored = 0u;
  if (!siglus_family::ExecutableSpan(image, text, 7u) ||
      image.base[text] != 0x53u || image.base[text + 1u] != 0x8bu ||
      image.base[text + 2u] != 0x1du ||
      !ReadableDataSlot(image, text + 3u, &ignored) ||
      !UniqueWithin(image, text, BoundedFunctionEnd(image, text, 0x400u),
                    kTextReturn.pattern(), &text_end) ||
      !UniqueWithin(image, text, text_end, kTextCopy.pattern(), &ignored) ||
      !UniqueWithin(image, glyph, BoundedFunctionEnd(image, glyph, 0x1000u),
                    kGlyphReturn.pattern(), &glyph_end) ||
      !UniqueWithin(image, glyph, glyph_end,
                    siglus_family::kGlyphFastReturn.pattern(), &ignored) ||
      !UniqueWithin(image, glyph, glyph_end, kGlyphFontArguments.pattern(),
                    &ignored) ||
      coordinates < glyph ||
      coordinates + kGlyphCoordinates.bytes.size() > glyph_end ||
      !UniqueWithin(image, input, BoundedFunctionEnd(image, input, 0x50u),
                    kInputReturn.pattern(), &ignored) ||
      !UniqueWithin(image, keyboard, BoundedFunctionEnd(image, keyboard, 0x400u),
                    kLeftButtonConsumer.pattern(), &ignored)) return false;

  uintptr_t key_slot = 0u;
  uint32_t key_target = 0u;
  if (!ReadableDataSlot(image, keyboard + 2u, &key_slot)) return false;
  std::memcpy(&key_target, image.base + key_slot, sizeof(key_target));
  if (key_target != bound_get_key_state ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, dialogue + kDialogueCallOffset + 5u, glyph) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, text_caller + kTextCallOffset + 5u, text) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, main_call + kMainInputCallOffset + 5u, input) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, coordinates + 21u, writer)) return false;
  // Both TextUnion copies use the same string-assignment implementation.
  uintptr_t copy = 0u;
  if (!UniqueWithin(image, text, text_end, kTextCopy.pattern(), &copy))
    return false;
  int32_t first = 0, second = 0;
  std::memcpy(&first, image.base + text_tail + 32u, 4u);
  std::memcpy(&second, image.base + copy + 23u, 4u);
  const int64_t copy_target = static_cast<int64_t>(text_tail) + 36 + first;
  if (copy_target < 0 || static_cast<uint64_t>(copy_target) >= image.size ||
      copy_target != static_cast<int64_t>(copy) + 27 + second ||
      !siglus_family::ExecutableSpan(
          image, static_cast<uintptr_t>(copy_target), 1u)) return false;

  out->pe_machine = IMAGE_FILE_MACHINE_I386;
  out->pointer_bits = 32u;
  out->text_feed = SiglusLookupTextFeed::kNativeEcxTextUnion;
  out->glyph_layout_rva = glyph;
  out->dialogue_glyph_return_rva = dialogue + kDialogueCallOffset + 5u;
  out->exact_text_rva = text;
  out->exact_text_return_rva = text_caller + kTextCallOffset + 5u;
  out->get_key_state_return_rva = keyboard + 17u;
  out->input_message_rva = input;
  out->main_input_message_return_rva = main_call + kMainInputCallOffset + 5u;
  return true;
}
}  // namespace fushi_voice_hook
