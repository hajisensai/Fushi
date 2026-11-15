// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <windows.h>

#include <array>
#include <cassert>
#include <cstdint>
#include <cstring>

#include "malie_engine_io_core.h"

// Chromium / Electron executables (TyranoScript Electron builds, NW.js, ...)
// carry a `.retplne` section whose Characteristics are 0: no IMAGE_SCN_MEM_READ,
// so the loader maps it PAGE_NOACCESS. Every startup adapter probes the main
// image before the game thread resumes; handing that section's pointer to a
// section scanner (the Malie identity fingerprint was the first one) raised an
// access violation inside the game and killed it at launch. The loaded-image
// view must expose such a section without bytes.

namespace exact = fushi_voice_hook::exact_lookup;
namespace io = fushi_voice_hook::malie_io;

namespace {

class ChromiumLikeImage {
 public:
  static constexpr uint32_t kSize = 0x6000u;
  static constexpr uint32_t kNt = 0x80u;

  ChromiumLikeImage() {
    bytes = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    assert(bytes != nullptr);
    IMAGE_DOS_HEADER dos{};
    dos.e_magic = IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = kNt;
    std::memcpy(bytes, &dos, sizeof(dos));
    // .text
    sections[0].VirtualAddress = 0x1000u;
    sections[0].Misc.VirtualSize = 0x2000u;
    sections[0].SizeOfRawData = 0x2000u;
    sections[0].Characteristics =
        IMAGE_SCN_CNT_CODE | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE;
    // .rdata
    sections[1].VirtualAddress = 0x3000u;
    sections[1].Misc.VirtualSize = 0x1000u;
    sections[1].SizeOfRawData = 0x1000u;
    sections[1].Characteristics =
        IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ;
    // .retplne: Characteristics 0, mapped PAGE_NOACCESS by the loader.
    std::memcpy(sections[2].Name, ".retplne", 8u);
    sections[2].VirtualAddress = 0x4000u;
    sections[2].Misc.VirtualSize = 0xf4u;
    sections[2].SizeOfRawData = 0x200u;
    sections[2].Characteristics = 0u;
    // .reloc
    sections[3].VirtualAddress = 0x5000u;
    sections[3].Misc.VirtualSize = 0x1000u;
    sections[3].SizeOfRawData = 0x1000u;
    sections[3].Characteristics = IMAGE_SCN_CNT_INITIALIZED_DATA |
                                  IMAGE_SCN_MEM_DISCARDABLE |
                                  IMAGE_SCN_MEM_READ;

    IMAGE_NT_HEADERS64 nt{};
    nt.Signature = IMAGE_NT_SIGNATURE;
    nt.FileHeader.Machine = IMAGE_FILE_MACHINE_AMD64;
    nt.FileHeader.NumberOfSections = static_cast<WORD>(sections.size());
    nt.FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER64);
    nt.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
    nt.OptionalHeader.SizeOfImage = kSize;
    std::memcpy(bytes + kNt, &nt, sizeof(nt));
    std::memcpy(bytes + kNt + sizeof(nt), sections.data(), sizeof(sections));
    for (uint32_t at = 0x1000u; at < 0x4000u; ++at) {
      bytes[at] = static_cast<uint8_t>(at * 31u);
    }
    DWORD old = 0u;
    assert(VirtualProtect(bytes + 0x4000u, 0x1000u, PAGE_NOACCESS, &old));
  }

  ~ChromiumLikeImage() {
    if (bytes != nullptr) VirtualFree(bytes, 0u, MEM_RELEASE);
  }
  ChromiumLikeImage(const ChromiumLikeImage&) = delete;
  ChromiumLikeImage& operator=(const ChromiumLikeImage&) = delete;

  HMODULE module() const { return reinterpret_cast<HMODULE>(bytes); }

  uint8_t* bytes = nullptr;
  std::array<IMAGE_SECTION_HEADER, 4u> sections{};
};

void UnreadableSectionHasNoBytes() {
  ChromiumLikeImage test;
  exact::LoadedPeImage image;
  assert(exact::OpenLoadedPeImage(test.module(), &image));
  assert(image.section_count == 4u);
  assert(image.sections[0].bytes == test.bytes + 0x1000u);
  assert(image.sections[0].size == 0x2000u);
  assert(image.sections[1].bytes == test.bytes + 0x3000u);
  // The unreadable section keeps its identity but exposes nothing to scan.
  assert(image.sections[2].rva == 0x4000u);
  assert(image.sections[2].characteristics == 0u);
  assert(image.sections[2].bytes == nullptr);
  assert(image.sections[2].size == 0u);
  assert(exact::FindSectionForRva(image, 0x4000u, 1u) == nullptr);
  assert(exact::FindSectionForRva(image, 0x3000u, 1u) == &image.sections[1]);

  // The same holds for the virtual-size extent policy.
  exact::LoadedPeImage virtual_image;
  assert(exact::OpenLoadedPeImage(
      test.module(), &virtual_image,
      exact::LoadedPeSectionExtent::kVirtualSize));
  assert(virtual_image.sections[2].bytes == nullptr);
  assert(virtual_image.sections[2].size == 0u);
}

void MalieFingerprintSkipsUnreadableSection() {
  ChromiumLikeImage test;
  exact::LoadedPeImage image;
  assert(exact::OpenLoadedPeImage(test.module(), &image));
  // Used to fault on the PAGE_NOACCESS section.
  const uint64_t before = io::ImageFingerprint(image);
  assert(before == io::ImageFingerprint(image));
  // Still a real fingerprint of the readable code: changing code changes it.
  test.bytes[0x1000u] ^= 0x5au;
  assert(io::ImageFingerprint(image) != before);
  // And the structural identity probe stays a plain refusal, not a crash.
  const io::SchemeResult result =
      io::ResolveScheme(image, io::kArchiveSchemeName);
  assert(result != io::SchemeResult::kResolved);
}

void UnreadableExecutableSectionStillFailsClosed() {
  ChromiumLikeImage test;
  DWORD old = 0u;
  assert(VirtualProtect(test.bytes + 0x2000u, 0x1000u, PAGE_NOACCESS, &old));
  exact::LoadedPeImage image;
  assert(exact::OpenLoadedPeImage(test.module(), &image));
  assert(image.sections[0].bytes == nullptr && image.sections[0].size == 0u);
  constexpr uint8_t bytes[] = {0x11u, 0x22u, 0x33u};
  const exact::MaskedPattern pattern = {bytes, nullptr, sizeof(bytes)};
  // An executable section that cannot be inspected must not read as "no
  // match": image-wide uniqueness is unknown.
  const auto match = exact::FindUniquePatternInExecutableSections(image, pattern);
  assert(match.address == nullptr && match.count == 2u);
}

}  // namespace

int main() {
  UnreadableSectionHasNoBytes();
  MalieFingerprintSkipsUnreadableSection();
  UnreadableExecutableSectionStillFailsClosed();
  return 0;
}
