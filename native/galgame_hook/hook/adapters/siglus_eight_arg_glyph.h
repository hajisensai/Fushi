#pragma once

#include "siglus_autoprofile.h"

namespace fushi_voice_hook {

// Static compiler-family proof only. The caller must separately prove live
// owner, viewport, input and text-event identity before installing any hook.
// Return sites below describe dialogue topology; arbitrary callers of these
// shared functions are deliberately not admitted.
struct SiglusEightArgGlyphSites {
  uintptr_t glyph_entry_rva = 0;
  uintptr_t glyph_return_rva = 0;
  uintptr_t wrapper_entry_rva = 0;
  uintptr_t wrapper_glyph_return_rva = 0;
  uintptr_t message_entry_rva = 0;
  uintptr_t message_scenario_return_rva = 0;
  uintptr_t scenario_entry_rva = 0;
  uintptr_t render_entry_rva = 0;
  uintptr_t render_wrapper_returns[2] = {};
  uintptr_t font_entry_rva = 0;
  uintptr_t coordinate_writer_rva = 0;
  uintptr_t transform_entry_rva = 0;
  uintptr_t config_slot_rva = 0;
  uintptr_t manager_slot_rva = 0;
  uintptr_t message_dispatch_rva = 0;
  uintptr_t message_caller_return_rva = 0;
  uintptr_t owner_selector_rva = 0;
  uintptr_t render_group_entry_rva = 0;
  uintptr_t group_render_return_rva = 0;
};

namespace siglus_eight_arg_glyph {
using siglus_family::Signature;

// Masks are limited to direct-call displacements and PE-relocated pointers.
// Stack layouts, vector divisions/strides, branch displacements and argument
// forwarding are exact. Offsets below are within independently found functions,
// never image RVAs. This family has ret 20, not the modern ret 28/legacy ret 40.
inline constexpr Signature kGlyphEntry{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC DC 00 00 00 53 56 57 A1 ?? ?? ?? ?? 33 C5 50 8D 45 F4 64 A3 00 00 00 00 8B F1 80 7E 20 00 75 16 B0 01 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B E5 5D C2 20 00"};

inline constexpr Signature kGlyphFont{
    "A1 ?? ?? ?? ?? 33 C9 38 4D 18 C7 45 EC FF FF FF FF 0F 95 C1 39 98 84 CF 00 00 51 0F 94 C0 0F B6 C0 50 51 FF 75 EC 8D 45 D8 FF 76 08 FF 76 04 FF 36 50 E8 ?? ?? ?? ?? C7 45 FC 00 00 00 00"};

inline constexpr Signature kGlyphCoordinates{
    "8D 8D 18 FF FF FF E8 ?? ?? ?? ?? A1 ?? ?? ?? ?? 8D 8D 18 FF FF FF 8B 55 08 C7 85 18 FF FF FF 01 00 00 00 C7 85 20 FF FF FF 00 00 00 00 8B 80 58 9B A2 00 89 85 24 FF FF FF 8B 46 18 03 45 20 66 0F 6E C0 8B 46 1C 03 45 24 0F 5B C0 F3 0F 11 85 2C FF FF FF 66 0F 6E C0 8B 45 0C 0F 5B C0 89 45 94 F3 0F 11 85 30 FF FF FF E8 ?? ?? ?? ?? 8D 46 28 50 8D 96 44 01 00 00 8D 8D 18 FF FF FF E8 ?? ?? ?? ??"};

inline constexpr Signature kGlyphReturn{
    "8A C3 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B E5 5D C2 20 00"};

inline constexpr Signature kWrapper{
    "55 8B EC 83 EC 08 53 56 8B B1 1C 01 00 00 B8 71 F8 42 8A 2B B1 18 01 00 00 F7 EE 57 03 D6 89 4D FC C1 FA 09 33 FF 8B DA C1 EB 1F 03 DA 85 DB 7E 5E 33 F6 EB 0B 8D A4 24 00 00 00 00 8D 64 24 00 A1 ?? ?? ?? ?? 8B 55 1C 83 B8 84 CF 00 00 01 75 0A 8B 81 18 01 00 00 2B 54 06 08 FF 75 20 8B 89 18 01 00 00 52 FF 75 18 03 CE FF 75 14 FF 75 10 FF 75 0C 6A 00 FF 75 08 E8 ?? ?? ?? ?? 84 C0 74 19 8B 4D FC 47 81 C6 B4 03 00 00 3B FB 7C B1 B0 01 5F 5E 5B 8B E5 5D C2 1C 00 5F 5E 32 C0 5B 8B E5 5D C2 1C 00"};

inline constexpr Signature kScenarioEntry{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 1C 04 00 00 A1 ?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B D9 8B 7D 08 83 7F 10 00 8B 45 0C 89 85 E0 FB FF FF 8D 47 10 89 BD FC FB FF FF 89 85 F0 FB FF FF 0F 84 31 06 00 00 8B 8B 1C 01 00 00 B8 71 F8 42 8A 2B 8B 18 01 00 00 F7 E9 8B 85 F0 FB FF FF 03 D1 8B 8B 20 01 00 00 2B 8B 18 01 00 00 C1 FA 09 8B F2 C1 EE 1F 03 F2 03 30 B8 71 F8 42 8A F7 E9 03 D1 C1 FA 09 8B C2 C1 E8 1F 03 C2 3B C6 73 1E"};

inline constexpr Signature kScenarioString{
    "83 7F 14 08 72 04 8B 37 EB 02 8B F7"};

inline constexpr Signature kScenarioFields{
    "8B 53 68 03 53 60 8B 4B 5C 03 4B 64 83 BD 00 FC FF FF 01 8B B5 F4 FB FF FF 8B 43 6C C7 85 DC FB FF FF 00 00 00 00 0F 44 B5 DC FB FF FF 80 BB FE 00 00 00 00 89 B5 F4 FB FF FF 8B B5 00 FC FF FF 89 85 10 FC FF FF 8B 85 F4 FB FF FF 89 85 14 FC FF FF 8B 85 E4 FB FF FF 89 B5 08 FC FF FF 8B B5 E8 FB FF FF 89 85 18 FC FF FF 8B 85 04 FC FF FF 89 B5 0C FC FF FF 89 85 1C FC FF FF 89 8D 20 FC FF FF 89 95 24 FC FF FF"};

inline constexpr Signature kScenarioAppend{
    "8D 85 08 FC FF FF 50 8D 8B 18 01 00 00 E8 ?? ?? ?? ??"};

inline constexpr Signature kScenarioReturn{
    "8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B 4D F0 33 CD E8 ?? ?? ?? ?? 8B E5 5D C2 08 00"};

inline constexpr Signature kMessage{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 44 A1 ?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B DA 8B F9 C7 45 FC 00 00 00 00 85 FF 0F 84 DC 02 00 00 33 C0 C7 45 EC 07 00 00 00 C7 45 E8 00 00 00 00 66 89 45 D8 8B 75 08 C6 45 FC 01 A1 ?? ?? ?? ?? 89 98 10 03 00 00 89 B0 14 03 00 00 E8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8D 4D 10 E8 ?? ?? ?? ?? 8D 45 10 50 E8 ?? ?? ?? ?? 8B 87 60 01 00 00 85 C0 0F 88 80 00 00 00 8B 8F AC 01 00 00 B8 1D 38 70 E0 2B 8F A8 01 00 00 F7 E9 03 D1 8B 8F 60 01 00 00 C1 FA 08 8B C2 C1 E8 1F 03 C2 3B C1 7E 57 69 F1 24 01 00 00 03 B7 A8 01 00 00 80 BE FC 00 00 00 00 75 0F 83 BE F8 00 00 00 01 75 06 8B 46 50 01 46 60 8D 45 D8 8B CE 50 8D 45 10 50 E8 ?? ?? ?? ?? 80 BE FC 00 00 00 00 75 11 C7 86 F8 00 00 00 00 00 00 00 C6 86 FC 00 00 00 01 8B CF E8 ?? ?? ?? ?? 8B 75 08"};

inline constexpr Signature kRenderEntry{
    "55 8B EC 81 EC 34 01 00 00 A1 ?? ?? ?? ?? 33 C5 89 45 FC 53 56 57 8B D9 E8 ?? ?? ?? ??"};

inline constexpr Signature kRenderFirst{
    "33 C9 B8 1D 38 70 E0 89 4D EC 8B 8B AC 01 00 00 2B 8B A8 01 00 00 F7 E9 03 D1 C1 FA 08 8B C2 C1 E8 1F 03 C2 85 C0 0F 8E 97 00 00 00 8B 45 E4 8B 55 D4 03 C7 8B 7D 08 03 D6 89 45 F0 33 C0 C7 45 E8 00 00 00 00 8B 75 E8 89 55 CC 89 45 E0 8D A4 24 00 00 00 00 FF 75 F0 8B 8B A8 01 00 00 52 FF 75 0C 03 C8 8D 85 D0 FE FF FF 57 6A 00 56 50 E8 ?? ?? ?? ?? 84 C0 74 36 8B 8B AC 01 00 00 B8 1D 38 70 E0 2B 8B A8 01 00 00 81 45 E0 24 01 00 00 FF 45 EC F7 E9 03 D1 C1 FA 08 8B C2 C1 E8 1F 03 C2 8B 55 CC 39 45 EC 8B 45 E0 7C A9 EB 18 32 C0 5F 5E 5B 8B 4D FC 33 CD E8 ?? ?? ?? ?? 8B E5 5D C2 08 00"};

inline constexpr Signature kRenderSecond{
    "8B 45 D4 33 C9 03 45 CC 89 45 E8 8B 45 F0 03 C7 89 4D F0 8B 8B AC 01 00 00 2B 8B A8 01 00 00 89 45 EC B8 1D 38 70 E0 F7 E9 03 D1 C1 FA 08 8B C2 C1 E8 1F 03 C2 85 C0 7E 65 C7 45 DC 00 00 00 00 33 FF 8B 75 DC 90 FF 75 EC 8B 8B A8 01 00 00 8D 85 D0 FE FF FF FF 75 E8 03 CF FF 75 0C FF 75 08 6A 00 56 50 E8 ?? ?? ?? ?? 84 C0 0F 84 DE FE FF FF 8B 8B AC 01 00 00 B8 1D 38 70 E0 2B 8B A8 01 00 00 81 C7 24 01 00 00 FF 45 F0 F7 E9 03 D1 C1 FA 08 8B C2 C1 E8 1F 03 C2 39 45 F0 7C A8"};

inline constexpr Signature kFontEntry{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 74 53 56 57 A1 ?? ?? ?? ?? 33 C5 50 8D 45 F4 64 A3 00 00 00 00 8B 45 0C C7 45 D8 00 00 00 00 89 45 B0 8B 45 10 89 45 B4 8B 45 14 89 45 B8 8B 45 18 89 45 BC 8B 45 1C 89 45 C0 8D 45 B0 50 E8 ?? ?? ?? ??"};

inline constexpr Signature kCoordinateWriter{
    "55 8B EC 8B 41 08 89 02 8B 41 0C 89 42 04 8B 41 10 89 42 08 83 39 00 8B 55 08 0F 95 C0 88 02 C6 42 03 00 8B 41 14 89 42 18 8B 41 18 89 42 1C"};

inline constexpr Signature kTransformEntry{
    "55 8B EC 83 EC 1C 53 56 57 8B F9 8B DA 89 5D FC 89 7D F4 85 FF 0F 84 BF 04 00 00 85 DB 0F 84 B7 04 00 00 83 3F 00 74 0C"};



inline constexpr Signature kMessageDispatch{
    "83 46 60 04 8D 4D 90 8B 46 60 8B 76 64 8B 78 FC E8 ?? ?? ?? ?? 83 EC 18 C7 45 FC 03 00 00 00 8D 45 90 89 A5 50 FF FF FF 8B CC 50 E8 ?? ?? ?? ?? 6A 01 57 C6 45 FC 04 E8 ?? ?? ?? ?? 8B D6 C6 45 FC 03 8B C8 E8 ?? ?? ?? ?? 83 C4 20 C7 45 FC FF FF FF FF 8D 4D 90 E8 ?? ?? ?? ??"};

inline constexpr Signature kOwnerSelector{
    "8B 0D ?? ?? ?? ?? 81 C1 64 01 00 00 6A 01 8B 41 7C 8D 14 81 E8 ?? ?? ?? ?? 83 C4 04 C3"};

inline constexpr Signature kRenderGroup{
    "55 8B EC 53 56 8B F1 B8 FF FD 51 33 57 8B 96 48 01 00 00 2B 96 44 01 00 00 F7 EA C1 FA 0A 8B DA C1 EB 1F 03 DA 85 DB 7E 2D 33 FF EB 03 8D 49 00 8B 8E 44 01 00 00 03 CF 80 B9 A0 00 00 00 00 74 0C 6A 00 FF 75 10 6A 00 E8 ?? ?? ?? ?? 81 C7 F4 13 00 00 4B 75 DA 8B 8E BC 03 00 00 B8 B7 E1 4D 5C 2B 8E B8 03 00 00 33 FF F7 E9 C1 FA 0B 8B C2 C1 E8 1F 03 C2 8B 55 08 89 45 10 85 C0 8B 45 0C 7E 2B 33 DB 8B 8E B8 03 00 00 50 03 CB 52 E8 ?? ?? ?? ?? 84 C0 0F 84 A4 00 00 00 8B 45 0C 47 8B 55 08 81 C3 30 16 00 00 3B 7D 10 7C D7"};

inline constexpr Signature kRenderVisible{
    "80 BB 56 01 00 00 00 75 0D 83 BB 8C 01 00 00 00 0F 8C 3D 07 00 00"};

inline constexpr Signature kRenderReturn{
    "8B 4D FC B0 01 5F 5E 33 CD 5B E8 ?? ?? ?? ?? 8B E5 5D C2 08 00"};

inline constexpr size_t kGlyphFontOffset = 0xa7;
inline constexpr size_t kGlyphCoordinatesOffset = 0x19b;
inline constexpr size_t kGlyphReturnOffset = 0x820;
inline constexpr size_t kWrapperGlyphCall = 120;
inline constexpr size_t kScenarioStringOffset = 0xbd;
inline constexpr size_t kScenarioFieldsOffset = 0x3a6;
inline constexpr size_t kScenarioAppendOffset = 0x53e;
inline constexpr size_t kScenarioReturnOffset = 0x686;
inline constexpr size_t kMessageScenarioCall = 234;
inline constexpr size_t kRenderFirstOffset = 0x43b;
inline constexpr size_t kRenderSecondOffset = 0x59a;
inline constexpr size_t kRenderFirstCall = 111;
inline constexpr size_t kRenderSecondCall = 100;
inline constexpr size_t kRenderVisibleOffset = 0x15b;
inline constexpr size_t kRenderReturnOffset = 0x8ae;
inline constexpr size_t kOwnerSurfaceIndex = 0x160;
inline constexpr size_t kOwnerSurfaceBegin = 0x1a8;
inline constexpr size_t kOwnerSurfaceEnd = 0x1ac;
inline constexpr size_t kSurfaceStride = 0x124;
inline constexpr size_t kSurfaceGlyphBegin = 0x118;
inline constexpr size_t kSurfaceGlyphEnd = 0x11c;
inline constexpr size_t kSurfaceGlyphCapacity = 0x120;
inline constexpr size_t kGlyphStride = 0x3b4;
// A rendering group owns this vector. It is NOT the manager global object.
// Selection of the active/normal group remains a separate runtime admission.
inline constexpr size_t kGroupOwnerBegin = 0x3b8;
inline constexpr size_t kGroupOwnerEnd = 0x3bc;
inline constexpr size_t kOwnerStride = 0x1630;
// Render continues while visible OR while the exit animation is active.
inline constexpr size_t kOwnerVisible = 0x156;
inline constexpr size_t kOwnerExitAnimation = 0x18c;

inline bool Span(const exact_lookup::LoadedPeImage& image,
                 uintptr_t rva, size_t size) {
  return siglus_family::ExecutableSpan(image, rva, size) &&
      exact_lookup::SectionHasRole(
          exact_lookup::FindSectionForRva(image, rva, size),
          IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE);
}
inline bool At(const exact_lookup::LoadedPeImage& image, uintptr_t entry,
               size_t offset, exact_lookup::MaskedPattern pattern) {
  return entry < image.size && offset <= image.size - entry &&
      Span(image, entry + offset, pattern.size) &&
      exact_lookup::MatchesMaskedPattern(image.base + entry + offset, pattern);
}
inline bool SoleWithin(const exact_lookup::LoadedPeImage& image, uintptr_t entry,
                       size_t length, size_t offset,
                       exact_lookup::MaskedPattern pattern) {
  if (!Span(image, entry, length) || !At(image, entry, offset, pattern)) return false;
  const auto match = exact_lookup::FindUniqueMaskedPattern(image.base + entry, length, pattern);
  return match.count == 1 && match.address == image.base + entry + offset;
}
inline uint32_t Word(const exact_lookup::LoadedPeImage& image, uintptr_t at) {
  uint32_t value = 0;
  if (at < image.size && sizeof(value) <= image.size - at)
    std::memcpy(&value, image.base + at, sizeof(value));
  return value;
}
inline uintptr_t Call(const exact_lookup::LoadedPeImage& image, uintptr_t at) {
  if (!Span(image, at, 5) || image.base[at] != 0xe8) return 0;
  const int64_t target = static_cast<int64_t>(at) + 5 +
      static_cast<int32_t>(Word(image, at + 1));
  return target > 0 && static_cast<uint64_t>(target) < image.size &&
      Span(image, static_cast<uintptr_t>(target), 1)
      ? static_cast<uintptr_t>(target) : 0;
}
inline uintptr_t Address(const exact_lookup::LoadedPeImage& image,
                         uintptr_t at, bool code) {
  const uintptr_t base = image.absolute_base != 0 ? image.absolute_base
      : reinterpret_cast<uintptr_t>(image.base);
  const uint32_t va = Word(image, at);
  if (base > UINT32_MAX || va <= base || va - base >= image.size) return 0;
  const uintptr_t rva = va - base;
  if (code) return Span(image, rva, 1) ? rva : 0;
  return (va & 3u) == 0 && exact_lookup::SectionHasRole(
      exact_lookup::FindSectionForRva(image, rva, 4),
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE, IMAGE_SCN_MEM_EXECUTE)
      ? rva : 0;
}
inline bool Unique(const exact_lookup::LoadedPeImage& image,
                   exact_lookup::MaskedPattern pattern, uintptr_t* rva) {
  return siglus_family::Unique(image, pattern, rva) &&
      Span(image, *rva, pattern.size);
}

inline bool Resolve(const exact_lookup::LoadedPeImage& image,
                    SiglusEightArgGlyphSites* out) {
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 || image.section_count == 0 ||
      image.section_count > image.sections.size()) return false;
  SiglusEightArgGlyphSites s;
  if (!Unique(image, kGlyphEntry.pattern(), &s.glyph_entry_rva) ||
      !Unique(image, kWrapper.pattern(), &s.wrapper_entry_rva) ||
      !Unique(image, kScenarioEntry.pattern(), &s.scenario_entry_rva) ||
      !Unique(image, kMessage.pattern(), &s.message_entry_rva) ||
      !Unique(image, kRenderEntry.pattern(), &s.render_entry_rva) ||
      !Unique(image, kFontEntry.pattern(), &s.font_entry_rva) ||
      !Unique(image, kCoordinateWriter.pattern(), &s.coordinate_writer_rva) ||
      !Unique(image, kTransformEntry.pattern(), &s.transform_entry_rva) ||
      !Unique(image, kMessageDispatch.pattern(), &s.message_dispatch_rva) ||
      !Unique(image, kOwnerSelector.pattern(), &s.owner_selector_rva) ||
      !Unique(image, kRenderGroup.pattern(), &s.render_group_entry_rva))
    return false;
  const auto g = s.glyph_entry_rva, w = s.wrapper_entry_rva;
  const auto t = s.scenario_entry_rva, m = s.message_entry_rva;
  const auto r = s.render_entry_rva;
  if (!SoleWithin(image, g, kGlyphReturnOffset + kGlyphReturn.bytes.size(),
                  kGlyphFontOffset, kGlyphFont.pattern()) ||
      !SoleWithin(image, g, kGlyphReturnOffset + kGlyphReturn.bytes.size(),
                  kGlyphCoordinatesOffset, kGlyphCoordinates.pattern()) ||
      !At(image, g, kGlyphReturnOffset, kGlyphReturn.pattern()) ||
      !Span(image, t, kScenarioReturnOffset + kScenarioReturn.bytes.size()) ||
      !Span(image, r, kRenderReturnOffset + kRenderReturn.bytes.size()) ||
      !At(image, t, kScenarioStringOffset, kScenarioString.pattern()) ||
      !At(image, t, kScenarioFieldsOffset, kScenarioFields.pattern()) ||
      !At(image, t, kScenarioAppendOffset, kScenarioAppend.pattern()) ||
      !At(image, t, kScenarioReturnOffset, kScenarioReturn.pattern()) ||
      !At(image, r, kRenderFirstOffset, kRenderFirst.pattern()) ||
      !At(image, r, kRenderSecondOffset, kRenderSecond.pattern()) ||
      !At(image, r, kRenderVisibleOffset, kRenderVisible.pattern()) ||
      !At(image, r, kRenderReturnOffset, kRenderReturn.pattern()))
    return false;
  // These exact instructions construct glyph+4 from the parsed character,
  // glyph+8 from surface+6c, append to surface+118, and iterate stride 3b4.
  // Both message and render use owner surfaces+1a8/+1ac with stride 124.
  // Coordinate writer copies descriptor floats to glyph+40/+44.
  if (Call(image, w + kWrapperGlyphCall) != g ||
      Call(image, m + kMessageScenarioCall) != t ||
      Call(image, r + kRenderFirstOffset + kRenderFirstCall) != w ||
      Call(image, r + kRenderSecondOffset + kRenderSecondCall) != w ||
      Call(image, g + kGlyphFontOffset + 50) != s.font_entry_rva ||
      Call(image, g + kGlyphCoordinatesOffset + 105) != s.transform_entry_rva ||
      Call(image, g + kGlyphCoordinatesOffset + 126) != s.coordinate_writer_rva ||
      Call(image, s.message_dispatch_rva + 68) != m ||
      Call(image, s.message_dispatch_rva + 55) != s.owner_selector_rva ||
      Call(image, s.render_group_entry_rva + 142) != r)
    return false;
  // Every other masked direct call still has to point into executable code.
  const uintptr_t auxiliary_calls[] = {
      g + kGlyphCoordinatesOffset + 6, t + kScenarioAppendOffset + 13,
      t + kScenarioReturnOffset + 19, m + 106, m + 111, m + 119,
      m + 128, m + 267, r + 24, r + kRenderFirstOffset + 184,
      s.font_entry_rva + 81, s.message_dispatch_rva + 16,
      s.message_dispatch_rva + 43, s.message_dispatch_rva + 86,
      s.owner_selector_rva + 20, s.render_group_entry_rva + 72,
      r + kRenderReturnOffset + 10};
  for (auto at : auxiliary_calls) if (Call(image, at) == 0) return false;
  const uintptr_t seh_addresses[] = {g + 6, t + 6, m + 6, s.font_entry_rva + 6};
  for (auto at : seh_addresses) if (Address(image, at, true) == 0) return false;
  const uintptr_t cookie = Address(image, g + 27, false);
  if (cookie == 0 || Address(image, t + 24, false) != cookie ||
      Address(image, m + 21, false) != cookie ||
      Address(image, r + 10, false) != cookie ||
      Address(image, s.font_entry_rva + 24, false) != cookie) return false;
  s.config_slot_rva = Address(image, g + kGlyphFontOffset + 1, false);
  s.manager_slot_rva = Address(image, m + 90, false);
  if (s.config_slot_rva == 0 || s.manager_slot_rva == 0 ||
      s.config_slot_rva == s.manager_slot_rva ||
      s.config_slot_rva == cookie || s.manager_slot_rva == cookie ||
      Address(image, g + kGlyphCoordinatesOffset + 12, false) != s.config_slot_rva ||
      Address(image, w + 65, false) != s.config_slot_rva ||
      Address(image, s.owner_selector_rva + 2, false) != s.manager_slot_rva)
    return false;
  s.glyph_return_rva = g + kGlyphReturnOffset + kGlyphReturn.bytes.size() - 3;
  s.wrapper_glyph_return_rva = w + kWrapperGlyphCall + 5;
  s.message_scenario_return_rva = m + kMessageScenarioCall + 5;
  s.render_wrapper_returns[0] = r + kRenderFirstOffset + kRenderFirstCall + 5;
  s.render_wrapper_returns[1] = r + kRenderSecondOffset + kRenderSecondCall + 5;
  s.message_caller_return_rva = s.message_dispatch_rva + 73;
  s.group_render_return_rva = s.render_group_entry_rva + 147;
  *out = s;
  return true;
}
}  // namespace siglus_eight_arg_glyph
}  // namespace fushi_voice_hook
