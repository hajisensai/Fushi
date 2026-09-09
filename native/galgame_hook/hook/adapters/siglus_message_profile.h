#pragma once

#include "siglus_autoprofile.h"
#include "siglus_resource_mapping.h"

namespace fushi_voice_hook {

enum class SiglusMessageOwnerRegister : uint8_t { kNone, kEsi, kEdi };

// Static x86 message ABI proof only. These addresses do not establish a voice
// occurrence, playback, or resource pairing. Native ownership must be decided
// before installing Luna, and runtime callers must validate the live object.
struct SiglusMessageProfile {
  uintptr_t message_entry_rva = 0;
  uintptr_t message_surface_return_rva = 0;
  uintptr_t surface_wrapper_rva = 0;
  uintptr_t scenario_return_rva = 0;
  uintptr_t voice_entry_rva = 0;
  uintptr_t prepare_entry_rva = 0;
  uintptr_t clear_layout_rva = 0;
  uintptr_t clear_all_rva = 0;
  SiglusMessageOwnerRegister owner_register = SiglusMessageOwnerRegister::kNone;
  uint32_t owner_voice_key_offset = 0;
  uint32_t owner_surface_index_offset = 0;
  uint32_t owner_surface_begin_offset = 0;
  uint32_t owner_surface_end_offset = 0;
  uint32_t surface_stride = 0;
  // The message ABI alone does not prove the resource key's archive/member
  // mapping. A separate resource-path proof is required before enabling audio.
  bool voice_key_resource_mapping_proved = false;
};

namespace siglus_message {
using siglus_family::Signature;

// Separate complete compiler variants: the owner register and stack allocation
// are not wildcards. Both use ECX=self, EDX=position and caller-cleaned stack
// arguments at the outer entry; the inner surface wrapper is thiscall/ret 8.
inline constexpr Signature kMessageEsi{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 3C A1 ?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B FA 8B F1 C7 45 FC 00 00 00 00 85 F6"};
inline constexpr Signature kMessageEdi{
    "55 8B EC 6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 83 EC 44 A1 ?? ?? ?? ?? 33 C5 89 45 F0 53 56 57 50 8D 45 F4 64 A3 00 00 00 00 8B F2 8B F9 C7 45 FC 00 00 00 00 85 FF"};
inline constexpr Signature kMessageCleanup{
    "83 7D 24 08 72 0B FF 75 10 E8 ?? ?? ?? ?? 83 C4 04 8B 4D F4 64 89 0D 00 00 00 00 59 5F 5E 5B 8B 4D F0 33 CD E8 ?? ?? ?? ?? 8B E5 5D C3"};
inline constexpr Signature kSurfaceEsi{
    "8B 86 E0 01 00 00 85 C0 78 49 8B 8E 2C 02 00 00 B8 93 24 49 92 2B 8E 28 02 00 00 F7 E9 03 D1 8B 8E E0 01 00 00 C1 FA 08 8B C2 C1 E8 1F 03 C2 3B C1 7E 20 69 C9 C0 01 00 00 8D 45 D8 50 8D 45 10 50 03 8E 28 02 00 00 E8 ?? ?? ?? ?? 8B CE E8 ?? ?? ?? ??"};
inline constexpr Signature kSurfaceEdi{
    "8B 87 E0 01 00 00 85 C0 78 49 8B 8F 2C 02 00 00 B8 93 24 49 92 2B 8F 28 02 00 00 F7 E9 03 D1 8B 8F E0 01 00 00 C1 FA 08 8B C2 C1 E8 1F 03 C2 3B C1 7E 20 69 C9 C0 01 00 00 8D 45 D8 50 8D 45 10 50 03 8F 28 02 00 00 E8 ?? ?? ?? ?? 8B CF E8 ?? ?? ?? ??"};
inline constexpr size_t kSurfaceCallOffset = 71u;
// This complete wrapper proves two arguments, the preserved frame chain, one
// synchronous scenario call, and ret 8. Other scenario callers are irrelevant.
inline constexpr Signature kWrapper{
    "55 8B EC 51 56 8B F1 80 BE A4 01 00 00 00 75 12 83 BE 7C 01 00 00 01 75 09 8B 46 50 01 86 E4 00 00 00 FF 75 0C FF 75 08 E8 ?? ?? ?? ?? 80 BE A4 01 00 00 00 75 11 C7 86 7C 01 00 00 00 00 00 00 C6 86 A4 01 00 00 01 5E 59 5D C2 08 00"};
inline constexpr size_t kWrapperCallOffset = 40u;
inline constexpr Signature kVoiceEntry{
    "55 8B EC 83 EC 10 89 4D F4 53 8B DA 56 57 85 C9"};
// ECX restored from its entry save; EBX is the original EDX request key.
inline constexpr Signature kVoiceWrite{
    "8B 4D F4 8A 45 FB 88 81 FC 01 00 00 8A 45 1C 88 81 FD 01 00 00 A1 ?? ?? ?? ?? 89 99 F8 01 00 00 81 C1 EC 01 00 00"};
inline constexpr Signature kVoiceReturn{"5F 5E 5B 8B E5 5D C3"};
inline constexpr Signature kClearLayout{
    "56 8B F1 8D 8E 34 02 00 00 E8 ?? ?? ?? ?? 8D 8E 34 0C 00 00 C7 86 F8 01 00 00 FF FF FF FF C6 86 FC 01 00 00 00"};
inline constexpr Signature kClearAll{
    "53 56 57 8B F1 E8 ?? ?? ?? ?? 8B CE E8 ?? ?? ?? ?? 8B CE E8 ?? ?? ?? ?? C7 86 F8 01 00 00 FF FF FF FF B8 93 24 49 92 C6 86 FC 01 00 00 00 33 DB 8B 8E 2C 02 00 00 2B 8E 28 02 00 00 F7 E9 03 D1 C1 FA 08"};
// This owner preparation reaches both clears. The flag branch is retained;
// entering this routine is NOT proof that a new sentence/reset occurred.
inline constexpr Signature kPrepare{
    "51 56 8B F1 57 80 BE D4 01 00 00 00 0F 85 ?? ?? ?? ?? 80 BE D8 01 00 00 00 74 2A E8 ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 83 BF 10 03 00 00 08 8D 87 FC 02 00 00 C7 40 10 00 00 00 00 72 02 8B 00 33 C9 66 89 08 EB 34 83 BE B8 01 00 00 00 7E 25 6A 00 E8 ?? ?? ?? ?? 84 C0 75 1A 8B CE E8 ?? ?? ?? ?? 8B 3D ?? ?? ?? ?? 8D 8F FC 02 00 00 E8 ?? ?? ?? ?? EB 06 8B 3D ?? ?? ?? ?? 8B CE E8 ?? ?? ?? ??"};
inline constexpr size_t kPrepareClearLayoutOffset = 27u;
inline constexpr size_t kPrepareSecondClearLayoutOffset = 91u;
inline constexpr size_t kPrepareClearAllOffset = 123u;
static_assert(kSurfaceEsi.bytes[kSurfaceCallOffset] == 0xe8u);
static_assert(kSurfaceEdi.bytes[kSurfaceCallOffset] == 0xe8u);
static_assert(kWrapper.bytes[kWrapperCallOffset] == 0xe8u);
static_assert(kPrepare.bytes[kPrepareClearLayoutOffset] == 0xe8u);
static_assert(kPrepare.bytes[kPrepareSecondClearLayoutOffset] == 0xe8u);
static_assert(kPrepare.bytes[kPrepareClearAllOffset] == 0xe8u);

inline bool MatchAt(const exact_lookup::LoadedPeImage& image, uintptr_t rva,
                    const exact_lookup::MaskedPattern& pattern) {
  if (!siglus_family::ExecutableSpan(image, rva, pattern.size)) return false;
  const auto found = exact_lookup::FindUniqueMaskedPattern(
      image.base + rva, pattern.size, pattern);
  return found.count == 1u && found.address == image.base + rva;
}

// Decode only the conditional branch that immediately follows an independently
// matched entry. Its destination is the checked cleanup, not a guessed extent.
inline bool NullExit(const exact_lookup::LoadedPeImage& image, uintptr_t branch,
                     uintptr_t entry, uintptr_t* target) {
  if (target == nullptr || !siglus_family::ExecutableSpan(image, branch, 6u) ||
      image.base[branch] != 0x0fu || image.base[branch + 1u] != 0x84u) return false;
  int32_t relative = 0;
  std::memcpy(&relative, image.base + branch + 2u, sizeof(relative));
  const int64_t result = static_cast<int64_t>(branch) + 6 + relative;
  if (result <= static_cast<int64_t>(branch) ||
      result < static_cast<int64_t>(entry) ||
      static_cast<uint64_t>(result) - entry > 0x600u ||
      static_cast<uint64_t>(result) >= image.size) return false;
  *target = static_cast<uintptr_t>(result);
  return true;
}

inline uint32_t CountDirectCalls(const exact_lookup::LoadedPeImage& image,
                                uintptr_t begin, uintptr_t end,
                                uintptr_t target) {
  if (end <= begin || !siglus_family::ExecutableSpan(image, begin, end - begin))
    return 0;
  uint32_t count = 0;
  for (uintptr_t at = begin; end - at >= 5u; ++at) {
    if (image.base[at] == 0xe8u &&
        exact_lookup::MatchesRel32CallEndingAt(image, at + 5u, target) &&
        ++count == 2u) return count;
  }
  return count;
}
}  // namespace siglus_message

inline bool ResolveSiglusMessageProfile(
    const exact_lookup::LoadedPeImage& image,
    const SiglusLookupProfile& admitted_scenario, SiglusMessageProfile* out) {
  using namespace siglus_message;
  using siglus_family::Unique;
  using siglus_family::UniqueWithin;
  if (out == nullptr) return false;
  *out = {};
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32u ||
      admitted_scenario.text_feed != SiglusLookupTextFeed::kLunaScenarioLane ||
      admitted_scenario.pe_machine != IMAGE_FILE_MACHINE_I386 ||
      admitted_scenario.pointer_bits != 32u ||
      admitted_scenario.exact_text_rva == 0u) return false;

  uintptr_t message = 0, surface = 0, wrapper = 0, voice = 0, voice_write = 0;
  uintptr_t prepare = 0, clear_layout = 0, clear_all = 0;
  const auto esi = exact_lookup::FindUniquePatternInExecutableSections(
      image, kMessageEsi.pattern());
  const auto edi = exact_lookup::FindUniquePatternInExecutableSections(
      image, kMessageEdi.pattern());
  if (esi.count + edi.count != 1u) return false;
  const bool owner_esi = esi.count == 1u;
  const auto& chosen = owner_esi ? esi : edi;
  if (chosen.address == nullptr) return false;
  message = static_cast<uintptr_t>(chosen.address - image.base);
  const auto surfaces_esi = exact_lookup::FindUniquePatternInExecutableSections(
      image, kSurfaceEsi.pattern());
  const auto surfaces_edi = exact_lookup::FindUniquePatternInExecutableSections(
      image, kSurfaceEdi.pattern());
  if (surfaces_esi.count + surfaces_edi.count != 1u ||
      (owner_esi ? surfaces_esi.count : surfaces_edi.count) != 1u) return false;
  const auto& chosen_surface = owner_esi ? surfaces_esi : surfaces_edi;
  if (chosen_surface.address == nullptr) return false;
  surface = static_cast<uintptr_t>(chosen_surface.address - image.base);
  uintptr_t message_exit = 0, voice_exit = 0, ignored = 0;
  if (!NullExit(image, message + kMessageEsi.bytes.size(), message,
                &message_exit) ||
      !MatchAt(image, message_exit, kMessageCleanup.pattern()) ||
      surface < message || surface >= message_exit ||
      kSurfaceEsi.bytes.size() > message_exit - surface ||
      !Unique(image, kWrapper.pattern(), &wrapper) ||
      !Unique(image, kVoiceEntry.pattern(), &voice) ||
      !NullExit(image, voice + kVoiceEntry.bytes.size(), voice, &voice_exit) ||
      !MatchAt(image, voice_exit, kVoiceReturn.pattern()) ||
      !Unique(image, kVoiceWrite.pattern(), &voice_write) ||
      voice_write < voice || voice_write >= voice_exit ||
      kVoiceWrite.bytes.size() > voice_exit - voice_write ||
      !Unique(image, kPrepare.pattern(), &prepare) ||
      !Unique(image, kClearLayout.pattern(), &clear_layout) ||
      !Unique(image, kClearAll.pattern(), &clear_all)) return false;

  const uintptr_t scenario = admitted_scenario.exact_text_rva;
  uintptr_t scenario_tail = 0, scenario_end = 0;
  if (!Unique(image, siglus_family::kScenarioEntryTail.pattern(), &scenario_tail) ||
      scenario_tail != scenario + 5u ||
      !siglus_family::OriginalOrExternalDetour(image, scenario) ||
      !UniqueWithin(image, scenario,
                    siglus_family::BoundedFunctionEnd(image, scenario, 0x1000u),
                    siglus_family::kScenarioReturn.pattern(), &scenario_end) ||
      !UniqueWithin(image, scenario, scenario_end,
                    siglus_family::kScenarioStringAbi.pattern(), &ignored) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, surface + kSurfaceCallOffset + 5u, wrapper) ||
      CountDirectCalls(image, message, message_exit, wrapper) != 1u ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, wrapper + kWrapperCallOffset + 5u, scenario) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, prepare + kPrepareClearLayoutOffset + 5u, clear_layout) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, prepare + kPrepareSecondClearLayoutOffset + 5u, clear_layout) ||
      !exact_lookup::MatchesRel32CallEndingAt(
          image, prepare + kPrepareClearAllOffset + 5u, clear_all)) return false;

  out->message_entry_rva = message;
  out->message_surface_return_rva = surface + kSurfaceCallOffset + 5u;
  out->surface_wrapper_rva = wrapper;
  out->scenario_return_rva = wrapper + kWrapperCallOffset + 5u;
  out->voice_entry_rva = voice;
  out->prepare_entry_rva = prepare;
  out->clear_layout_rva = clear_layout;
  out->clear_all_rva = clear_all;
  out->owner_register = owner_esi ? SiglusMessageOwnerRegister::kEsi
                                  : SiglusMessageOwnerRegister::kEdi;
  out->owner_voice_key_offset = 0x1f8u;
  out->owner_surface_index_offset = 0x1e0u;
  out->owner_surface_begin_offset = 0x228u;
  out->owner_surface_end_offset = 0x22cu;
  out->surface_stride = 0x1c0u;
  // Static resource mapping is independently available, but it does not prove
  // which observed file produced a payload. Keep audio admission closed until
  // the runtime caller binds the proved resource source to actual file identity.
  return true;
}
}  // namespace fushi_voice_hook
