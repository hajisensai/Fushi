#pragma once

#include "siglus_image.h"
#include "siglus_legacy_message_profile.h"
#include "siglus_legacy_resource.h"

namespace fushi_voice_hook {

// Shared by the live installers and their cross-architecture admission tests.
inline bool ResolveLiveSiglusLegacyMessage(HMODULE module,
    const SiglusLookupProfile& lane,
    const LegacyGlyphSites& admitted,
    SiglusLegacyMessageProfile* profile) {
  __try {
    exact_lookup::LoadedPeImage image;
    SiglusLegacyResourceMappingProfile resource;
    return OpenSiglusLoadedImage(module, &image) &&
        ResolveSiglusLegacyMessageProfile(
            image, lane, admitted, profile) &&
        // Retain the existing Luna/resource fallback when the independent old
        // voice contract is absent. Source installation still has its own gate.
        ResolveSiglusLegacyResourceMappingProfile(
            image, profile->voice_entry_rva, &resource) &&
        // The legacy resource resolver matches the entire FPO Ogg entry,
        // including its prologue, and rejects an already-detoured entry.
        image.base[lane.exact_text_rva] == 0x6a &&
        image.base[profile->message_entry_rva] == 0x6a;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

inline bool ResolveLiveSiglusLegacyVoiceSource(HMODULE module, uintptr_t proved_voice_entry,
    SiglusLegacyResourceMappingProfile* profile) {
  __try {
    exact_lookup::LoadedPeImage image;
    return OpenSiglusLoadedImage(module, &image) &&
        // This resolver matches the complete legacy FPO Ogg entry, including
        // its prologue; an external detour cannot satisfy that contract.
        ResolveSiglusLegacyResourceMappingProfile(
            image, proved_voice_entry, profile);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

}  // namespace fushi_voice_hook
