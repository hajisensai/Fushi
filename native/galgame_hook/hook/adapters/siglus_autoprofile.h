#pragma once

#include "siglus_lookup.h"

namespace fushi_voice_hook::siglus_family {

// This is the measured x86 scenario/TextUnion argument ABI, not every release
// called Siglus. Addresses are recovered independently; the field offsets and
// instruction shapes below define the admitted compiler/layout family.
template <size_t N>
struct Signature {
  static constexpr size_t kSize = N / 3u;
  std::array<uint8_t, kSize> bytes = {};
  std::array<uint8_t, kSize> mask = {};
  static constexpr uint8_t Hex(char c) {
    return c >= '0' && c <= '9' ? static_cast<uint8_t>(c - '0')
                               : static_cast<uint8_t>(c - 'A' + 10);
  }
  constexpr Signature(const char (&value)[N]) {
    for (size_t i = 0; i < kSize; ++i) {
      if (value[i * 3u] != '?') {
        bytes[i] = static_cast<uint8_t>(Hex(value[i * 3u]) * 16u +
                                         Hex(value[i * 3u + 1u]));
        mask[i] = 0xffu;
      }
    }
  }
  exact_lookup::MaskedPattern pattern() const {
    return {bytes.data(), mask.data(), bytes.size()};
  }
};

// Ten stack arguments and the 0x3b4 glyph-vector stride identify the dialogue
// traversal, distinguishing the other three callers of the same glyph entry.
inline constexpr Signature kDialogueCall{
    "FF 75 28 8B 5D F8 FF 75 E0 FF 75 20 8B 83 AC 01 00 00 FF 75 1C 03 45 E4 51 56 8B 75 F4 8B C8 57 FF 75 F0 6A 00 56 E8 ?? ?? ?? ?? 84 C0 0F 84 ?? ?? ?? ?? 8B 45 EC 81 45 E4 B4 03 00 00"};
inline constexpr size_t kDialogueCallOffset = 38u;

// Start at entry+5: Luna may already own the first five bytes. The original
// prologue or a validated external E9 is checked separately, never wildcarded.
inline constexpr Signature kScenarioEntryTail{
    "68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC C4 04 00 00 A1 ?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B D9 8B 7D 08 8B 45 0C 89 BD 54 FB FF FF 89 85 38 FB FF FF 83 7F 10 00 0F 84 ?? ?? ?? ?? 8B 8B B0 01 00 00 B8 71 F8 42 8A 2B 8B AC 01 00 00"};
inline constexpr Signature kScenarioStringAbi{
    "83 7F 14 08 72 04 8B 37 EB 02 8B F7 89 B5 50 FB FF FF 8B 57 14 83 FA 08 72 04 8B 07 EB 02 8B C7"};
inline constexpr Signature kScenarioReturn{
    "8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B 4D F0 33 CD E8 ?? ?? ?? ?? 8B E5 5D C2 08 00"};

inline constexpr Signature kMainInputCall{
    "53 56 8B 75 10 8B D9 57 8B 7D 08 56 FF 75 0C 89 5C 24 5C 57 89 74 24 50 E8 ?? ?? ?? ?? 81 FF 12 01 00 00"};
inline constexpr size_t kMainInputCallOffset = 24u;
// The argument is ESI=0..255. Index 1 (VK_LBUTTON) is consumed below, rather
// than a dedicated push 1 call. EDI must come from the independently named IAT.
inline constexpr Signature kKeyboardLoop{
    "8B 3D ?? ?? ?? ?? 33 F6 8D 64 24 00 56 FF D7 C1 E8 08 24 80 88 84 35 F8 FE FF FF 46 81 FE 00 01 00 00 7C E8"};
inline constexpr Signature kLeftButtonConsumer{
    "83 3A 01 8A 85 F9 FE FF FF 88 85 F6 FE FF FF 75 0E 84 C0 78 0A 83 EC 08 8B CA E8 ?? ?? ?? ??"};
inline constexpr Signature kInputReturn{"8B E5 5D C2 0C 00"};

// self+4 and self+8 are submitted alongside the glyph kind to the font cache.
inline constexpr Signature kGlyphFontArguments{
    "8D 45 D0 FF 76 08 FF 76 04 FF 36 50 E8 ?? ?? ?? ?? C7 45 FC 00 00 00 00"};
inline constexpr Signature kGlyphFastReturn{
    "B0 01 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B E5 5D C2 28 00"};
inline constexpr Signature kGlyphReturn{
    "8A C3 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B E5 5D C2 28 00"};
// Destination argument self+0x28, then helper writes float x/y at +0x18/+0x1c:
// this proves the capture object's self+0x40/+0x44 geometry fields.
inline constexpr Signature kGlyphCoordinates{
    "8D 46 28 50 8D 96 44 01 00 00 8D 8D 08 FF FF FF E8 ?? ?? ?? ?? 8B 3E 83 C4 04 C6 46 29 01"};
inline constexpr size_t kCoordinateCallOffset = 16u;
inline constexpr Signature kCoordinateWriter{
    "55 8B EC 8B 41 08 89 02 8B 41 0C 89 42 04 8B 41 10 89 42 08 83 39 00 8B 55 08 0F 95 C0 88 02 C6 42 03 00 F3 0F 10 41 14 F3 0F 58 41 2C F3 0F 11 42 18 F3 0F 10 41 18 F3 0F 58 41 30 F3 0F 11 42 1C"};

inline bool ExecutableSpan(const exact_lookup::LoadedPeImage& image,
                           uintptr_t rva, size_t size) {
  return size != 0u && rva < image.size && size <= image.size - rva &&
         exact_lookup::SectionHasRole(
             exact_lookup::FindSectionForRva(image, rva, size),
             IMAGE_SCN_MEM_EXECUTE) &&
         exact_lookup::IsReadableSpan(image.base + rva, size);
}

inline bool Unique(const exact_lookup::LoadedPeImage& image,
                   const exact_lookup::MaskedPattern& pattern,
                   uintptr_t* rva) {
  const auto match =
      exact_lookup::FindUniquePatternInExecutableSections(image, pattern);
  if (match.count != 1u || match.address == nullptr) return false;
  *rva = static_cast<uintptr_t>(match.address - image.base);
  return true;
}

// A bounded function-body check only corroborates an independently unique
// entry. It never supplies an address by proximity to a previously measured RVA.
inline bool UniqueWithin(const exact_lookup::LoadedPeImage& image,
                         uintptr_t begin, uintptr_t end,
                         const exact_lookup::MaskedPattern& pattern,
                         uintptr_t* rva) {
  if (end <= begin || !ExecutableSpan(image, begin, end - begin)) return false;
  const auto match = exact_lookup::FindUniqueMaskedPattern(
      image.base + begin, end - begin, pattern);
  if (match.count != 1u || match.address == nullptr) return false;
  *rva = static_cast<uintptr_t>(match.address - image.base);
  return true;
}

inline uintptr_t BoundedFunctionEnd(const exact_lookup::LoadedPeImage& image,
                                    uintptr_t begin, size_t limit) {
  const auto* section = exact_lookup::FindSectionForRva(image, begin, 1u);
  if (section == nullptr || begin >= image.size) return begin;
  const uintptr_t section_end = section->rva + section->size;
  return (std::min)({begin + (std::min)(limit, image.size - begin),
                    section_end, static_cast<uintptr_t>(image.size)});
}

inline bool OriginalOrExternalDetour(const exact_lookup::LoadedPeImage& image,
                                     uintptr_t entry) {
  if (!ExecutableSpan(image, entry, 5u)) return false;
  constexpr uint8_t original[] = {0x55u, 0x8bu, 0xecu, 0x6au, 0xffu};
  if (std::memcmp(image.base + entry, original, sizeof(original)) == 0)
    return true;
  if (image.base[entry] != 0xe9u) return false;
  int32_t relative = 0;
  std::memcpy(&relative, image.base + entry + 1u, sizeof(relative));
  const int64_t target = static_cast<int64_t>(entry) + 5 + relative;
  // The already installed Luna trampoline is outside the image. Its address
  // is never followed or called here; its remaining function body must pass.
  return target < 0 || static_cast<uint64_t>(target) >= image.size;
}

}  // namespace fushi_voice_hook::siglus_family

namespace fushi_voice_hook {

// get_key_state_iat_rva must be resolved by import name (user32/GetKeyState)
// by the caller. Returning true admits this ABI only; runtime dimensions and
// glyph observations still have to pass before a provider can become ready.
inline bool ResolveSiglusFamilyProfile(
    const exact_lookup::LoadedPeImage& image, uintptr_t get_key_state_iat_rva,
    SiglusLookupProfile* out) {
  using namespace siglus_family;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u || get_key_state_iat_rva == 0u ||
      !exact_lookup::SectionHasRole(exact_lookup::FindSectionForRva(
                                       image, get_key_state_iat_rva, 4u),
                                   IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE)) {
    return false;
  }
  uintptr_t glyph = 0u, dialogue = 0u, scenario_tail = 0u, input = 0u;
  uintptr_t main_call = 0u, keyboard = 0u, coordinates = 0u, writer = 0u;
  if (!Unique(image, siglus_exact::kGlyphLayoutEntryPattern, &glyph) ||
      !siglus_exact::IsMeasuredGlyphStackSize(image.base + glyph) ||
      !Unique(image, kDialogueCall.pattern(), &dialogue) ||
      !Unique(image, kScenarioEntryTail.pattern(), &scenario_tail) ||
      !Unique(image, siglus_exact::kSprbInputMessageEntryPattern, &input) ||
      !Unique(image, kMainInputCall.pattern(), &main_call) ||
      !Unique(image, kKeyboardLoop.pattern(), &keyboard) ||
      !Unique(image, kGlyphCoordinates.pattern(), &coordinates) ||
      !Unique(image, kCoordinateWriter.pattern(), &writer) ||
      scenario_tail < 5u) {
    return false;
  }
  const uintptr_t scenario = scenario_tail - 5u;
  uintptr_t glyph_end = 0u, ignored = 0u, scenario_end = 0u;
  const uintptr_t glyph_limit = BoundedFunctionEnd(image, glyph, 0x1000u);
  const uintptr_t scenario_limit =
      BoundedFunctionEnd(image, scenario, 0x1000u);
  if (!UniqueWithin(image, glyph, glyph_limit, kGlyphReturn.pattern(),
                    &glyph_end) ||
      !UniqueWithin(image, glyph, glyph_end, kGlyphFastReturn.pattern(),
                    &ignored) ||
      !UniqueWithin(image, glyph, glyph_end, kGlyphFontArguments.pattern(),
                    &ignored) ||
      coordinates < glyph ||
      coordinates + kGlyphCoordinates.bytes.size() > glyph_end ||
      !UniqueWithin(image, scenario, scenario_limit, kScenarioReturn.pattern(),
                    &scenario_end) ||
      !UniqueWithin(image, scenario, scenario_end, kScenarioStringAbi.pattern(),
                    &ignored) ||
      !OriginalOrExternalDetour(image, scenario) ||
      !UniqueWithin(image, input, BoundedFunctionEnd(image, input, 0x50u),
                    kInputReturn.pattern(), &ignored) ||
      !UniqueWithin(image, keyboard,
                    BoundedFunctionEnd(image, keyboard, 0x100u),
                    kLeftButtonConsumer.pattern(), &ignored)) {
    return false;
  }
  uintptr_t observed_iat = 0u, observed_iat_rva = 0u;
  if (!exact_lookup::DecodeAbsolute32ImageAddress(
          image, image.base + keyboard + 2u, &observed_iat,
          &observed_iat_rva) ||
      observed_iat_rva != get_key_state_iat_rva ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, dialogue + kDialogueCallOffset + 5u, glyph) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, main_call + kMainInputCallOffset + 5u, input) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, coordinates + kCoordinateCallOffset + 5u, writer)) {
    return false;
  }
  out->pe_machine = IMAGE_FILE_MACHINE_I386;
  out->pointer_bits = 32u;
  out->text_feed = SiglusLookupTextFeed::kLunaScenarioLane;
  out->glyph_layout_rva = glyph;
  out->dialogue_glyph_return_rva = dialogue + kDialogueCallOffset + 5u;
  out->exact_text_rva = scenario;
  out->get_key_state_return_rva = keyboard + 15u;
  out->input_message_rva = input;
  out->main_input_message_return_rva = main_call + kMainInputCallOffset + 5u;
  // No executable digest or guessed viewport becomes part of admission.
  return true;
}

}  // namespace fushi_voice_hook
