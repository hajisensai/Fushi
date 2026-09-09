#pragma once

#include "siglus_eightarg_owner_profile.h"
#include "siglus_image.h"

namespace fushi_voice_hook::siglus_eightarg_lookup_family {
struct Sites {
  SiglusEightArgGlyphSites glyph{};
  siglus_eightarg_input_viewport::Sites input{};
  siglus_eightarg_owner_profile::Sites owner{};
};

// A final original-entry check for the boundaries an installer can patch.
// Validate complete family signatures rather than assuming all functions begin
// with PUSH EBP: input and message entry ABIs are independently defined.
// This does not authorize reuse of somebody else's existing detour/trampoline.
inline bool ValidateLiveEntries(const exact_lookup::LoadedPeImage& image,
                                const Sites& sites) {
  namespace glyph = siglus_eight_arg_glyph;
  namespace input = siglus_eightarg_input_viewport;
  if (image.base == nullptr || image.machine != IMAGE_FILE_MACHINE_I386 ||
      image.pointer_bits != 32 || image.section_count == 0 ||
      image.section_count > image.sections.size()) return false;
  const uintptr_t entries[] = {sites.glyph.glyph_entry_rva,
      sites.glyph.message_entry_rva, sites.glyph.scenario_entry_rva,
      sites.input.sampler, sites.input.message};
  const exact_lookup::MaskedPattern patterns[] = {glyph::kGlyphEntry.pattern(),
      glyph::kMessage.pattern(), glyph::kScenarioEntry.pattern(),
      input::kSampler.pattern(), input::kMessage.pattern()};
  for (size_t n = 0; n < std::size(entries); ++n)
    if (entries[n] == 0 || !glyph::At(image, entries[n], 0, patterns[n]))
      return false;
  return true;
}

// Caller supplies independently named/verified USER32 IAT slots, never an
// executable hash or an address guessed from another architecture's export.
// Keep partial results private. The owner join currently revalidates glyphs;
// this intentionally costs two glyph scans instead of accepting stale sites.
inline bool Resolve(const exact_lookup::LoadedPeImage& image,
                    const siglus_eightarg_input_viewport::Imports& imports,
                    Sites* out) {
  if (out == nullptr) return false;
  *out = {};
  Sites candidate;
  if (!siglus_eight_arg_glyph::Resolve(image, &candidate.glyph) ||
      !siglus_eightarg_input_viewport::Resolve(image, imports, &candidate.input) ||
      !siglus_eightarg_owner_profile::Resolve(
          image, candidate.glyph, candidate.input, &candidate.owner) ||
      !ValidateLiveEntries(image, candidate)) return false;
  *out = candidate;
  return true;
}

// Shared production/test boundary. The real Siglus opener validates hydrated
// VirtualSize extents, readability, section overlap and PE32 architecture.
// Sites contain the profile RVA mapping, but no design dimensions, enabled flag
// or fabricated text-feed identity: the installer must obtain a healthy live
// viewport and wire the measured eight-argument message capture separately.
inline bool ResolveLive(HMODULE module,
                        const siglus_eightarg_input_viewport::Imports& imports,
                        Sites* out) {
  if (out == nullptr) return false;
  *out = {};
  if (module == nullptr) return false;
  __try {
    exact_lookup::LoadedPeImage image;
    return OpenSiglusLoadedImage(module, &image) && Resolve(image, imports, out);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    *out = {};
    return false;
  }
}
}  // namespace fushi_voice_hook::siglus_eightarg_lookup_family
