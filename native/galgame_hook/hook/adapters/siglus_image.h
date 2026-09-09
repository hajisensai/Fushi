#pragma once

#include "exact_lookup_signature.h"

namespace fushi_voice_hook {

// Protected Siglus retains a packed on-disk payload's SizeOfRawData in its
// hydrated header. That payload can exceed SizeOfImage; it is not a mapped
// code range. Scan complete virtual sections, without truncating bad ranges
// or changing the default PE extent policy used by other adapters.
inline bool OpenSiglusLoadedImage(HMODULE module,
                                 exact_lookup::LoadedPeImage* image) {
  if (!exact_lookup::OpenLoadedPeImage(
          module, image, exact_lookup::LoadedPeSectionExtent::kVirtualSize))
    return false;
  if (image->machine != IMAGE_FILE_MACHINE_I386 || image->pointer_bits != 32u) {
    *image = {};
    return false;
  }
  for (size_t index = 0; index < image->section_count; ++index) {
    const auto& section = image->sections[index];
    if (exact_lookup::SectionHasRole(&section, IMAGE_SCN_MEM_EXECUTE) &&
        !exact_lookup::IsReadableSpan(section.bytes, section.size)) {
      *image = {};
      return false;
    }
    for (size_t earlier = 0; earlier < index; ++earlier) {
      const auto& other = image->sections[earlier];
      if (section.rva < other.rva + other.size &&
          other.rva < section.rva + section.size) {
        *image = {};
        return false;
      }
    }
  }
  return true;
}

}  // namespace fushi_voice_hook
