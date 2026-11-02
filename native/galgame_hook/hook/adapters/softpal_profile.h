#pragma once

// SoftPal ADV System identity: a loaded module exporting the Pal runtime
// surface the adapter binds (softpal_core.h).  Structural only: no hash,
// file name or title.  The executable reaches Pal.dll through
// GetProcAddress, so the identity is the module, not the executable.

#include <windows.h>
#include <tlhelp32.h>

#include "softpal_core.h"

namespace fushi_voice_hook {

// `base` is a loaded PE32 module (or a synthetic image laid out by section).
inline bool IsSoftpalImage(const uint8_t* base, size_t mapped_size) {
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
  softpal::ExportView view;
  view.bytes = base;
  view.size = nt->OptionalHeader.SizeOfImage;
  const IMAGE_DATA_DIRECTORY& exports =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
  view.export_rva = exports.VirtualAddress;
  view.export_size = exports.Size;
  return softpal::HasPalExports(view);
}

inline bool IsSoftpalModule(HMODULE module) {
  if (module == nullptr) return false;
  const auto* base = reinterpret_cast<const uint8_t*>(module);
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return false;
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    return false;
  }
  return IsSoftpalImage(base, nt->OptionalHeader.SizeOfImage);
}

// The loaded Pal runtime module, nullptr when none is loaded.  With a module
// name, only that module is measured (a load notification).
inline HMODULE FindSoftpalModule(const wchar_t* module_name) {
  if (module_name != nullptr) {
    const HMODULE module = GetModuleHandleW(module_name);
    return IsSoftpalModule(module) ? module : nullptr;
  }
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,
                                             GetCurrentProcessId());
  if (snapshot == INVALID_HANDLE_VALUE) return nullptr;
  MODULEENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  HMODULE found = nullptr;
  for (BOOL more = Module32FirstW(snapshot, &entry); more && found == nullptr;
       more = Module32NextW(snapshot, &entry)) {
    if (IsSoftpalModule(entry.hModule)) found = entry.hModule;
  }
  CloseHandle(snapshot);
  return found;
}

inline bool MatchesSoftpalProfile(const wchar_t* module_name) {
  return FindSoftpalModule(module_name) != nullptr;
}

}  // namespace fushi_voice_hook
