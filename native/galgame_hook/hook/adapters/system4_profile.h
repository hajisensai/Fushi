#pragma once

// AliceSoft System 4 identity: a loaded module exporting the SACT2 HLL
// surface the adapter binds (system4_core.h).  Structural only: no hash,
// file name or title.  The VM loads its HLL libraries after start, so the
// identity is the module, not the executable.

#include <windows.h>
#include <tlhelp32.h>

#include "system4_core.h"

namespace fushi_voice_hook {

// The PE32 headers of a loaded module (or a synthetic image laid out by
// section), nullptr when it is not one.
inline const IMAGE_NT_HEADERS32* System4NtHeaders(const uint8_t* base,
                                                  size_t mapped_size) {
  if (base == nullptr || mapped_size < sizeof(IMAGE_DOS_HEADER)) return nullptr;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) >
          mapped_size) {
    return nullptr;
  }
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC ||
      nt->OptionalHeader.SizeOfImage > mapped_size) {
    return nullptr;
  }
  return nt;
}

inline bool IsSystem4Sact2Image(const uint8_t* base, size_t mapped_size) {
  const IMAGE_NT_HEADERS32* nt = System4NtHeaders(base, mapped_size);
  if (nt == nullptr ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXPORT) {
    return false;
  }
  system4::ExportView view;
  view.bytes = base;
  view.size = nt->OptionalHeader.SizeOfImage;
  const IMAGE_DATA_DIRECTORY& exports =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
  view.export_rva = exports.VirtualAddress;
  view.export_size = exports.Size;
  return system4::HasSact2Exports(view);
}

// The MSG handler layout of a VM image, false when it is not the VM.
inline bool DecodeSystem4VmImage(const uint8_t* base, size_t mapped_size,
                                 system4::MsgLayout* layout) {
  const IMAGE_NT_HEADERS32* nt = System4NtHeaders(base, mapped_size);
  if (nt == nullptr) return false;
  system4::ImageView view;
  view.bytes = base;
  view.size = nt->OptionalHeader.SizeOfImage;
  view.image_base = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(base));
  return system4::DecodeMsgHandler(view, layout);
}

inline size_t System4LoadedImageSize(HMODULE module) {
  if (module == nullptr) return 0u;
  const auto* base = reinterpret_cast<const uint8_t*>(module);
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return 0u;
  const auto* nt =
      reinterpret_cast<const IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    return 0u;
  }
  return nt->OptionalHeader.SizeOfImage;
}

inline bool IsSystem4Sact2Module(HMODULE module) {
  const size_t size = System4LoadedImageSize(module);
  return size != 0u &&
         IsSystem4Sact2Image(reinterpret_cast<const uint8_t*>(module), size);
}

// The loaded SACT2 module, nullptr when none is loaded.  With a module name,
// only that module is measured (a load notification).
inline HMODULE FindSystem4Sact2Module(const wchar_t* module_name) {
  if (module_name != nullptr) {
    const HMODULE module = GetModuleHandleW(module_name);
    return IsSystem4Sact2Module(module) ? module : nullptr;
  }
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,
                                             GetCurrentProcessId());
  if (snapshot == INVALID_HANDLE_VALUE) return nullptr;
  MODULEENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  HMODULE found = nullptr;
  for (BOOL more = Module32FirstW(snapshot, &entry); more && found == nullptr;
       more = Module32NextW(snapshot, &entry)) {
    if (IsSystem4Sact2Module(entry.hModule)) found = entry.hModule;
  }
  CloseHandle(snapshot);
  return found;
}

// The VM module (the one whose MSG handler decodes), outside the system
// directory.  Its layout into `layout`.
inline HMODULE FindSystem4VmModule(system4::MsgLayout* layout) {
  wchar_t system_dir[MAX_PATH] = {};
  const UINT system_len = GetSystemWindowsDirectoryW(system_dir, MAX_PATH);
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,
                                             GetCurrentProcessId());
  if (snapshot == INVALID_HANDLE_VALUE) return nullptr;
  MODULEENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  HMODULE found = nullptr;
  for (BOOL more = Module32FirstW(snapshot, &entry); more && found == nullptr;
       more = Module32NextW(snapshot, &entry)) {
    // Windows' own modules are not the VM (and are large to scan).
    if (system_len != 0u && system_len < MAX_PATH &&
        _wcsnicmp(entry.szExePath, system_dir, system_len) == 0) {
      continue;
    }
    const size_t size = System4LoadedImageSize(entry.hModule);
    if (size == 0u || size > (64u << 20)) continue;
    bool decoded = false;
    __try {
      decoded = DecodeSystem4VmImage(
          reinterpret_cast<const uint8_t*>(entry.hModule), size, layout);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      decoded = false;
    }
    if (decoded) found = entry.hModule;
  }
  CloseHandle(snapshot);
  return found;
}

inline bool MatchesSystem4Profile(const wchar_t* module_name) {
  return FindSystem4Sact2Module(module_name) != nullptr;
}

}  // namespace fushi_voice_hook
