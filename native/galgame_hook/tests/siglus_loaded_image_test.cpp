#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <array>
#include <cstdint>
#include <cstring>

#include "siglus_image.h"

namespace {

using fushi_voice_hook::exact_lookup::LoadedPeImage;
using fushi_voice_hook::OpenSiglusLoadedImage;
namespace lookup = fushi_voice_hook::exact_lookup;

class TestImage {
 public:
  static constexpr uint32_t kSize = 0x6000u;
  static constexpr uint32_t kNt = 0x80u;

  TestImage() {
    bytes = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    assert(bytes != nullptr);
    IMAGE_DOS_HEADER dos{};
    dos.e_magic = IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = kNt;
    std::memcpy(bytes, &dos, sizeof(dos));
    sections[0].VirtualAddress = 0x1000u;
    sections[0].Misc.VirtualSize = 0x2000u;
    sections[0].SizeOfRawData = 0x100u;
    sections[0].Characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE;
    sections[1].VirtualAddress = 0x3000u;
    sections[1].Misc.VirtualSize = 0x1000u;
    sections[1].SizeOfRawData = 0x100u;
    sections[1].Characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE;
    sections[2].VirtualAddress = 0x4000u;
    sections[2].Misc.VirtualSize = 0x1000u;
    sections[2].SizeOfRawData = 0x1000u;
    sections[2].Characteristics = IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE;
    Headers();
  }

  ~TestImage() { if (bytes != nullptr) VirtualFree(bytes, 0u, MEM_RELEASE); }
  TestImage(const TestImage&) = delete;
  TestImage& operator=(const TestImage&) = delete;

  void Headers(bool optional64 = false,
               uint16_t machine = IMAGE_FILE_MACHINE_I386) {
    size_t section_offset = 0u;
    if (optional64) {
      IMAGE_NT_HEADERS64 nt{};
      nt.Signature = IMAGE_NT_SIGNATURE;
      nt.FileHeader.Machine = machine;
      nt.FileHeader.NumberOfSections = static_cast<WORD>(sections.size());
      nt.FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER64);
      nt.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
      nt.OptionalHeader.SizeOfImage = kSize;
      std::memcpy(bytes + kNt, &nt, sizeof(nt));
      section_offset = kNt + sizeof(nt);
    } else {
      IMAGE_NT_HEADERS32 nt{};
      nt.Signature = IMAGE_NT_SIGNATURE;
      nt.FileHeader.Machine = machine;
      nt.FileHeader.NumberOfSections = static_cast<WORD>(sections.size());
      nt.FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER32);
      nt.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
      nt.OptionalHeader.SizeOfImage = kSize;
      std::memcpy(bytes + kNt, &nt, sizeof(nt));
      section_offset = kNt + sizeof(nt);
    }
    std::memcpy(bytes + section_offset, sections.data(), sizeof(sections));
  }

  HMODULE module() const { return reinterpret_cast<HMODULE>(bytes); }

  uint8_t* bytes = nullptr;
  std::array<IMAGE_SECTION_HEADER, 3u> sections{};
};

void PackedRawExtentIsOptIn() {
  TestImage test;
  LoadedPeImage image;
  assert(lookup::OpenLoadedPeImage(test.module(), &image));
  test.sections[0].SizeOfRawData = TestImage::kSize + 0x1000u;
  test.Headers();
  assert(!lookup::OpenLoadedPeImage(test.module(), &image));
  assert(image.base == nullptr && image.section_count == 0u);
  assert(OpenSiglusLoadedImage(test.module(), &image));
  assert(image.section_count == 3u && image.size == TestImage::kSize);
  assert(image.sections[0].rva == 0x1000u);
  assert(image.sections[0].size == 0x2000u);
  assert(image.sections[1].size == 0x1000u);
}

void InvalidVirtualExtents() {
  for (const uint32_t size : {0x6000u, UINT32_MAX}) {
    TestImage test;
    test.sections[0].Misc.VirtualSize = size;
    test.Headers();
    LoadedPeImage image;
    assert(!OpenSiglusLoadedImage(test.module(), &image));
    assert(image.base == nullptr && image.section_count == 0u);
  }
  for (const uint32_t rva : {TestImage::kSize, UINT32_MAX}) {
    TestImage test;
    test.sections[0].VirtualAddress = rva;
    test.Headers();
    LoadedPeImage image;
    assert(!OpenSiglusLoadedImage(test.module(), &image));
  }
  for (const uint32_t rva : {0x1000u, 0x2800u}) {
    TestImage test;
    test.sections[1].VirtualAddress = rva;
    test.Headers();
    LoadedPeImage image;
    assert(!OpenSiglusLoadedImage(test.module(), &image));
    assert(image.base == nullptr && image.section_count == 0u);
  }
  TestImage test;
  // Overlap remains invalid when the later section contains data.
  test.sections[2].VirtualAddress = 0x3800u;
  test.Headers();
  LoadedPeImage image;
  assert(!OpenSiglusLoadedImage(test.module(), &image));
}

void UnreadableExecutableExtent() {
  for (const DWORD protection : {PAGE_NOACCESS, PAGE_READWRITE | PAGE_GUARD}) {
    TestImage test;
    DWORD old = 0u;
    // A readable prefix is insufficient: the whole virtual code range must
    // be inspectable, including pages beyond the smaller raw extent.
    assert(VirtualProtect(test.bytes + 0x2000u, 0x1000u, protection, &old));
    LoadedPeImage image;
    assert(!OpenSiglusLoadedImage(test.module(), &image));
    assert(image.base == nullptr && image.section_count == 0u);
  }
}

void ScanAllVirtualExecutableBytes() {
  TestImage test;
  test.sections[0].SizeOfRawData = TestImage::kSize + 0x1000u;
  test.Headers();
  constexpr uint8_t bytes[] = {0xa7u, 0x53u, 0x19u, 0xd2u, 0x6eu};
  const lookup::MaskedPattern pattern = {bytes, nullptr, sizeof(bytes)};
  LoadedPeImage image;
  assert(OpenSiglusLoadedImage(test.module(), &image));
  const uint32_t first = 0x3000u - sizeof(bytes);
  const uint32_t second = 0x4000u - sizeof(bytes);
  std::memcpy(test.bytes + first, bytes, sizeof(bytes));
  auto match = lookup::FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 1u && match.address == test.bytes + first);
  std::memcpy(test.bytes + second, bytes, sizeof(bytes));
  match = lookup::FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 2u && match.address == nullptr);
  std::memset(test.bytes + first, 0, sizeof(bytes));
  match = lookup::FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 1u && match.address == test.bytes + second);
  std::memcpy(test.bytes + 0x4200u, bytes, sizeof(bytes));
  match = lookup::FindUniquePatternInExecutableSections(image, pattern);
  assert(match.count == 1u && match.address == test.bytes + second);
}

void ZeroVirtualSizeUsesBoundedRawExtent() {
  TestImage test;
  test.sections[0].Misc.VirtualSize = 0u;
  test.sections[0].SizeOfRawData = 0x2000u;
  test.Headers();
  LoadedPeImage image;
  assert(OpenSiglusLoadedImage(test.module(), &image));
  assert(image.sections[0].size == 0x2000u);
  for (const uint32_t raw_size : {0u, TestImage::kSize, UINT32_MAX}) {
    test.sections[0].SizeOfRawData = raw_size;
    test.Headers();
    assert(!OpenSiglusLoadedImage(test.module(), &image));
    assert(image.base == nullptr && image.section_count == 0u);
  }
}

void RejectOtherArchitectures() {
  TestImage test;
  LoadedPeImage image;
  test.Headers(false, IMAGE_FILE_MACHINE_AMD64);
  assert(!OpenSiglusLoadedImage(test.module(), &image));
  assert(image.base == nullptr && image.section_count == 0u);
  test.Headers(true, IMAGE_FILE_MACHINE_AMD64);
  assert(!OpenSiglusLoadedImage(test.module(), &image));
  test.Headers(true, IMAGE_FILE_MACHINE_I386);
  assert(!OpenSiglusLoadedImage(test.module(), &image));
  test.Headers(false, IMAGE_FILE_MACHINE_ARMNT);
  assert(!OpenSiglusLoadedImage(test.module(), &image));
  assert(!OpenSiglusLoadedImage(nullptr, &image));
  assert(!OpenSiglusLoadedImage(test.module(), nullptr));
}

}  // namespace

int main() {
  PackedRawExtentIsOptIn();
  InvalidVirtualExtents();
  UnreadableExecutableExtent();
  ScanAllVirtualExecutableBytes();
  ZeroVirtualSizeUsesBoundedRawExtent();
  RejectOtherArchitectures();
  return 0;
}
