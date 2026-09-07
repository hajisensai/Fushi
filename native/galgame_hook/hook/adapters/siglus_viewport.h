#pragma once

#include "exact_lookup_signature.h"

namespace fushi_voice_hook::siglus_viewport {

// The render-state initializer copies Gameexe's design size into the renderer;
// an independent window-normalization path divides by those same fields.
// Both must reference the same global. These are ABI patterns, not title RVAs.
inline constexpr uint8_t kRenderSizeBytes[] = {
    0x8b,0x15,0,0,0,0,0x56,0x8b,0x35,0,0,0,0,0x8d,0x4e,0x08,
    0x8b,0x82,0x58,0xbb,0,0,0x89,0x06,0xc7,0x46,0x04,0,0,0,0,
    0x8b,0x82,0x5c,0xbb,0,0,0x89,0x01,0x8b,0x82,0x60,0xbb,0,0,
    0x89,0x41,0x04,0x8b,0x42,0x7c,0x89,0x46,0x10,
    0x8b,0x82,0x80,0,0,0,0x89,0x46,0x14};
inline constexpr auto kRenderSizeMask =
    exact_lookup::MaskExceptRanges<sizeof(kRenderSizeBytes)>(2,6,9,13);
inline constexpr exact_lookup::MaskedPattern kRenderSizePattern = {
    kRenderSizeBytes,kRenderSizeMask.data(),sizeof(kRenderSizeBytes)};
inline constexpr uint8_t kNormalizeSizeBytes[] = {
    0x8b,0x3d,0,0,0,0,0x8d,0x44,0x24,0x48,0x66,0x0f,0x6e,0xc9,
    0x8d,0x74,0x24,0x40,0x66,0x0f,0x6e,0xc2,0x0f,0x5b,0xc0,
    0xc7,0x44,0x24,0x3c,0x10,0,0,0,0x66,0x0f,0x6e,0x57,0x7c,
    0x66,0x0f,0x6e,0x9f,0x80,0,0,0,0x0f,0x5b,0xd2,
    0x0f,0x5b,0xc9,0x0f,0x5b,0xdb,0xf3,0x0f,0x5e,0xca,
    0xf3,0x0f,0x5e,0xc3};
inline constexpr auto kNormalizeSizeMask =
    exact_lookup::MaskExceptRanges<sizeof(kNormalizeSizeBytes)>(2,6);
inline constexpr exact_lookup::MaskedPattern kNormalizeSizePattern = {
    kNormalizeSizeBytes,kNormalizeSizeMask.data(),sizeof(kNormalizeSizeBytes)};

inline uintptr_t ResolveConfigSlot(const exact_lookup::LoadedPeImage& image) {
  if (image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u)
    return 0;
  const auto render = exact_lookup::FindUniquePatternInExecutableSections(
      image,kRenderSizePattern);
  const auto normalize = exact_lookup::FindUniquePatternInExecutableSections(
      image,kNormalizeSizePattern);
  if (render.count != 1 || normalize.count != 1) return 0;
  uint32_t first = 0, second = 0;
  std::memcpy(&first,render.address + 2,sizeof(first));
  std::memcpy(&second,normalize.address + 2,sizeof(second));
  const uintptr_t base = image.absolute_base != 0 ? image.absolute_base
      : reinterpret_cast<uintptr_t>(image.base);
  if (first != second || first < base || (first & 3u) != 0) return 0;
  const uintptr_t rva = first - base;
  return exact_lookup::SectionHasRole(
      exact_lookup::FindSectionForRva(image,rva,sizeof(uint32_t)),
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE,IMAGE_SCN_MEM_EXECUTE) ? rva : 0;
}

inline bool ValidDesignSize(int32_t width,int32_t height) {
  return width >= 256 && width <= 16384 && height >= 256 && height <= 16384;
}

// Bounded PE import traversal. The key sampler must refer to the named
// user32!GetKeyState thunk, rather than any executable indirect call target.
inline const uint8_t* At(const exact_lookup::LoadedPeImage& image,
                         uint64_t rva,size_t bytes) {
  return image.base != nullptr && rva < image.size && bytes <= image.size-rva
      ? image.base + rva : nullptr;
}
inline bool NameEquals(const exact_lookup::LoadedPeImage& image,uint64_t rva,
                        const char* name,bool ignore_case) {
  for (size_t index = 0; index <= std::strlen(name); ++index) {
    const auto* value = At(image,rva+index,1);
    if (value == nullptr) return false;
    uint8_t lhs = *value, rhs = static_cast<uint8_t>(name[index]);
    if (ignore_case) {
      if (lhs >= 'A' && lhs <= 'Z') lhs += 'a'-'A';
      if (rhs >= 'A' && rhs <= 'Z') rhs += 'a'-'A';
    }
    if (lhs != rhs) return false;
  }
  return true;
}
inline uintptr_t FindGetKeyStateImport(const exact_lookup::LoadedPeImage& image,
                                      uintptr_t bound_get_key_state = 0) {
  if (image.machine != IMAGE_FILE_MACHINE_I386 || image.pointer_bits != 32u)
    return 0;
  const auto* dos_bytes = At(image,0,sizeof(IMAGE_DOS_HEADER));
  if (dos_bytes == nullptr) return 0;
  IMAGE_DOS_HEADER dos{};
  std::memcpy(&dos,dos_bytes,sizeof(dos));
  if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew <= 0) return 0;
  const auto* nt_bytes = At(image,dos.e_lfanew,sizeof(IMAGE_NT_HEADERS32));
  if (nt_bytes == nullptr) return 0;
  IMAGE_NT_HEADERS32 nt{};
  std::memcpy(&nt,nt_bytes,sizeof(nt));
  if (nt.Signature != IMAGE_NT_SIGNATURE ||
      nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
      nt.OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT)
    return 0;
  const auto dir = nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (dir.VirtualAddress == 0 || At(image,dir.VirtualAddress,dir.Size) == nullptr)
    return 0;
  uintptr_t match = 0;
  for (uint64_t offset = 0; offset+sizeof(IMAGE_IMPORT_DESCRIPTOR) <= dir.Size;
       offset += sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
    IMAGE_IMPORT_DESCRIPTOR desc{};
    std::memcpy(&desc,image.base+dir.VirtualAddress+offset,sizeof(desc));
    if (desc.Name == 0 && desc.FirstThunk == 0) return match;
    if (!NameEquals(image,desc.Name,"user32.dll",true)) continue;
    // Protected Siglus launches rebuild imports without an original name
    // table. In that layout only an exact, independently resolved USER32
    // export can identify the slot. Never interpret live pointers as names.
    const bool bound = desc.OriginalFirstThunk == 0;
    if (desc.FirstThunk == 0 || (bound &&
        (bound_get_key_state == 0 || bound_get_key_state > UINT32_MAX))) return 0;
    const uint32_t table = bound ? desc.FirstThunk : desc.OriginalFirstThunk;
    bool terminated = false;
    for (uint64_t index = 0; index < image.size/sizeof(uint32_t); ++index) {
      const auto* lookup = At(image,static_cast<uint64_t>(table)
          + index*sizeof(uint32_t),sizeof(uint32_t));
      if (lookup == nullptr) return 0;
      uint32_t name = 0;
      std::memcpy(&name,lookup,sizeof(name));
      if (name == 0) { terminated = true; break; }
      const bool is_key_state = bound ? name == bound_get_key_state :
          (name & IMAGE_ORDINAL_FLAG32) == 0 &&
          NameEquals(image,static_cast<uint64_t>(name)+2,"GetKeyState",false);
      if (!is_key_state)
        continue;
      const uint64_t thunk = static_cast<uint64_t>(desc.FirstThunk)+index*4;
      if (match != 0 || (thunk & 3u) != 0 ||
          !exact_lookup::SectionHasRole(exact_lookup::FindSectionForRva(
              image,static_cast<uintptr_t>(thunk),4),IMAGE_SCN_MEM_READ,
              IMAGE_SCN_MEM_EXECUTE)) return 0;
      match = static_cast<uintptr_t>(thunk);
    }
    if (!terminated) return 0;
  }
  return 0;
}

}  // namespace fushi_voice_hook::siglus_viewport
