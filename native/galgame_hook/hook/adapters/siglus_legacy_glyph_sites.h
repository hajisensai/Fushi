#pragma once
#include "siglus_autoprofile.h"

namespace fushi_voice_hook {
// Resolved code sites only. This does not prove viewport, visibility, input
// ownership, text occurrence, or support readiness. Menus can retain layout.
struct LegacyGlyphSites {
  uintptr_t glyph_entry_rva = 0;
  uintptr_t dialogue_entry_rva = 0;
  uintptr_t dialogue_glyph_return_rva = 0;
  uintptr_t text_entry_rva = 0;
  uintptr_t text_bridge_return_rva = 0;
  uintptr_t text_writer_rva = 0;
  uintptr_t owner_render_rva = 0;
};
namespace siglus_legacy_glyph {
using siglus_family::Signature;
// Independent FPO compiler/layout family: glyph self is stack slot 1, with
// 15 more DWORD slots (including a 16-byte value argument), and RET 0x40.
// Glyphs stride 0x1e0; x/y are written at +0x34/+0x38. The text string has
// an iterator proxy at +0, buffer +4, length +0x14, capacity +0x18.
// Masks cover relocated addresses and call/entry-branch displacements only.
inline constexpr Signature kGlyphEntry{
    "6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 2C 53 55 56 57 A1 ?? ?? ?? ?? 33 C4 50 8D 44 24 40 64 A3 00 00 00 00 8B 6C 24 50 80 7D 1C 00 0F 84 ?? ?? ?? ??"};
inline constexpr Signature kGlyphReturn{
    "B0 01 8B 4C 24 40 64 89 0D 00 00 00 00 59 5F 5E 5D 5B 83 C4 38 C2 40 00"};
inline constexpr Signature kGlyphFont{
    "8B 4D 08 8B 55 04 33 C0 38 44 24 64 C6 44 24 53 FF 0F 95 C0 C6 44 24 52 FF C6 44 24 51 FF C6 44 24 50 FF 50 8B 44 24 54 50 8B 45 00 51 52 50 8D 4C 24 2C 51 E8 ?? ?? ?? ??"};
inline constexpr Signature kGlyphFontSecond{
    "8D 44 24 64 50 8B 45 10 E8 ?? ?? ?? ?? 8B 08 8B 55 08 8B 45 04 57 51 8B 4D 00 52 50 51 8D 54 24 34 52 E8 ?? ?? ?? ??"};
inline constexpr Signature kGlyphCoordinates{
    "8B 4D 14 8B 45 18 03 4C 24 70 03 44 24 74 83 7D 00 01 89 4C 24 28 DB 44 24 28 89 44 24 50 89 7D 30 D9 5C 24 28 8B 54 24 28 DB 44 24 50 89 55 34 8A 54 24 6C 88 55 64 8B 94 24 88 00 00 00 D9 5C 24 2C D9 05 ?? ?? ?? ?? 8B 44 24 2C D9 5C 24 30 8B 4C 24 30 89 45 38 8B 84 24 80 00 00 00 89 4D 3C"};
inline constexpr Signature kDialogueEntry{
    "8B 86 00 01 00 00 83 EC 0C 53 55 57 33 FF 3B C7 75 06 89 7C 24 14 EB 1F 8B 8E 04 01 00 00 2B C8 B8 89 88 88 88 F7 E9 03 D1 C1 FA 08 8B C2 C1 E8 1F 03 C2 89 44 24 14 39 7C 24 14 89 7C 24 10 0F 8E B1 00 00 00"};
inline constexpr Signature kDialogueLoop{
    "8B 86 00 01 00 00 85 C0 74 21 8B 8E 04 01 00 00 2B C8 B8 89 88 88 88 F7 E9 03 D1 C1 FA 08 8B C2 C1 E8 1F 03 C2 39 44 24 10 72 05 E8 ?? ?? ?? ?? 8B 54 24 40 83 EC 10 8B C4 89 10 8B 54 24 54 89 50 04 8B 54 24 48 8B 8E 00 01 00 00 89 68 08 89 58 0C 8B 44 24 4C 50 8B 44 24 48 52 8B 54 24 48 50 8B 44 24 48 52 8B 54 24 48 6A 01 50 8B 44 24 4C 52 8B 54 24 4C 50 8B 44 24 4C 52 6A 00 03 CF 50 51 E8 ?? ?? ?? ?? 84 C0 74 26 8B 44 24 10 83 C0 01 81 C7 E0 01 00 00 3B 44 24 14 89 44 24 10 0F 8C 5A FF FF FF B0 01 5F 5D 5B 83 C4 0C C2 34 00 5F 5D 32 C0 5B 83 C4 0C C2 34 00"};
inline constexpr Signature kTextTail{
    "64 A1 00 00 00 00 50 81 EC B4 00 00 00 A1 ?? ?? ?? ?? 33 C4 89 84 24 B0 00 00 00 53 55 56 57 A1 ?? ?? ?? ?? 33 C4 50 8D 84 24 C8 00 00 00 64 A3 00 00 00 00 33 C0 8B F9 89 7C 24 24 C7 84 24 C0 00 00 00 07 00 00 00 89 84 24 BC 00 00 00 66 89 84 24 AC 00 00 00 89 84 24 D0 00 00 00 8D 44 24 50 50 E8 ?? ?? ?? ?? 8B 28 8B 48 04 89 6C 24 18 89 4C 24 1C"};
inline constexpr Signature kTextString{
    "8B 5C 24 24 8B 53 18 83 FA 08 8D 7B 04 72 04 8B 0F EB 02 8B CF 8B 43 14 03 C0 8D 34 08"};
inline constexpr Signature kTextReturn{
    "6A FF 6A 00 8D 84 24 B0 00 00 00 50 8B C3 E8 ?? ?? ?? ?? 83 BC 24 C0 00 00 00 08 72 10 8B 8C 24 AC 00 00 00 51 E8 ?? ?? ?? ?? 83 C4 04 8B 8C 24 C8 00 00 00 64 89 0D 00 00 00 00 59 5F 5E 5D 5B 8B 8C 24 B0 00 00 00 33 CC E8 ?? ?? ?? ?? 81 C4 C0 00 00 00 C3"};
inline constexpr Signature kTextBridge{
    "8B F9 85 FF C7 44 24 14 00 00 00 00 75 0E 83 7C 24 34 08 72 35 8B 44 24 20 50 EB 26 8D 4C 24 1C E8 ?? ?? ?? ?? 8D 4C 24 1C 51 E8 ?? ?? ?? ?? 83 7C 24 34 08 C6 87 FC 00 00 00 01"};
inline constexpr Signature kTextWriter{
    "56 8B B7 04 01 00 00 85 F6 7C 7A 8B 87 54 01 00 00 85 C0 74 19 8B 8F 58 01 00 00 2B C8 B8 6B 4C A4 07 F7 E9 C1 FA 03 8B C2 C1 E8 1F 03 C2 3B C6 7E 53 8B 87 54 01 00 00 85 C0 74 1D 8B 8F 58 01 00 00 2B C8 B8 6B 4C A4 07 F7 E9 C1 FA 03 8B C2 C1 E8 1F 03 C2 3B F0 72 05 E8 ?? ?? ?? ?? 8B 44 24 08 69 F6 0C 01 00 00 03 B7 54 01 00 00 6A FF 6A 00 50 8D 86 AC 00 00 00 E8 ?? ?? ?? ?? C6 86 E2 00 00 00 01 5E C2 04 00"};
inline constexpr Signature kOwnerRender{
    "8B 54 24 68 8B 8D 54 01 00 00 83 EC 10 8B C4 03 4C 24 38 89 18 89 70 04 89 50 08 8B 54 24 7C 89 50 0C 8B 45 68 8B 55 64 50 8B 44 24 58 52 8B 54 24 58 50 8B 84 24 30 01 00 00 52 8B 94 24 30 01 00 00 50 8B 44 24 48 52 53 50 8D 94 24 A0 00 00 00 52 8B F1 E8 ?? ?? ?? ?? 84 C0 74 1A 83 44 24 30 01 81 44 24 28 0C 01 00 00 8B 74 24 4C 8B 7C 24 48 E9 C7 FE FF FF"};

inline constexpr Signature kOwnerLoopHead{
    "8B 85 54 01 00 00 3B C3 75 04 33 C0 EB 19 8B 8D 58 01 00 00 2B C8 B8 6B 4C A4 07 F7 E9 C1 FA 03 8B C2 C1 E8 1F 03 C2 39 44 24 30 0F 8D 17 01 00 00"};
inline uint32_t U32(const exact_lookup::LoadedPeImage& image, uintptr_t at) {
  uint32_t value = 0;
  if (at < image.size && 4 <= image.size - at)
    std::memcpy(&value, image.base + at, 4);
  return value;
}
inline bool AddressRole(const exact_lookup::LoadedPeImage& image,
                        uintptr_t operand, DWORD required, DWORD forbidden) {
  uintptr_t absolute = 0, rva = 0;
  return siglus_family::ExecutableSpan(image, operand, 4) &&
      exact_lookup::DecodeAbsolute32ImageAddress(
          image, image.base + operand, &absolute, &rva) &&
      exact_lookup::SectionHasRole(
          exact_lookup::FindSectionForRva(image, rva, 4), required, forbidden);
}
inline bool CallTarget(const exact_lookup::LoadedPeImage& image,
                       uintptr_t call, uintptr_t* rva) {
  if (!siglus_family::ExecutableSpan(image, call, 5) ||
      image.base[call] != 0xe8) return false;
  int32_t relative = 0;
  std::memcpy(&relative, image.base + call + 1, 4);
  const int64_t target = static_cast<int64_t>(call) + 5 + relative;
  if (target < 0 || static_cast<uint64_t>(target) >= image.size ||
      !siglus_family::ExecutableSpan(image, static_cast<uintptr_t>(target), 1))
    return false;
  *rva = static_cast<uintptr_t>(target);
  return true;
}
inline bool SameCall(const exact_lookup::LoadedPeImage& image,
                     uintptr_t a, uintptr_t b) {
  uintptr_t first = 0, second = 0;
  return CallTarget(image, a, &first) && CallTarget(image, b, &second) &&
      first == second;
}
inline bool Calls(const exact_lookup::LoadedPeImage& image,
                  uintptr_t call, uintptr_t expected) {
  uintptr_t target = 0;
  return CallTarget(image, call, &target) && target == expected;
}
// Luna may already own the first five bytes of this independently recognized
// text body. Admit only its original prologue or an external direct detour;
// never follow an external pointer or treat an internal E9 as the same entry.
inline bool TextPrologue(const exact_lookup::LoadedPeImage& image,
                         uintptr_t text) {
  if (!siglus_family::ExecutableSpan(image, text, 7)) return false;
  const auto* bytes = image.base + text;
  if (bytes[0] == 0x6a && bytes[1] == 0xff && bytes[2] == 0x68)
    return AddressRole(image, text + 3, IMAGE_SCN_MEM_EXECUTE, 0);
  if (bytes[0] != 0xe9) return false;
  int32_t relative = 0;
  std::memcpy(&relative, bytes + 1, 4);
  const int64_t target = static_cast<int64_t>(text) + 5 + relative;
  return target < 0 || static_cast<uint64_t>(target) >= image.size;
}
} // namespace siglus_legacy_glyph

inline bool ResolveSiglusLegacyGlyphSites(
    const exact_lookup::LoadedPeImage& image, LegacyGlyphSites* out) {
  using namespace siglus_legacy_glyph;
  using siglus_family::Unique;
  using siglus_family::ExecutableSpan;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32) return false;
  uintptr_t glyph=0, glyph_return=0, font=0, second_font=0, coordinates=0;
  uintptr_t dialogue=0, loop=0, text_tail=0, text_string=0, text_return=0;
  uintptr_t bridge=0, writer=0, render=0, owner_loop=0;
  // Global uniqueness rejects an orphaned or duplicated alternative as well
  // as two complete candidates; addresses never come from a known image RVA.
  if (!Unique(image,kGlyphEntry.pattern(),&glyph) ||
      !Unique(image,kGlyphReturn.pattern(),&glyph_return) ||
      !Unique(image,kGlyphFont.pattern(),&font) ||
      !Unique(image,kGlyphFontSecond.pattern(),&second_font) ||
      !Unique(image,kGlyphCoordinates.pattern(),&coordinates) ||
      !Unique(image,kDialogueEntry.pattern(),&dialogue) ||
      !Unique(image,kDialogueLoop.pattern(),&loop) ||
      !Unique(image,kTextTail.pattern(),&text_tail) ||
      !Unique(image,kTextString.pattern(),&text_string) ||
      !Unique(image,kTextReturn.pattern(),&text_return) ||
      !Unique(image,kTextBridge.pattern(),&bridge) ||
      !Unique(image,kTextWriter.pattern(),&writer) ||
      !Unique(image,kOwnerRender.pattern(),&render) ||
      !Unique(image,kOwnerLoopHead.pattern(),&owner_loop) || text_tail < 7)
    return false;
  const uintptr_t text = text_tail - 7;
  // Entry's disabled branch must land at the actual RET 0x40 epilogue.
  int32_t disabled = 0;
  std::memcpy(&disabled,image.base + glyph + 49,4);
  const int64_t disabled_target = static_cast<int64_t>(glyph) + 53 + disabled;
  if (disabled_target != static_cast<int64_t>(glyph_return) ||
      glyph_return <= glyph || glyph_return - glyph > 0x1000 ||
      !ExecutableSpan(image,glyph,glyph_return + kGlyphReturn.bytes.size()-glyph) ||
      font < glyph + kGlyphEntry.bytes.size() ||
      coordinates < font + kGlyphFont.bytes.size() ||
      second_font < coordinates + kGlyphCoordinates.bytes.size() ||
      second_font + kGlyphFontSecond.bytes.size() > glyph_return ||
      // The fixed loop branch and entry's empty-vector branch land within this
      // exact body. Its self vector and increment both describe stride 0x1e0.
      loop != dialogue + 0x50 ||
      !ExecutableSpan(image,dialogue,0x50 + kDialogueLoop.bytes.size()) ||
      !Calls(image,loop + 130,glyph) ||
      !Calls(image,render + 84,dialogue) ||
      render != owner_loop + 0xc2 ||
      !ExecutableSpan(image,owner_loop,0xc2 + kOwnerRender.bytes.size()) ||
      !SameCall(image,font + 52,second_font + 34) ||
      !AddressRole(image,glyph + 3,IMAGE_SCN_MEM_EXECUTE,0) ||
      !AddressRole(image,glyph + 22,IMAGE_SCN_MEM_READ|IMAGE_SCN_MEM_WRITE,
                   IMAGE_SCN_MEM_EXECUTE) ||
      !AddressRole(image,coordinates + 68,IMAGE_SCN_MEM_READ,IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!TextPrologue(image,text) || text_return <= text ||
      text_return - text > 0x1000 ||
      !ExecutableSpan(image,text,text_return + kTextReturn.bytes.size()-text) ||
      text_string < text_tail + kTextTail.bytes.size() ||
      text_string + kTextString.bytes.size() > text_return ||
      !Calls(image,bridge + 32,text) || !Calls(image,bridge + 42,writer) ||
      // The same string assignment routine receives the transformed text and
      // writes entry+0xac in the owner's 0x10c vector. The render bridge reads
      // that same vector layout and calls the admitted dialogue walker.
      !SameCall(image,text_return + 14,writer + 121) ||
      U32(image,text_tail + 14) != U32(image,glyph + 22) ||
      U32(image,text_tail + 32) != U32(image,glyph + 22))
    return false;
  // Every other masked call is still required to target executable image code.
  uintptr_t ignored = 0;
  if (!CallTarget(image,second_font + 8,&ignored) ||
      !CallTarget(image,loop + 43,&ignored) ||
      !CallTarget(image,text_tail + 98,&ignored) ||
      !CallTarget(image,text_return + 37,&ignored) ||
      !CallTarget(image,text_return + 73,&ignored) ||
      !CallTarget(image,writer + 89,&ignored)) return false;
  out->glyph_entry_rva=glyph;
  out->dialogue_entry_rva=dialogue;
  out->dialogue_glyph_return_rva=loop + 135;
  out->text_entry_rva=text;
  out->text_bridge_return_rva=bridge + 37;
  out->text_writer_rva=writer;
  out->owner_render_rva=render;
  return true;
}
} // namespace fushi_voice_hook
