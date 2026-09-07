#pragma once

#include "siglus_message_profile.h"
#include "siglus_native_autoprofile.h"

namespace fushi_voice_hook {

struct SiglusNativeMessageProfile {
  uintptr_t message_entry_rva = 0;
  uintptr_t native_text_return_rva = 0;
  uintptr_t voice_entry_rva = 0;
  uintptr_t renderer_entry_rva = 0;
  uint32_t owner_voice_key_offset = 0;
  uint32_t owner_surface_index_offset = 0;
  uint32_t owner_surface_begin_offset = 0;
  uint32_t owner_surface_end_offset = 0;
  uint32_t surface_stride = 0;
};

namespace siglus_native_message {
using siglus_family::Signature;

// One complete measured compiler ABI. Masks cover only relocated addresses and
// direct-call displacements. Frame alignment, saved registers, branch opcodes,
// stack locals and owner layout are fixed structural facts, never title gates.
inline constexpr Signature kEntry{
    "53 8B DC 83 EC 08 83 E4 F8 83 C4 04 55 8B 6B 04 89 6C 24 04 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 53 83 EC 40 A1 ?? ?? ?? ?? 33 C5 89 45 EC 56 57 50 8D 45 F4 64 A3 00 00 00 00 89 55 B8 8B F9 C7 45 FC 00 00 00 00 85 FF"};
inline constexpr Signature kCleanup{
    "8D 4B 10 E8 ?? ?? ?? ?? 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 8B 4D EC 33 CD E8 ?? ?? ?? ?? 8B E5 5D 8B E3 5B C3"};
inline constexpr Signature kTextBridge{
    "0F 57 C0 C7 45 E4 00 00 00 00 BE 07 00 00 00 33 C0 0F 11 45 D4 89 75 E8 66 89 45 D4 C6 45 FC 01 A1 ?? ?? ?? ?? 89 90 40 03 00 00 8B 53 08 89 90 44 03 00 00 E8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8D 4B 10 E8 ?? ?? ?? ?? 8D 4B 10 E8 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 8D 43 10 39 73 24 FF 73 20 0F 47 43 10 8D 89 FC 02 00 00 50 E8 ?? ?? ?? ??"};
inline constexpr size_t kTextCall = 73;
inline constexpr size_t kBridgeFirstPrepareCall = 52;
inline constexpr size_t kBridgeSecondPrepareCall = 57;
inline constexpr size_t kBridgeGlobal = 33;
inline constexpr size_t kBridgeSecondGlobal = 80;
inline constexpr Signature kSurface{
    "8B 87 E0 01 00 00 85 C0 0F 88 83 00 00 00 8B 8F 2C 02 00 00 B8 93 24 49 92 2B 8F 28 02 00 00 F7 E9 03 D1 8B 8F E0 01 00 00 C1 FA 08 8B C2 C1 E8 1F 03 C2 3B C1 7E 5A 69 F1 C0 01 00 00 03 B7 28 02 00 00 80 BE A4 01 00 00 00 75 12 83 BE 7C 01 00 00 01 75 09 8B 46 50 01 86 E4 00 00 00 8D 45 D4 8B CE 50 8D 43 10 50 E8 ?? ?? ?? ?? 80 BE A4 01 00 00 00 75 11 C7 86 7C 01 00 00 00 00 00 00 C6 86 A4 01 00 00 01"};
inline constexpr size_t kRendererCall = 104;
inline constexpr Signature kRendererEntry{
    "53 8B DC 83 EC 08 83 E4 F8 83 C4 04 55 8B 6B 04 89 6C 24 04 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 53 81 EC C0 04 00 00 A1 ?? ?? ?? ?? 33 C5 89 45 EC 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B C1 89 85 AC FB FF FF 8B 53 08 8B 4B 0C"};
inline constexpr Signature kVoiceEntry{
    "55 8B EC 83 EC 0C 89 4D F8 53 8B DA 56 57 85 C9"};
inline constexpr Signature kVoicePrefix{
    "8B 35 ?? ?? ?? ?? 8B 45 0C 89 86 40 03 00 00 8B 45 10 89 86 44 03 00 00 E8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8B 7D 08 8B CF E8 ?? ?? ?? ??"};
inline constexpr Signature kVoiceWrite{
    "8B 4D F8 8A 45 FF 8B 55 0C 8B 75 10 88 81 FC 01 00 00 8A 45 1C 88 81 FD 01 00 00 A1 ?? ?? ?? ?? 89 99 F8 01 00 00 81 C1 EC 01 00 00"};
static_assert(kTextBridge.bytes[kTextCall] == 0xe8);
static_assert(kTextBridge.bytes[kBridgeFirstPrepareCall] == 0xe8);
static_assert(kTextBridge.bytes[kBridgeSecondPrepareCall] == 0xe8);
static_assert(kSurface.bytes[kRendererCall] == 0xe8);
static_assert(kVoicePrefix.bytes[24] == 0xe8);
static_assert(kVoicePrefix.bytes[29] == 0xe8);

inline uint32_t Word(const exact_lookup::LoadedPeImage& image, uintptr_t rva) {
  uint32_t result = 0;
  if (rva < image.size && sizeof(result) <= image.size - rva)
    std::memcpy(&result, image.base + rva, sizeof(result));
  return result;
}

inline bool DataGlobal(const exact_lookup::LoadedPeImage& image, uint32_t va) {
  const uintptr_t base = image.absolute_base != 0 ? image.absolute_base
      : reinterpret_cast<uintptr_t>(image.base);
  return va >= base && (va & 3u) == 0 && exact_lookup::SectionHasRole(
      exact_lookup::FindSectionForRva(image, va - base, sizeof(uint32_t)),
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE, IMAGE_SCN_MEM_EXECUTE);
}

inline bool SameDirectTarget(const exact_lookup::LoadedPeImage& image,
                             uintptr_t first, uintptr_t second) {
  int32_t a = 0, b = 0;
  std::memcpy(&a, image.base + first + 1, 4);
  std::memcpy(&b, image.base + second + 1, 4);
  const int64_t target = static_cast<int64_t>(first) + 5 + a;
  return target > 0 && target == static_cast<int64_t>(second) + 5 + b &&
      static_cast<uint64_t>(target) < image.size &&
      siglus_family::ExecutableSpan(image, static_cast<uintptr_t>(target), 1);
}
}  // namespace siglus_native_message

inline bool ResolveSiglusNativeMessageProfile(
    const exact_lookup::LoadedPeImage& image,
    const SiglusLookupProfile& admitted_native, SiglusNativeMessageProfile* out) {
  using namespace siglus_native_message;
  using siglus_family::Unique;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 ||
      admitted_native.text_feed != SiglusLookupTextFeed::kNativeEcxTextUnion ||
      admitted_native.pe_machine != IMAGE_FILE_MACHINE_I386 ||
      admitted_native.pointer_bits != 32 || admitted_native.exact_text_rva == 0 ||
      admitted_native.exact_text_return_rva == 0)
    return false;
  uintptr_t entry = 0, bridge = 0, surface = 0, renderer = 0, voice = 0;
  uintptr_t prefix = 0, write = 0, cleanup = 0, voice_exit = 0;
  if (!Unique(image, kEntry.pattern(), &entry) ||
      !Unique(image, kTextBridge.pattern(), &bridge) ||
      !Unique(image, kSurface.pattern(), &surface) ||
      !Unique(image, kRendererEntry.pattern(), &renderer) ||
      !Unique(image, kVoiceEntry.pattern(), &voice) ||
      !Unique(image, kVoicePrefix.pattern(), &prefix) ||
      !Unique(image, kVoiceWrite.pattern(), &write) ||
      !siglus_message::NullExit(image, entry + kEntry.bytes.size(), entry, &cleanup) ||
      !siglus_message::MatchAt(image, cleanup, kCleanup.pattern()) ||
      bridge != entry + kEntry.bytes.size() + 6 ||
      surface != bridge + kTextBridge.bytes.size() ||
      surface >= cleanup || kSurface.bytes.size() > cleanup - surface ||
      !siglus_message::NullExit(image, voice + kVoiceEntry.bytes.size(), voice,
                               &voice_exit) ||
      !siglus_message::MatchAt(image, voice_exit, siglus_message::kVoiceReturn.pattern()) ||
      prefix != voice + kVoiceEntry.bytes.size() + 6 ||
      write < prefix + kVoicePrefix.bytes.size() || write >= voice_exit ||
      kVoiceWrite.bytes.size() > voice_exit - write) return false;
  const uintptr_t text = admitted_native.exact_text_rva;
  uintptr_t text_tail = 0, text_end = 0, text_copy = 0;
  if (!Unique(image, siglus_native_family::kTextTail.pattern(), &text_tail) ||
      text_tail != text + 7 || !siglus_family::ExecutableSpan(image, text, 7) ||
      image.base[text] != 0x53 || image.base[text + 1] != 0x8b ||
      image.base[text + 2] != 0x1d || !DataGlobal(image, Word(image, text + 3)) ||
      !siglus_family::UniqueWithin(image, text,
          siglus_family::BoundedFunctionEnd(image, text, 0x1000),
          siglus_native_family::kTextReturn.pattern(), &text_end) ||
      !siglus_family::UniqueWithin(image, text, text_end,
          siglus_native_family::kTextCopy.pattern(), &text_copy) ||
      !exact_lookup::MatchesRel32CallEndingAt(image, bridge + kTextCall + 5, text) ||
      bridge + kTextCall + 5 != admitted_native.exact_text_return_rva ||
      siglus_message::CountDirectCalls(image, entry, cleanup, text) != 1 ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, surface + kRendererCall + 5, renderer) ||
      siglus_message::CountDirectCalls(image, entry, cleanup, renderer) != 1)
    return false;
  const uint32_t global = Word(image, bridge + kBridgeGlobal);
  if (!DataGlobal(image, global) ||
      global != Word(image, bridge + kBridgeSecondGlobal) ||
      global != Word(image, prefix + 2) ||
      !SameDirectTarget(image, bridge + kBridgeFirstPrepareCall, prefix + 24) ||
      !SameDirectTarget(image, bridge + kBridgeSecondPrepareCall, prefix + 29))
    return false;
  out->message_entry_rva = entry;
  out->native_text_return_rva = bridge + kTextCall + 5;
  out->voice_entry_rva = voice;
  out->renderer_entry_rva = renderer;
  out->owner_voice_key_offset = 0x1f8;
  out->owner_surface_index_offset = 0x1e0;
  out->owner_surface_begin_offset = 0x228;
  out->owner_surface_end_offset = 0x22c;
  out->surface_stride = 0x1c0;
  // This profile says nothing about source-file observation or audio readiness.
  return true;
}
}  // namespace fushi_voice_hook
