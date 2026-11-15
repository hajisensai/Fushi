#pragma once

// Nitroplus N2System identity: the game executable carries the engine's
// backlog append routine, proved by its structure (nitroplus_core.h
// ResolveBacklogAppend).  Structural only: no hash, file name, title or
// string.  The routine lives in the executable itself, so the identity is the
// main module, measured once.

#include <windows.h>

#include "nitroplus_core.h"

namespace fushi_voice_hook {

// `base` is a PE32 image laid out by section (a loaded module or a synthetic
// test image of `mapped_size` bytes).  The scanned section is the executable
// section that holds the entry point.
inline nitroplus::ImageView NitroplusImageView(const uint8_t* base,
                                               size_t mapped_size) {
  nitroplus::ImageView view;
  if (base == nullptr || mapped_size < sizeof(IMAGE_DOS_HEADER)) return view;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) >
          mapped_size) {
    return view;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
      nt->OptionalHeader.SizeOfImage > mapped_size) {
    return view;
  }
  const size_t sections_at = static_cast<size_t>(dos->e_lfanew) +
                             offsetof(IMAGE_NT_HEADERS32, OptionalHeader) +
                             nt->FileHeader.SizeOfOptionalHeader;
  const uint32_t count = nt->FileHeader.NumberOfSections;
  if (sections_at + count * sizeof(IMAGE_SECTION_HEADER) > mapped_size) {
    return view;
  }
  const auto* sections =
      reinterpret_cast<const IMAGE_SECTION_HEADER*>(base + sections_at);
  const uint32_t entry = nt->OptionalHeader.AddressOfEntryPoint;
  for (uint32_t i = 0; i < count; ++i) {
    const IMAGE_SECTION_HEADER& s = sections[i];
    const uint32_t size = s.Misc.VirtualSize != 0 ? s.Misc.VirtualSize
                                                  : s.SizeOfRawData;
    if ((s.Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0 ||
        entry < s.VirtualAddress || entry >= s.VirtualAddress + size) {
      continue;
    }
    view.bytes = base;
    view.size = nt->OptionalHeader.SizeOfImage;
    view.image_base = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(base));
    view.code_rva = s.VirtualAddress;
    view.code_size = size;
    break;
  }
  return view;
}

#if defined(_M_IX86)
// The main executable's resolution, measured once (probe and install may run
// on different threads; the first measurement wins).
inline const nitroplus::BacklogSites& NitroplusMainModuleSites() {
  static const nitroplus::BacklogSites sites = [] {
    const auto* base = reinterpret_cast<const uint8_t*>(GetModuleHandleW(nullptr));
    if (base == nullptr) return nitroplus::BacklogSites{};
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) {
      return nitroplus::BacklogSites{};
    }
    const auto* nt =
        reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
      return nitroplus::BacklogSites{};
    }
    return nitroplus::ResolveBacklogAppend(
        NitroplusImageView(base, nt->OptionalHeader.SizeOfImage));
  }();
  return sites;
}
#endif

// Only the main executable can carry the routine: a module load of anything
// else never changes the answer.
inline bool MatchesNitroplusProfile(const wchar_t* module_name) {
#if defined(_M_IX86)
  if (module_name != nullptr &&
      GetModuleHandleW(module_name) != GetModuleHandleW(nullptr)) {
    return false;
  }
  return NitroplusMainModuleSites().ok;
#else
  (void)module_name;
  return false;  // the resolver encodes x86 code; no x64 sample is measured
#endif
}

}  // namespace fushi_voice_hook
