#pragma once

#include "siglus_autoprofile.h"

namespace fushi_voice_hook::siglus_legacy_input_viewport {
namespace ex = exact_lookup;
namespace family = siglus_family;

// Structural sites only. This does not admit a renderer, text occurrence,
// menu visibility, or an input lease. The caller must independently resolve
// the four named user32 exports and verify their live IAT bindings.
struct Imports {
  uintptr_t keyboard_state = 0;    // GetKeyboardState, BOOL WINAPI(BYTE*)
  uintptr_t cursor_position = 0;   // GetCursorPos
  uintptr_t active_window = 0;     // GetActiveWindow
  uintptr_t screen_to_client = 0;  // ScreenToClient
};
struct Sites {
  uintptr_t sampler = 0;
  uintptr_t keyboard_state_return = 0;
  uintptr_t message = 0;  // ECX=lparam, EDX=wparam, stack message; ret 4.
  uintptr_t main_message_handler = 0;
  uintptr_t main_message_return = 0;
  uintptr_t main_sampler_return = 0;
  uintptr_t config_slot = 0;
  uintptr_t owner_slot = 0;
  uintptr_t input_slot = 0;
  uintptr_t window_slot = 0;
  // Necessary rejection predicates, not a complete visibility admission.
  uintptr_t modal_slot = 0;
  uintptr_t hidden_slot = 0;
  uintptr_t auxiliary_visibility_slot = 0;
};
inline constexpr uint32_t kConfigWidth = 0x90;
inline constexpr uint32_t kConfigHeight = 0x94;
inline constexpr uint32_t kConfigOwner = 0xb86f88;
inline constexpr uint32_t kOwnerDesignWidth = 0x38aa0;
inline constexpr uint32_t kOwnerDesignHeight = 0x38aa4;
inline constexpr uint32_t kOwnerViewportX = 0x38aa8;
inline constexpr uint32_t kOwnerViewportY = 0x38aac;
inline constexpr uint32_t kOwnerViewportWidth = 0x38ab8;
inline constexpr uint32_t kOwnerViewportHeight = 0x38abc;
inline constexpr uint32_t kModalByte = 0xac;
inline constexpr uint32_t kHiddenByte = 2;
inline constexpr uint32_t kOwnerModal = 0x38a98;
inline constexpr uint32_t kOwnerHidden = 0x38ed4;
inline constexpr uint32_t kOwnerLogByte = 0x3c35c;
inline constexpr uint32_t kOwnerInput = 0x359d0;
inline constexpr uint32_t kOwnerWindow = 0xf8;

// Absolute operands and external relative CALLs are relocated; all ABI,
// frame, dispatch, key-buffer indexing and coordinate arithmetic bytes remain
// exact. The relocated control-flow and data edges are checked below.
inline constexpr family::Signature kSampler{
    "81 EC 18 01 00 00 A1 ?? ?? ?? ?? 33 C4 89 84 24 10 01 00 00 53 56 8B 35 "
    "?? ?? ?? ?? 57 8D 44 24 10 33 DB 50 89 5C 24 14 89 5C 24 18 FF 15 ?? ?? "
    "?? ?? 8B 4C 24 10 8B 54 24 14 68 FF 00 00 00 8D 44 24 1D 53 50 89 8E 30 "
    "10 00 00 89 96 34 10 00 00 88 5C 24 24 E8 ?? ?? ?? ?? 83 C4 0C FF 15 ?? "
    "?? ?? ?? 85 C0 74 0B 8D 4C 24 18 51 FF 15 ?? ?? ?? ?? BF 01 00 00 00 39 "
    "BE 38 10 00 00 BA 02 00 00 00 75 29 F6 44 24 19 80 75 22 39 9E 40 10 00 "
    "00 89 9E 38 10 00 00 75 06 89 BE 40 10 00 00 39 BE 44 10 00 00 75 06 89 "
    "96 44 10 00 00 39 BE 48 10 00 00 75 29 F6 44 24 1A 80 75 22 39 9E 50 10 "
    "00 00 89 9E 48 10 00 00 75 06 89 BE 50 10 00 00 39 BE 54 10 00 00 75 06 "
    "89 96 54 10 00 00 33 C9 8D 86 6C 10 00 00 39 78 F4 75 18 F6 44 0C 18 80 "
    "75 11 39 58 FC 89 58 F4 75 03 89 78 FC 39 38 75 02 89 10 39 78 04 75 1A "
    "F6 44 0C 19 80 75 13 89 58 04 39 58 0C 75 03 89 78 0C 39 78 10 75 03 89 "
    "50 10 39 78 14 75 1A F6 44 0C 1A 80 75 13 89 58 14 39 58 1C 75 03 89 78 "
    "1C 39 78 20 75 03 89 50 20 39 78 24 75 1A F6 44 0C 1B 80 75 13 89 58 24 "
    "39 58 2C 75 03 89 78 2C 39 78 30 75 03 89 50 30 83 C1 04 83 C0 40 81 F9 "
    "00 01 00 00 0F 8C 74 FF FF FF E8 ?? ?? ?? ?? 0F B6 54 24 19 80 E2 80 32 "
    "C0 3A C2 0F B6 54 24 1A 1B C9 F7 D9 80 E2 80 3A C2 89 4E 08 1B C9 F7 D9 "
    "89 4E 18 33 C0 83 C6 30 0F B6 54 04 18 80 E2 80 32 C9 3A CA 1B D2 F7 DA "
    "89 16 03 C7 83 C6 10 3D 00 01 00 00 7C E2 8B 8C 24 1C 01 00 00 5F 5E 5B "
    "33 CC E8 ?? ?? ?? ?? 81 C4 18 01 00 00 C3"};
inline constexpr family::Signature kMessage{
    "56 8B 35 ?? ?? ?? ?? 57 8B 7C 24 0C 81 FF 01 02 00 00 77 66 74 36 8D 87 "
    "00 FF FF FF 83 F8 05 0F 87 A4 00 00 00 FF 24 85 ?? ?? ?? ?? 8D BE 60 10 "
    "00 00 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8D BE 60 10 00 00 E8 ?? ?? ?? ?? 5F "
    "5E C2 04 00 83 BE 3C 10 00 00 00 B8 01 00 00 00 89 86 38 10 00 00 75 06 "
    "89 86 3C 10 00 00 83 BE 44 10 00 00 00 75 5A 5F 89 86 44 10 00 00 5E C2 "
    "04 00 8D 87 FE FD FF FF 83 F8 08 77 44 FF 24 85 ?? ?? ?? ?? 8D 86 38 10 "
    "00 00 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8D 86 48 10 00 00 E8 ?? ?? ?? ?? 5F "
    "5E C2 04 00 8D 86 48 10 00 00 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8D BE 58 10 "
    "00 00 8B C2 E8 ?? ?? ?? ?? 5F 5E C2 04 00 8B FF"};
inline constexpr family::Signature kMainCall{
    "53 8B 5C 24 08 55 8B 6C 24 10 56 57 8B F1 8B 4C 24 1C 53 8B D5 E8 ?? ?? "
    "?? ?? 81 FB 04 01 00 00"};
inline constexpr family::Signature kNormalize{
    "A1 ?? ?? ?? ?? 68 30 10 00 00 50 8D 9D 30 7A 03 00 53 E8 ?? ?? ?? ?? 83 "
    "C4 0C E8 ?? ?? ?? ?? 8B F5 E8 ?? ?? ?? ?? 8B FD E8 ?? ?? ?? ?? A1 ?? ?? "
    "?? ?? 8B 08 8B 50 04 89 4C 24 2C 8B 0D ?? ?? ?? ?? 8D 44 24 2C 89 54 24 "
    "30 8B 51 04 50 52 FF 15 ?? ?? ?? ?? 8B 44 24 2C 8B 0D ?? ?? ?? ?? 89 01 "
    "8B 54 24 30 89 51 04 2B 85 A8 8A 03 00 33 F6 0F AF 85 A0 8A 03 00 99 F7 "
    "BD B8 8A 03 00 89 01 8B 41 04 2B 85 AC 8A 03 00 0F AF 85 A4 8A 03 00 99 "
    "F7 BD BC 8A 03 00 89 41 04"};
inline constexpr family::Signature kDesign{
    "A1 ?? ?? ?? ?? 88 9D 99 8A 03 00 8A 51 4D 88 95 9A 8A 03 00 89 BD 9C 8A "
    "03 00 8B 90 90 00 00 00 89 95 A0 8A 03 00 8B 90 94 00 00 00 89 95 A4 8A "
    "03 00 33 D2 89 95 A8 8A 03 00 89 95 B0 8A 03 00 89 9D AC 8A 03 00 89 9D "
    "B4 8A 03 00 8B 90 90 00 00 00 89 95 B8 8A 03 00 8B 90 94 00 00 00 89 95 "
    "BC 8A 03 00 8B 90 90 00 00 00 89 95 C0 8A 03 00 8B 90 94 00 00 00 89 95 "
    "C4 8A 03 00 8B 90 90 00 00 00 89 95 C8 8A 03 00 8B 90 94 00 00 00 89 95 "
    "CC 8A 03 00"};
inline constexpr family::Signature kOwner{
    "8B 84 24 94 00 00 00 8D 88 1C 6F B8 00 8D 90 38 6F B8 00 8D A8 88 6F B8 "
    "00 A3 ?? ?? ?? ?? 89 0D ?? ?? ?? ?? 89 15 ?? ?? ?? ?? 89 2D ?? ?? ?? ??"};
inline constexpr family::Signature kVisibility{
    "A1 ?? ?? ?? ?? 80 B8 AC 00 00 00 00 74 03 32 C0 C3 8B 0D ?? ?? ?? ?? 80 "
    "79 5C 00 75 F1 8B 15 ?? ?? ?? ?? 80 7A 02 00 75 E5 E8 ?? ?? ?? ?? 84 C0 "
    "0F 94 C0 C3"};

inline constexpr family::Signature kAliases{
    "8D BE 98 8A 03 00 89 5F 08 89 5F 0C 89 5F 10 89 5F 14 89 5F 18 89 5F 1C "
    "89 5F 20 89 5F 24 89 5F 28 89 5F 2C 89 5F 30 89 5F 34 89 5F 3C 89 5F 40 "
    "89 5F 68 89 5F 6C 89 5F 70 89 5F 74 89 AF A0 00 00 00 89 9F 9C 00 00 00 "
    "66 89 9F 8C 00 00 00 8D 86 18 8C 03 00 E8 ?? ?? ?? ?? 8D 86 84 8D 03 00 "
    "50 C6 44 24 30 0B E8 ?? ?? ?? ?? 8D 86 24 8F 03 00 50 C6 44 24 30 0C E8 "
    "?? ?? ?? ?? 8D 86 24 91 03 00 50 C6 44 24 30 0D E8 ?? ?? ?? ?? 89 9E B4 "
    "91 03 00 89 9E B8 91 03 00 89 9E BC 91 03 00 89 9E C4 91 03 00 89 9E C8 "
    "91 03 00 89 9E CC 91 03 00 89 9E 00 92 03 00 89 9E 04 92 03 00 89 9E 08 "
    "92 03 00 89 9E 10 92 03 00 89 9E 14 92 03 00 C6 44 24 2C 12 88 5C 24 20 "
    "8B 54 24 20 52 53 8D 8E 1C 92 03 00 89 9E 18 92 03 00 E8 ?? ?? ?? ?? 89 "
    "9E 20 92 03 00 8D AE 24 92 03 00 C7 85 80 00 00 00 07 00 00 00 89 5D 7C "
    "6A 5C 66 89 5D 6C 8D 45 0C 53 50 89 5D 00 89 5D 04 89 5D 08 E8 ?? ?? ?? "
    "?? 83 C4 0C C6 45 23 80 8D 86 A8 92 03 00 50 C6 44 24 30 14 E8 ?? ?? ?? "
    "?? C7 86 A8 92 03 00 ?? ?? ?? ?? 8D 86 24 93 03 00 50 C6 44 24 30 15 E8 "
    "?? ?? ?? ?? 8D 86 EC 93 03 00 50 C6 44 24 30 16 E8 ?? ?? ?? ?? C7 86 EC "
    "93 03 00 ?? ?? ?? ?? C6 44 24 2C 17 E8 ?? ?? ?? ?? 89 86 6C 94 03 00 C6 "
    "40 45 01 8B 86 6C 94 03 00 89 40 04 8B 86 6C 94 03 00 89 00 8B 86 6C 94 "
    "03 00 89 40 08 89 9E 70 94 03 00 89 9E 78 94 03 00 89 9E 7C 94 03 00 89 "
    "9E 80 94 03 00 8D 86 84 94 03 00 50 C6 44 24 30 19 E8 ?? ?? ?? ?? 89 9E "
    "A4 94 03 00 89 9E A8 94 03 00 89 9E AC 94 03 00 89 9E B4 94 03 00 89 9E "
    "B8 94 03 00 89 9E BC 94 03 00 89 9E C4 94 03 00 89 9E C8 94 03 00 89 9E "
    "CC 94 03 00 89 9E D0 94 03 00 89 9E D4 94 03 00 89 9E 08 95 03 00 89 9E "
    "0C 95 03 00 89 9E 10 95 03 00 89 9E 18 95 03 00 89 9E 1C 95 03 00 89 9E "
    "20 95 03 00 89 9E 28 95 03 00 89 9E 2C 95 03 00 89 9E 30 95 03 00 8D 86 "
    "34 95 03 00 C6 44 24 2C 20 E8 ?? ?? ?? ?? 8D 86 64 A5 03 00 E8 ?? ?? ?? "
    "?? 8D 86 34 95 03 00 E8 ?? ?? ?? ?? 8D 86 94 B5 03 00 50 E8 ?? ?? ?? ?? "
    "89 9E E8 B5 03 00 89 9E EC B5 03 00 89 9E F0 B5 03 00 89 9E FC B5 03 00 "
    "89 9E 00 B6 03 00 89 9E 04 B6 03 00 C6 44 24 2C 23 8D 86 1C B6 03 00 50 "
    "89 9E 08 B6 03 00 89 9E 0C B6 03 00 89 9E 10 B6 03 00 89 9E 14 B6 03 00 "
    "89 9E 18 B6 03 00 E8 ?? ?? ?? ?? 8D 86 64 BD 03 00 50 C6 44 24 30 24 E8 "
    "?? ?? ?? ?? C7 86 64 BD 03 00 ?? ?? ?? ?? C6 44 24 2C 25 8D 86 E0 BD 03 "
    "00 50 E8 ?? ?? ?? ?? C7 86 E0 BD 03 00 ?? ?? ?? ?? 8D 86 5C BE 03 00 50 "
    "C6 44 24 30 26 E8 ?? ?? ?? ?? C7 86 5C BE 03 00 ?? ?? ?? ?? 8D 86 D8 BE "
    "03 00 50 C6 44 24 30 27 E8 ?? ?? ?? ?? 8D 86 B0 C0 03 00 50 C6 44 24 30 "
    "28 E8 ?? ?? ?? ?? C7 86 B0 C0 03 00 ?? ?? ?? ?? 89 9E 68 C1 03 00 8D 86 "
    "6C C1 03 00 50 C6 44 24 30 29 E8 ?? ?? ?? ?? C7 86 6C C1 03 00 ?? ?? ?? "
    "?? 8D 86 E8 C1 03 00 50 C6 44 24 30 2A E8 ?? ?? ?? ?? C7 86 E8 C1 03 00 "
    "?? ?? ?? ?? 8D 86 64 C2 03 00 50 C6 44 24 30 2B E8 ?? ?? ?? ?? C7 86 64 "
    "C2 03 00 ?? ?? ?? ?? C7 86 F8 C2 03 00 07 00 00 00 89 9E F4 C2 03 00 66 "
    "89 9E E4 C2 03 00 8D 86 00 C3 03 00 50 C6 44 24 30 2C E8 ?? ?? ?? ?? 8D "
    "86 58 FA 03 00 50 C6 44 24 30 2D E8 ?? ?? ?? ?? C7 86 20 FC 03 00 07 00 "
    "00 00 89 9E 1C FC 03 00 66 89 9E 0C FC 03 00 8D 86 2C FC 03 00 50 C6 44 "
    "24 30 2F E8 ?? ?? ?? ?? 8D 86 64 FF 03 00 50 C6 44 24 30 30 E8 ?? ?? ?? "
    "?? C7 86 64 FF 03 00 ?? ?? ?? ?? 8D 86 E0 FF 03 00 50 C6 44 24 30 31 E8 "
    "?? ?? ?? ?? C7 86 E0 FF 03 00 ?? ?? ?? ?? 8D 86 5C 00 04 00 50 C6 44 24 "
    "30 32 E8 ?? ?? ?? ?? C7 86 5C 00 04 00 ?? ?? ?? ?? C6 44 24 2C 33 8D 86 "
    "DC 00 04 00 50 E8 ?? ?? ?? ?? 8D 86 F8 00 00 00 A3 ?? ?? ?? ?? 8D 86 C4 "
    "0C 00 00 A3 ?? ?? ?? ?? 8D 86 60 0D 00 00 A3 ?? ?? ?? ?? 8D 86 D0 59 03 "
    "00 A3 ?? ?? ?? ?? 8D 86 30 7A 03 00 A3 ?? ?? ?? ?? 8D 86 70 8A 03 00 A3 "
    "?? ?? ?? ?? 8D 86 18 8C 03 00 A3 ?? ?? ?? ?? 8D 86 84 8D 03 00 A3 ?? ?? "
    "?? ?? 8D 86 24 8F 03 00 A3 ?? ?? ?? ?? 8D 86 24 91 03 00 A3 ?? ?? ?? ?? "
    "8D 86 A4 91 03 00 A3 ?? ?? ?? ?? 8D 86 D0 91 03 00 A3 ?? ?? ?? ?? 8D 86 "
    "10 92 03 00 A3 ?? ?? ?? ?? 8D 86 18 92 03 00 A3 ?? ?? ?? ?? 8D 86 A8 92 "
    "03 00 A3 ?? ?? ?? ?? 8D 86 24 93 03 00 A3 ?? ?? ?? ?? 8D 86 EC 93 03 00 "
    "A3 ?? ?? ?? ?? 8D 86 68 94 03 00 A3 ?? ?? ?? ?? 8D 86 74 94 03 00 A3 ?? "
    "?? ?? ?? 8D 86 84 94 03 00 A3 ?? ?? ?? ?? 8D 86 A0 94 03 00 A3 ?? ?? ?? "
    "?? 8D 86 B0 94 03 00 A3 ?? ?? ?? ?? 8D 86 C0 94 03 00 A3 ?? ?? ?? ?? 8D "
    "86 D8 94 03 00 A3 ?? ?? ?? ?? 8D 86 14 95 03 00 A3 ?? ?? ?? ?? 8D 86 24 "
    "95 03 00 A3 ?? ?? ?? ?? 8D 86 34 95 03 00 A3 ?? ?? ?? ?? 8D 86 94 B5 03 "
    "00 A3 ?? ?? ?? ?? 8D 86 E4 B5 03 00 A3 ?? ?? ?? ?? 8D 86 08 B6 03 00 A3 "
    "?? ?? ?? ?? 8D 86 60 8A 03 00 A3 ?? ?? ?? ?? 8D 86 1C B6 03 00 A3 ?? ?? "
    "?? ?? 8D 86 64 BD 03 00 A3 ?? ?? ?? ?? 8D 86 E0 BD 03 00 A3 ?? ?? ?? ?? "
    "8D 86 5C BE 03 00 8D 8E 90 8A 03 00 8D 96 D4 8E 03 00 A3 ?? ?? ?? ?? 88 "
    "9E 68 05 04 00 89 0D ?? ?? ?? ?? 89 3D ?? ?? ?? ?? 89 15 ?? ?? ?? ??"};
inline constexpr family::Signature kInputGate{
    "8B 44 24 14 80 B8 44 8B 03 00 00 0F 85 03 01 00 00 80 B8 5C C3 03 00 00 "
    "0F 85 F6 00 00 00 8D B0 B8 FE 03 00 E8 ?? ?? ?? ?? 83 F8 02 0F 84 E2 00 "
    "00 00 83 F8 03 0F 84 D9 00 00 00 8B 0D ?? ?? ?? ?? 80 79 02 00 0F 85 C9 "
    "00 00 00 8B 15 ?? ?? ?? ?? 80 BA E9 01 00 00 00 0F 85 B6 00 00 00"};

inline uint32_t U32(const ex::LoadedPeImage& image, uintptr_t rva) {
  uint32_t out = 0;
  std::memcpy(&out, image.base + rva, sizeof(out));
  return out;
}
inline bool Span(const ex::LoadedPeImage& image, uintptr_t rva, size_t size,
                 uint32_t required, uint32_t excluded = 0) {
  return rva < image.size && size <= image.size - rva &&
         ex::SectionHasRole(ex::FindSectionForRva(image, rva, size), required,
                            excluded) &&
         ex::IsReadableSpan(image.base + rva, size);
}
inline uintptr_t Address(const ex::LoadedPeImage& image, uintptr_t operand) {
  if (!Span(image, operand, 4, IMAGE_SCN_MEM_READ)) return 0;
  const uintptr_t base = image.absolute_base != 0
                             ? image.absolute_base
                             : reinterpret_cast<uintptr_t>(image.base);
  const uint32_t value = U32(image, operand);
  return value >= base && value - base < image.size ? value - base : 0;
}
inline uintptr_t Slot(const ex::LoadedPeImage& image, uintptr_t operand) {
  const auto slot = Address(image, operand);
  return slot != 0 && (slot & 3u) == 0 &&
                 Span(image, slot, 4, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,
                      IMAGE_SCN_MEM_EXECUTE)
             ? slot
             : 0;
}
inline uintptr_t Call(const ex::LoadedPeImage& image, uintptr_t operand) {
  if (operand == 0 ||
      !Span(image, operand - 1, 5,
            IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE) ||
      image.base[operand - 1] != 0xe8)
    return 0;
  int32_t delta = 0;
  std::memcpy(&delta, image.base + operand, sizeof(delta));
  const int64_t target = static_cast<int64_t>(operand) + 4 + delta;
  return target > 0 && static_cast<uint64_t>(target) < image.size &&
                 Span(image, static_cast<uintptr_t>(target), 1,
                      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE)
             ? static_cast<uintptr_t>(target)
             : 0;
}
inline bool Import(const ex::LoadedPeImage& image, uintptr_t operand,
                   uintptr_t expected) {
  return expected != 0 && Address(image, operand) == expected &&
         (expected & 3u) == 0 &&
         Span(image, expected, 4, IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_EXECUTE);
}
inline bool Resolve(const ex::LoadedPeImage& image, const Imports& imports,
                    Sites* output) {
  if (output == nullptr) return false;
  *output = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 || image.size < 4 ||
      image.section_count > image.sections.size())
    return false;
  uintptr_t sampler = 0, message = 0, main = 0, norm = 0, design = 0, owner = 0,
            visible = 0;
  uintptr_t aliases = 0, gate = 0;
  if (!family::Unique(image, kSampler.pattern(), &sampler) ||
      !family::Unique(image, kMessage.pattern(), &message) ||
      !family::Unique(image, kMainCall.pattern(), &main) ||
      !family::Unique(image, kNormalize.pattern(), &norm) ||
      !family::Unique(image, kDesign.pattern(), &design) ||
      !family::Unique(image, kOwner.pattern(), &owner) ||
      !family::Unique(image, kVisibility.pattern(), &visible) ||
      !family::Unique(image, kAliases.pattern(), &aliases) ||
      !family::Unique(image, kInputGate.pattern(), &gate))
    return false;
  if (!Import(image, sampler + 110, imports.keyboard_state) ||
      !Import(image, sampler + 46, imports.cursor_position) ||
      !Import(image, sampler + 95, imports.active_window) ||
      !Import(image, norm + 80, imports.screen_to_client) ||
      Call(image, main + 22) != message || Call(image, norm + 27) != sampler)
    return false;
  const auto input = Slot(image, sampler + 24);
  const auto config = Slot(image, design + 1);
  const auto manager = Slot(image, owner + 44);
  const auto window = Slot(image, norm + 61);
  const auto modal = Slot(image, visible + 1);
  const auto auxiliary = Slot(image, visible + 19);
  const auto hidden = Slot(image, visible + 31);
  if (!input || !config || !manager || !window || !modal || !auxiliary ||
      !hidden || Slot(image, message + 3) != input ||
      Slot(image, norm + 1) != input || Slot(image, norm + 46) != input ||
      Slot(image, norm + 90) != input || Slot(image, owner + 26) != config ||
      !Slot(image, owner + 32) || !Slot(image, owner + 38))
    return false;
  // The complete constructor fragment preserves ESI=owner and EDI=owner+38a98
  // through the eventual alias writes; it cannot borrow a nearby unrelated
  // initialization block. The hotkey gate independently consumes the same
  // hidden slot and the owner's modal/log fields before normal input handling.
  if (Slot(image, aliases + 1121) != window ||
      Slot(image, aliases + 1154) != input ||
      Slot(image, aliases + 1525) != modal ||
      Slot(image, aliases + 1531) != hidden ||
      Slot(image, gate + 61) != hidden ||
      Slot(image, gate + 77) != Slot(image, aliases + 1209) ||
      !Call(image, gate + 37))
    return false;
  if (!Call(image, aliases + 86)) return false;
  if (!Call(image, aliases + 103)) return false;
  if (!Call(image, aliases + 120)) return false;
  if (!Call(image, aliases + 137)) return false;
  if (!Call(image, aliases + 235)) return false;
  if (!Call(image, aliases + 285)) return false;
  if (!Call(image, aliases + 309)) return false;
  if (!Span(image, Address(image, aliases + 319), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 336)) return false;
  if (!Call(image, aliases + 353)) return false;
  if (!Span(image, Address(image, aliases + 363), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 373)) return false;
  if (!Call(image, aliases + 450)) return false;
  if (!Call(image, aliases + 586)) return false;
  if (!Call(image, aliases + 597)) return false;
  if (!Call(image, aliases + 608)) return false;
  if (!Call(image, aliases + 620)) return false;
  if (!Call(image, aliases + 703)) return false;
  if (!Call(image, aliases + 720)) return false;
  if (!Span(image, Address(image, aliases + 730), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 747)) return false;
  if (!Span(image, Address(image, aliases + 757), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 774)) return false;
  if (!Span(image, Address(image, aliases + 784), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 801)) return false;
  if (!Call(image, aliases + 818)) return false;
  if (!Span(image, Address(image, aliases + 828), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 851)) return false;
  if (!Span(image, Address(image, aliases + 861), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 878)) return false;
  if (!Span(image, Address(image, aliases + 888), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 905)) return false;
  if (!Span(image, Address(image, aliases + 915), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 955)) return false;
  if (!Call(image, aliases + 972)) return false;
  if (!Call(image, aliases + 1012)) return false;
  if (!Call(image, aliases + 1029)) return false;
  if (!Span(image, Address(image, aliases + 1039), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 1056)) return false;
  if (!Span(image, Address(image, aliases + 1066), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 1083)) return false;
  if (!Span(image, Address(image, aliases + 1093), 4, IMAGE_SCN_MEM_READ,
            IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE))
    return false;
  if (!Call(image, aliases + 1110)) return false;
  if (!Slot(image, aliases + 1121)) return false;
  if (!Slot(image, aliases + 1132)) return false;
  if (!Slot(image, aliases + 1143)) return false;
  if (!Slot(image, aliases + 1154)) return false;
  if (!Slot(image, aliases + 1165)) return false;
  if (!Slot(image, aliases + 1176)) return false;
  if (!Slot(image, aliases + 1187)) return false;
  if (!Slot(image, aliases + 1198)) return false;
  if (!Slot(image, aliases + 1209)) return false;
  if (!Slot(image, aliases + 1220)) return false;
  if (!Slot(image, aliases + 1231)) return false;
  if (!Slot(image, aliases + 1242)) return false;
  if (!Slot(image, aliases + 1253)) return false;
  if (!Slot(image, aliases + 1264)) return false;
  if (!Slot(image, aliases + 1275)) return false;
  if (!Slot(image, aliases + 1286)) return false;
  if (!Slot(image, aliases + 1297)) return false;
  if (!Slot(image, aliases + 1308)) return false;
  if (!Slot(image, aliases + 1319)) return false;
  if (!Slot(image, aliases + 1330)) return false;
  if (!Slot(image, aliases + 1341)) return false;
  if (!Slot(image, aliases + 1352)) return false;
  if (!Slot(image, aliases + 1363)) return false;
  if (!Slot(image, aliases + 1374)) return false;
  if (!Slot(image, aliases + 1385)) return false;
  if (!Slot(image, aliases + 1396)) return false;
  if (!Slot(image, aliases + 1407)) return false;
  if (!Slot(image, aliases + 1418)) return false;
  if (!Slot(image, aliases + 1429)) return false;
  if (!Slot(image, aliases + 1440)) return false;
  if (!Slot(image, aliases + 1451)) return false;
  if (!Slot(image, aliases + 1462)) return false;
  if (!Slot(image, aliases + 1473)) return false;
  if (!Slot(image, aliases + 1484)) return false;
  if (!Slot(image, aliases + 1507)) return false;
  if (!Slot(image, aliases + 1519)) return false;
  if (!Slot(image, aliases + 1525)) return false;
  if (!Slot(image, aliases + 1531)) return false;
  // A relocated jump table must still dispatch to these exact instruction
  // boundaries inside the same message routine. No table borrowed from another
  // compatible-looking routine is accepted.
  constexpr uint32_t table_offsets[] = {0x2c, 0x3c, 0xc9, 0xc9, 0x2c,
                                        0x3c, 0x8c, 0xc9, 0x9c, 0xac,
                                        0xc9, 0xc9, 0xc9, 0xc9, 0xbc};
  const auto table = Address(image, message + 40);
  if (!table || Address(image, message + 136) != table + 24 ||
      !Span(image, table, sizeof(table_offsets), IMAGE_SCN_MEM_READ))
    return false;
  const uintptr_t base = image.absolute_base != 0
                             ? image.absolute_base
                             : reinterpret_cast<uintptr_t>(image.base);
  for (size_t i = 0; i < std::size(table_offsets); ++i) {
    if (static_cast<uint64_t>(base) + message + table_offsets[i] > UINT32_MAX ||
        U32(image, table + i * 4) != base + message + table_offsets[i])
      return false;
  }
  // Every wildcard CALL remains an in-image executable edge. The two button-up
  // dispatch cases must share the same transition helper.
  for (const size_t at : {86u, 371u, 459u})
    if (!Call(image, sampler + at)) return false;
  for (const size_t at : {51u, 67u, 147u, 163u, 179u, 197u})
    if (!Call(image, message + at)) return false;
  for (const size_t at : {19u, 34u, 41u})
    if (!Call(image, norm + at)) return false;
  if (Call(image, message + 147) != Call(image, message + 179) ||
      !Call(image, visible + 42))
    return false;
  // The static sites deliberately do not assert that a live HWND's vtable+4 is
  // main. Runtime must check that against main_message_handler, and re-read
  // config/owner dimensions and the actual viewport rectangle on each publish.
  *output = {sampler,   sampler + 114, message,  main,  main + 26,
             norm + 31, config,        manager,  input, window,
             modal,     hidden,        auxiliary};
  return true;
}

}  // namespace fushi_voice_hook::siglus_legacy_input_viewport
