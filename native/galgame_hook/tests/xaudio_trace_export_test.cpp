#include <windows.h>

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <cstring>

#include "xaudio_trace.h"

int wmain(int argc, wchar_t** argv) {
  assert(argc == 2);
  HMODULE module = LoadLibraryExW(argv[1], nullptr,
                                  DONT_RESOLVE_DLL_REFERENCES);
  assert(module != nullptr);
  FARPROC exported =
      GetProcAddress(module, fushi_voice_hook::kXAudioTraceExportName);
  assert(exported != nullptr);
  const auto* trace = reinterpret_cast<
      const fushi_voice_hook::XAudioTraceBuffer*>(exported);
  assert(trace->magic == fushi_voice_hook::kXAudioTraceMagic);
  assert(trace->version == fushi_voice_hook::kXAudioTraceVersion);
  assert(trace->event_size == sizeof(fushi_voice_hook::XAudioTraceEvent));
  assert(trace->slot_size == sizeof(fushi_voice_hook::XAudioTraceSlot));
  assert(trace->capacity == fushi_voice_hook::kXAudioTraceCapacity);

  // The C data export must have one architecture-neutral name.  A redundant
  // x86 linker alias still lets GetProcAddress pass but creates two identical
  // name-table entries, which makes remote enumeration ambiguous.
  const auto* base = reinterpret_cast<const uint8_t*>(module);
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  assert(dos->e_magic == IMAGE_DOS_SIGNATURE);
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
      base + static_cast<size_t>(dos->e_lfanew));
  assert(nt->Signature == IMAGE_NT_SIGNATURE);
  const IMAGE_DATA_DIRECTORY export_directory =
      nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
  assert(export_directory.VirtualAddress != 0);
  const auto* exports = reinterpret_cast<const IMAGE_EXPORT_DIRECTORY*>(
      base + export_directory.VirtualAddress);
  const auto* names = reinterpret_cast<const DWORD*>(
      base + exports->AddressOfNames);
  uint32_t matching_names = 0;
  for (uint32_t i = 0; i < exports->NumberOfNames; ++i) {
    const char* name = reinterpret_cast<const char*>(base + names[i]);
    if (std::strcmp(name, fushi_voice_hook::kXAudioTraceExportName) == 0) {
      ++matching_names;
    }
  }
  assert(matching_names == 1);
  assert(FreeLibrary(module));
  return 0;
}
