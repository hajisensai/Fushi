// CatSystem2 offline site probe: runs the hook DLL's own structural resolvers
// (catsystem2_lookup_core.h / catsystem2_voice_core.h) over a game image read
// from disk and prints what they resolve, as RVAs.
//
// Purpose: when a volunteer machine reports `catsystem2-lookup: sites
// unresolved result=N` or `catsystem2-voice: ... result=N`, the exe (or a dump
// of its main module) can be checked offline against the exact code the hook
// runs, without launching or injecting anything.
//
// Usage:
//   fushi_catsystem2_site_probe <cs2.exe>             disk image, mapped here
//   fushi_catsystem2_site_probe --mapped <module.mem> flat dump of the loaded
//                                                     main module
//
// The input is untrusted data: it is only read and copied into a private
// read/write buffer laid out by section; nothing in it is executed, no loader
// is involved and no relocation is applied (absolute operands are resolved
// against the header's ImageBase, which is also what an unrelocated dump
// carries).

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "catsystem2_lookup_core.h"
#include "catsystem2_voice_core.h"

namespace {

namespace exact = fushi_voice_hook::exact_lookup;
namespace cs2 = fushi_voice_hook::catsystem2_lookup;
namespace cs2_voice = fushi_voice_hook::catsystem2_voice;

bool ReadWholeFile(const wchar_t* path, std::vector<uint8_t>* bytes) {
  HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {};
  bool ok = GetFileSizeEx(file, &size) != 0 && size.QuadPart > 0 &&
            size.QuadPart < 512ll * 1024ll * 1024ll;
  if (ok) {
    bytes->resize(static_cast<size_t>(size.QuadPart));
    DWORD done = 0u;
    ok = ReadFile(file, bytes->data(), static_cast<DWORD>(bytes->size()),
                  &done, nullptr) != 0 &&
         done == bytes->size();
  }
  CloseHandle(file);
  return ok;
}

struct Headers {
  const IMAGE_NT_HEADERS32* nt = nullptr;
  const IMAGE_SECTION_HEADER* sections = nullptr;
};

bool ParseHeaders(const std::vector<uint8_t>& bytes, Headers* out) {
  if (bytes.size() < sizeof(IMAGE_DOS_HEADER)) return false;
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(bytes.data());
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
      static_cast<size_t>(dos->e_lfanew) + sizeof(IMAGE_NT_HEADERS32) >
          bytes.size()) {
    return false;
  }
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS32*>(
      bytes.data() + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    return false;
  }
  const size_t section_table = static_cast<size_t>(dos->e_lfanew) +
                               sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) +
                               nt->FileHeader.SizeOfOptionalHeader;
  if (section_table + nt->FileHeader.NumberOfSections *
                          sizeof(IMAGE_SECTION_HEADER) >
      bytes.size()) {
    return false;
  }
  out->nt = nt;
  out->sections =
      reinterpret_cast<const IMAGE_SECTION_HEADER*>(bytes.data() + section_table);
  return true;
}

// Lays the file out at its RVAs in a fresh read/write buffer.
uint8_t* MapImage(const std::vector<uint8_t>& bytes, bool mapped,
                  uint32_t* image_base) {
  Headers headers;
  if (!ParseHeaders(bytes, &headers)) return nullptr;
  const uint32_t size = headers.nt->OptionalHeader.SizeOfImage;
  if (size < 4096u || size > 512u * 1024u * 1024u) return nullptr;
  auto* view = static_cast<uint8_t*>(
      VirtualAlloc(nullptr, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  if (view == nullptr) return nullptr;
  if (mapped) {
    std::memcpy(view, bytes.data(), bytes.size() < size ? bytes.size() : size);
  } else {
    const uint32_t header_bytes =
        headers.nt->OptionalHeader.SizeOfHeaders < size
            ? headers.nt->OptionalHeader.SizeOfHeaders
            : size;
    std::memcpy(view, bytes.data(),
                header_bytes < bytes.size() ? header_bytes : bytes.size());
    for (WORD index = 0u; index < headers.nt->FileHeader.NumberOfSections;
         ++index) {
      const IMAGE_SECTION_HEADER& section = headers.sections[index];
      const uint64_t raw_end =
          static_cast<uint64_t>(section.PointerToRawData) +
          section.SizeOfRawData;
      if (section.SizeOfRawData == 0u || raw_end > bytes.size() ||
          section.VirtualAddress >= size) {
        continue;
      }
      uint32_t copy = section.SizeOfRawData;
      if (copy > size - section.VirtualAddress) {
        copy = size - section.VirtualAddress;
      }
      std::memcpy(view + section.VirtualAddress,
                  bytes.data() + section.PointerToRawData, copy);
    }
  }
  *image_base = headers.nt->OptionalHeader.ImageBase;
  return view;
}

uintptr_t Rva(const exact::LoadedPeImage& image, uintptr_t address) {
  return address == 0u ? 0u
                       : address - reinterpret_cast<uintptr_t>(image.base);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  bool mapped = false;
  const wchar_t* path = nullptr;
  for (int index = 1; index < argc; ++index) {
    if (std::wcscmp(argv[index], L"--mapped") == 0) {
      mapped = true;
    } else {
      path = argv[index];
    }
  }
  if (path == nullptr) {
    std::fprintf(stderr,
                 "usage: fushi_catsystem2_site_probe [--mapped] <image>\n");
    return 2;
  }
  std::vector<uint8_t> bytes;
  if (!ReadWholeFile(path, &bytes)) {
    std::fprintf(stderr, "cannot read input\n");
    return 2;
  }
  uint32_t image_base = 0u;
  uint8_t* view = MapImage(bytes, mapped, &image_base);
  if (view == nullptr) {
    std::fprintf(stderr, "not an x86 PE image\n");
    return 2;
  }
  exact::LoadedPeImage image;
  if (!exact::OpenLoadedPeImage(reinterpret_cast<HMODULE>(view), &image)) {
    std::fprintf(stderr, "image headers rejected\n");
    return 2;
  }
  image.absolute_base = image_base;

  cs2::ImportSlots imports;
  imports.get_glyph_outline =
      cs2::FindImportSlotRva(image, "gdi32.dll", "GetGlyphOutlineA");
  imports.set_capture =
      cs2::FindImportSlotRva(image, "user32.dll", "SetCapture");
  imports.release_capture =
      cs2::FindImportSlotRva(image, "user32.dll", "ReleaseCapture");
  imports.window_from_point =
      cs2::FindImportSlotRva(image, "user32.dll", "WindowFromPoint");
  imports.get_foreground_window =
      cs2::FindImportSlotRva(image, "user32.dll", "GetForegroundWindow");
  cs2::Sites sites;
  const cs2::SiteResult lookup = cs2::ResolveSites(image, imports, &sites);
  std::printf("lookup result=%u variant=%u render_args=%u input_args=%u\n",
              static_cast<unsigned>(lookup),
              static_cast<unsigned>(sites.variant), sites.render_stack_args,
              sites.input_stack_args);
  std::printf("  render_char=0x%zx clear_page=0x%zx window_update=0x%zx\n",
              Rva(image, sites.render_char), Rva(image, sites.clear_page),
              Rva(image, sites.window_update));
  std::printf("  input_handler=0x%zx char_image=0x%zx rasteriser=0x%zx\n",
              Rva(image, sites.input_handler), Rva(image, sites.char_image),
              Rva(image, sites.rasteriser));
  std::printf("  walk list=+0x%zx head=+0x%zx layer_by_pointer=%d\n",
              sites.walk.list_offset, sites.walk.head_offset,
              sites.walk.layer_by_pointer ? 1 : 0);
  std::printf(
      "  layout window.screen=+0x%zx window.renderer=+0x%zx page=+0x%zx/"
      "+0x%zx work=+0x%zx\n",
      sites.layout.window_screen, sites.layout.window_renderer,
      sites.layout.page_width, sites.layout.page_height,
      sites.layout.work_image);

  cs2_voice::VoiceImportSlots voice_imports;
  voice_imports.set_file_pointer =
      cs2::FindImportSlotRva(image, "kernel32.dll", "SetFilePointer");
  voice_imports.read_file =
      cs2::FindImportSlotRva(image, "kernel32.dll", "ReadFile");
  cs2_voice::VoiceSites voice_sites;
  const cs2_voice::VoiceSiteResult voice =
      cs2_voice::ResolveVoiceSites(image, voice_imports, &voice_sites);
  std::printf("voice result=%u\n", static_cast<unsigned>(voice));
  std::printf("  read_entry=0x%zx big_read_call=0x%zx plain_block=0x%zx\n",
              Rva(image, voice_sites.read_entry),
              Rva(image, voice_sites.big_read),
              Rva(image, voice_sites.plain_block));
  VirtualFree(view, 0u, MEM_RELEASE);
  return lookup == cs2::SiteResult::kResolved &&
                 voice == cs2_voice::VoiceSiteResult::kResolved
             ? 0
             : 1;
}
