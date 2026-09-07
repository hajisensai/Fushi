#pragma once

#include "siglus_viewport.h"

namespace fushi_voice_hook::siglus_native_viewport {

// This native Siglus ABI initializes renderer fields from Gameexe config,
// including design width/height at +0x7c/+0x80. A separate normalization path
// divides window dimensions by those same fields. Require both independent
// instruction chains to identify one writable config-pointer slot.
inline constexpr uint8_t kRenderSizeBytes[] = {
    0x8b,0x3d,0,0,0,0,0x51,0x8b,0x87,0x94,0xf7,0,0,0x89,0x01,
    0xc7,0x41,0x04,0,0,0,0,0x8b,0xb7,0x9c,0xf7,0,0,
    0x89,0x85,0x08,0xff,0xff,0xff,0x8b,0x87,0x98,0xf7,0,0,
    0x89,0x02,0x89,0x72,0x04,0x8b,0x47,0x7c,
    0x8b,0xb7,0x80,0,0,0,0x89,0x41,0x10,0x89,0x71,0x14};
inline constexpr auto kRenderSizeMask =
    exact_lookup::MaskExceptRanges<sizeof(kRenderSizeBytes)>(2,6);
inline constexpr exact_lookup::MaskedPattern kRenderSizePattern = {
    kRenderSizeBytes,kRenderSizeMask.data(),sizeof(kRenderSizeBytes)};

inline constexpr uint8_t kNormalizeSizeBytes[] = {
    0x8b,0x35,0,0,0,0,0x83,0xec,0x08,0x66,0x0f,0x6e,0xc0,
    0x66,0x0f,0x6e,0xd2,0x0f,0x5b,0xd2,0x66,0x0f,0x6e,0x4e,0x7c,
    0x66,0x0f,0x6e,0x9e,0x80,0,0,0,0x0f,0x5b,0xc9,
    0x0f,0x5b,0xc0,0x0f,0x5b,0xdb,0xf3,0x0f,0x5e,0xc1,
    0xf3,0x0f,0x5e,0xd3};
inline constexpr auto kNormalizeSizeMask =
    exact_lookup::MaskExceptRanges<sizeof(kNormalizeSizeBytes)>(2,6);
inline constexpr exact_lookup::MaskedPattern kNormalizeSizePattern = {
    kNormalizeSizeBytes,kNormalizeSizeMask.data(),sizeof(kNormalizeSizeBytes)};

// Returns an RVA, never a dereferenced config object or a guessed viewport.
// Callers validate live dimensions with siglus_viewport::ValidDesignSize.
inline uintptr_t ResolveNativeConfigSlot(
    const exact_lookup::LoadedPeImage& image) {
  if (image.base == nullptr || image.size < sizeof(uint32_t) ||
      image.section_count > image.sections.size() ||
      image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u)
    return 0;
  const auto render = exact_lookup::FindUniquePatternInExecutableSections(
      image,kRenderSizePattern);
  const auto normalize = exact_lookup::FindUniquePatternInExecutableSections(
      image,kNormalizeSizePattern);
  if (render.count != 1u || normalize.count != 1u) return 0;
  uint32_t first = 0, second = 0;
  std::memcpy(&first,render.address + 2u,sizeof(first));
  std::memcpy(&second,normalize.address + 2u,sizeof(second));
  const uintptr_t base = image.absolute_base != 0 ? image.absolute_base
      : reinterpret_cast<uintptr_t>(image.base);
  if (first != second || first < base || (first & 3u) != 0) return 0;
  const uintptr_t rva = first - base;
  if (rva > image.size - sizeof(uint32_t)) return 0;
  return exact_lookup::SectionHasRole(
      exact_lookup::FindSectionForRva(image,rva,sizeof(uint32_t)),
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,IMAGE_SCN_MEM_EXECUTE) ? rva : 0;
}

}  // namespace fushi_voice_hook::siglus_native_viewport
