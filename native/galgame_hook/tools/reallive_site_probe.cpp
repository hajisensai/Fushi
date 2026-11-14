// RealLive offline site probe: runs the hook DLL's own import-slot reader and
// structural site resolver (reallive_lookup_core.h) over a game image read
// from disk and prints every step, as RVAs.
//
// Purpose: when a machine reports `reallive-lookup: sites unresolved
// result=N`, the exe (or a flat dump of its main module) can be checked
// offline against the exact code the hook runs, without launching or
// injecting anything.
//
// Usage:
//   fushi_reallive_site_probe <RealLive.exe>          disk image, mapped here
//   fushi_reallive_site_probe --mapped <module.mem>   flat dump of the loaded
//                                                     main module
//
// The input is untrusted data: it is only read and copied into a private
// read/write buffer laid out by section; nothing in it is executed, no loader
// is involved and no relocation is applied (absolute operands are resolved
// against the header's ImageBase, which is also what an unrelocated dump
// carries).  Exit code: 0 resolved, 1 unresolved, 2 unreadable input.

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "reallive_lookup_core.h"

namespace {

namespace exact = fushi_voice_hook::exact_lookup;
namespace core = fushi_voice_hook::reallive_lookup;

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
  out->sections = reinterpret_cast<const IMAGE_SECTION_HEADER*>(
      bytes.data() + section_table);
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

const char* ResultName(core::SiteResult result) {
  switch (result) {
    case core::SiteResult::kResolved: return "kResolved";
    case core::SiteResult::kNotX86: return "kNotX86";
    case core::SiteResult::kImportsMissing: return "kImportsMissing";
    case core::SiteResult::kGlyphPathMissing: return "kGlyphPathMissing";
    case core::SiteResult::kGlyphJoinInvalid: return "kGlyphJoinInvalid";
    case core::SiteResult::kGlyphFrameInvalid: return "kGlyphFrameInvalid";
    case core::SiteResult::kRasterInvalid: return "kRasterInvalid";
    case core::SiteResult::kKeyPathMissing: return "kKeyPathMissing";
    case core::SiteResult::kFocusInvalid: return "kFocusInvalid";
    case core::SiteResult::kCompositeMissing: return "kCompositeMissing";
    case core::SiteResult::kBlitInvalid: return "kBlitInvalid";
  }
  return "?";
}

// Match count and first match RVA of one of the resolver's own signatures.
void PrintPattern(const exact::LoadedPeImage& image, const char* name,
                  const uint8_t* bytes, const uint8_t* mask, size_t size) {
  const exact::MaskedPattern pattern = {bytes, mask, size};
  const auto match =
      exact::FindUniquePatternInExecutableSections(image, pattern);
  std::printf("  signature %-9s matches=%u at=0x%zx\n", name,
              static_cast<unsigned>(match.count),
              match.address == nullptr
                  ? static_cast<size_t>(0u)
                  : static_cast<size_t>(
                        Rva(image, reinterpret_cast<uintptr_t>(match.address))));
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
                 "usage: fushi_reallive_site_probe [--mapped] <image>\n");
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
    VirtualFree(view, 0u, MEM_RELEASE);
    return 2;
  }
  image.absolute_base = image_base;
  std::printf("image machine=0x%x bits=%u base=0x%x size=0x%zx sections=%zu\n",
              static_cast<unsigned>(image.machine),
              static_cast<unsigned>(image.pointer_bits),
              static_cast<unsigned>(image_base), image.size,
              image.section_count);
  for (size_t index = 0u; index < image.section_count; ++index) {
    const exact::LoadedPeSection& section = image.sections[index];
    std::printf("  section rva=0x%zx size=0x%zx ch=0x%08lx\n",
                static_cast<size_t>(
                    Rva(image, reinterpret_cast<uintptr_t>(section.bytes))),
                section.size, static_cast<unsigned long>(section.characteristics));
  }

  // Step 1: the same import-slot reader the hook calls.
  const core::ImportSlots imports = core::FindLookupImportSlots(image);
  std::printf("imports GetKeyboardState=0x%zx GetFocus=0x%zx "
              "glyph_outline=0x%zx\n",
              static_cast<size_t>(imports.get_keyboard_state),
              static_cast<size_t>(imports.get_focus),
              static_cast<size_t>(imports.get_glyph_outline));

  // Step 2: the resolver's signatures, counted image-wide.
  PrintPattern(image, "glyph", core::kGlyphPathBytes,
               core::kGlyphPathMask.data(), sizeof(core::kGlyphPathBytes));
  const char* const kKeyShapeNames[] = {"key.plain", "key.norm"};
  static_assert(sizeof(kKeyShapeNames) / sizeof(kKeyShapeNames[0]) ==
                    sizeof(core::kKeyPathShapes) /
                        sizeof(core::kKeyPathShapes[0]),
                "one name per key-poll shape");
  for (size_t index = 0u; index < sizeof(core::kKeyPathShapes) /
                                      sizeof(core::kKeyPathShapes[0]);
       ++index) {
    const core::KeyPathShape& shape = core::kKeyPathShapes[index];
    PrintPattern(image, kKeyShapeNames[index], shape.bytes, shape.mask,
                 shape.size);
  }
  PrintPattern(image, "composite", core::kCompositeCallBytes,
               core::kCompositeCallMask.data(),
               sizeof(core::kCompositeCallBytes));

  // Step 3: the resolver itself (first failing proof is its result).
  core::Sites sites;
  const core::SiteResult result = core::ResolveSites(image, imports, &sites);
  std::printf("result=%u %s\n", static_cast<unsigned>(result),
              ResultName(result));
  std::printf("  join=0x%zx raster=0x%zx key=0x%zx blit=0x%zx\n",
              static_cast<size_t>(Rva(image, sites.glyph_join)),
              static_cast<size_t>(Rva(image, sites.raster)),
              static_cast<size_t>(Rva(image, sites.key_join)),
              static_cast<size_t>(Rva(image, sites.composite_blit)));
  std::printf("  size=0x%zx screen=0x%zx w=0x%zx h=0x%zx hwnd=0x%zx\n",
              static_cast<size_t>(sites.font_size_rva),
              static_cast<size_t>(sites.screen_bits_rva),
              static_cast<size_t>(sites.screen_width_rva),
              static_cast<size_t>(sites.screen_height_rva),
              static_cast<size_t>(sites.window_rva));
  VirtualFree(view, 0u, MEM_RELEASE);
  return result == core::SiteResult::kResolved ? 0 : 1;
}
