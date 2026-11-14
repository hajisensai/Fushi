#pragma once

// EntisGLS identity: the main executable exports the engine runtime by its
// MSVC-mangled names (the Sakura2 VM syscall table and the runtime classes
// of the message window and its Rosetta binding; entisgls_core.h).
// Structural only: no hash, file name or title.

#include <windows.h>

#include "entisgls_core.h"

namespace fushi_voice_hook {

// `base` is a loaded PE32 image (or a synthetic image laid out by section).
// Fills `view` (bytes, size, base, exports, code ranges) when it is a PE32.
inline bool EntisGlsImageView(const uint8_t* base, size_t mapped_size,
                              entisgls::ImageView* view) {
  if (base == nullptr || mapped_size < sizeof(IMAGE_DOS_HEADER)) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) >
          mapped_size) {
    return false;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
      nt->OptionalHeader.SizeOfImage > mapped_size ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXPORT) {
    return false;
  }
  view->bytes = base;
  view->size = nt->OptionalHeader.SizeOfImage;
  view->va_base = nt->OptionalHeader.ImageBase;
  const IMAGE_DATA_DIRECTORY& exports =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
  view->export_rva = exports.VirtualAddress;
  view->export_size = exports.Size;
  view->code_count = 0u;
  const auto* sections = IMAGE_FIRST_SECTION(nt);
  for (uint32_t i = 0u; i < nt->FileHeader.NumberOfSections; ++i) {
    if (reinterpret_cast<const uint8_t*>(&sections[i] + 1) > base + view->size) {
      return false;
    }
    if ((sections[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0u) continue;
    if (view->code_count >= view->code.size()) return false;
    const uint32_t span = sections[i].Misc.VirtualSize != 0u
                              ? sections[i].Misc.VirtualSize
                              : sections[i].SizeOfRawData;
    if (sections[i].VirtualAddress > view->size ||
        span > view->size - sections[i].VirtualAddress) {
      return false;
    }
    view->code[view->code_count++] = {sections[i].VirtualAddress,
                                      sections[i].VirtualAddress + span};
  }
  return view->code_count != 0u;
}

inline bool IsEntisGlsImage(const uint8_t* base, size_t mapped_size) {
  entisgls::ImageView view;
  return EntisGlsImageView(base, mapped_size, &view) &&
         entisgls::HasEntisExports(view);
}

inline bool MatchesEntisGlsProfile(const wchar_t* module_name) {
  // The identity is the main executable; module loads never change it.
  if (module_name != nullptr) return false;
  const auto* base =
      reinterpret_cast<const uint8_t*>(GetModuleHandleW(nullptr));
  if (base == nullptr) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return false;
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    return false;
  }
  return IsEntisGlsImage(base, nt->OptionalHeader.SizeOfImage);
}

}  // namespace fushi_voice_hook
