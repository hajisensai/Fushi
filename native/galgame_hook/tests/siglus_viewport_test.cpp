#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <array>
#include <cstdint>
#include <cstring>

#include "siglus_viewport.h"

namespace {

using fushi_voice_hook::exact_lookup::LoadedPeImage;
namespace viewport = fushi_voice_hook::siglus_viewport;

// Entirely synthetic loaded PE32 image; the preferred VA is deliberately
// independent of the host allocation so these tests run on x86 and x64.
class TestImage {
 public:
  static constexpr uint32_t kBase = 0x400000u;
  static constexpr uint32_t kSize = 0x3000u;
  static constexpr uint32_t kNt = 0x80u;
  static constexpr uint32_t kImports = 0x1000u;
  static constexpr uint32_t kDll = 0x1100u;
  static constexpr uint32_t kLookup = 0x1200u;
  static constexpr uint32_t kIat = 0x1300u;
  static constexpr uint32_t kName = 0x1400u;
  static constexpr uint32_t kSlot = 0x1600u;

  TestImage() {
    image.base = bytes.data();
    image.absolute_base = kBase;
    image.size = bytes.size();
    image.machine = IMAGE_FILE_MACHINE_I386;
    image.pointer_bits = 32u;
    image.section_count = 2u;
    image.sections[0] = {bytes.data() + 0x400u, 0xc00u, 0x400u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {bytes.data() + 0x1000u, 0x2000u, 0x1000u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};

    IMAGE_DOS_HEADER dos{};
    dos.e_magic = IMAGE_DOS_SIGNATURE;
    dos.e_lfanew = kNt;
    Write(0u, dos);
    IMAGE_NT_HEADERS32 nt{};
    nt.Signature = IMAGE_NT_SIGNATURE;
    nt.FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
    nt.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
    nt.OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
    nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT] = {
        kImports, 2u * sizeof(IMAGE_IMPORT_DESCRIPTOR)};
    Write(kNt, nt);

    descriptor.OriginalFirstThunk = kLookup;
    descriptor.Name = kDll;
    descriptor.FirstThunk = kIat;
    Write(kImports, descriptor);
    WriteName(kDll, "user32.dll");
    Write(kLookup, kName);
    Write(kIat, uint32_t{0x76543210u});  // A resolved live function address.
    WriteName(kName + sizeof(WORD), "GetKeyState");
  }

  TestImage(const TestImage&) = delete;
  TestImage& operator=(const TestImage&) = delete;

  template <typename T>
  void Write(uint32_t rva, const T& value) {
    assert(rva <= bytes.size() && sizeof(value) <= bytes.size() - rva);
    std::memcpy(bytes.data() + rva, &value, sizeof(value));
  }

  void WriteName(uint32_t rva, const char* name) {
    const size_t size = std::strlen(name) + 1u;
    assert(rva <= bytes.size() && size <= bytes.size() - rva);
    std::memcpy(bytes.data() + rva, name, size);
  }

  void Render(uint32_t rva, uint32_t slot = kSlot) {
    std::memcpy(bytes.data() + rva, viewport::kRenderSizeBytes,
                sizeof(viewport::kRenderSizeBytes));
    Write(rva + 2u, kBase + slot);
    Write(rva + 9u, uint32_t{kBase + 0x1700u});
  }

  void Normalize(uint32_t rva, uint32_t slot = kSlot) {
    std::memcpy(bytes.data() + rva, viewport::kNormalizeSizeBytes,
                sizeof(viewport::kNormalizeSizeBytes));
    Write(rva + 2u, kBase + slot);
  }

  std::array<uint8_t, kSize> bytes{};
  LoadedPeImage image{};
  IMAGE_IMPORT_DESCRIPTOR descriptor{};
};

void ConfigSlotRelocation() {
  // Each function can move independently; no shared delta or title RVA is
  // assumed. Both decoded operands must still identify the same data slot.
  for (const uint32_t render : {0x420u, 0x680u}) {
    for (const uint32_t normalize : {0x800u, 0xb20u}) {
      TestImage test;
      test.Render(render);
      test.Normalize(normalize);
      assert(viewport::ResolveConfigSlot(test.image) == TestImage::kSlot);
      test.Write(render + 9u, uint32_t{0x412344u});
      assert(viewport::ResolveConfigSlot(test.image) == TestImage::kSlot);
      test.Normalize(normalize, TestImage::kSlot + 4u);
      assert(viewport::ResolveConfigSlot(test.image) == 0u);
    }
  }
}

void ConfigSlotSectionAndUniqueness() {
  for (const uint32_t slot : {0x600u, 0x200u, 0x3000u,
                              TestImage::kSlot + 1u}) {
    TestImage test;
    test.Render(0x420u, slot);
    test.Normalize(0x800u, slot);
    assert(viewport::ResolveConfigSlot(test.image) == 0u);
  }
  constexpr std::array<uint32_t, 2u> invalid_roles = {
      IMAGE_SCN_MEM_READ,
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE};
  for (const uint32_t role : invalid_roles) {
    TestImage test;
    test.Render(0x420u);
    test.Normalize(0x800u);
    test.image.sections[1].characteristics = role;
    assert(viewport::ResolveConfigSlot(test.image) == 0u);
  }
  for (const bool duplicate_render : {false, true}) {
    TestImage test;
    test.Render(0x420u);
    test.Normalize(0x800u);
    if (duplicate_render) test.Render(0xc00u);
    else test.Normalize(0xc00u);
    assert(viewport::ResolveConfigSlot(test.image) == 0u);
  }
  for (const bool render_in_data : {false, true}) {
    TestImage test;
    test.Render(render_in_data ? 0x2000u : 0x420u);
    test.Normalize(render_in_data ? 0x800u : 0x2000u);
    assert(viewport::ResolveConfigSlot(test.image) == 0u);
  }
  TestImage test;
  test.Render(0x420u);
  test.Normalize(0x800u);
  // Data copies do not create executable ambiguity.
  test.Render(0x2000u);
  test.Normalize(0x2200u);
  assert(viewport::ResolveConfigSlot(test.image) == TestImage::kSlot);
  test.image.machine = IMAGE_FILE_MACHINE_AMD64;
  assert(viewport::ResolveConfigSlot(test.image) == 0u);
  test.image.machine = IMAGE_FILE_MACHINE_I386;
  test.image.pointer_bits = 64u;
  assert(viewport::ResolveConfigSlot(test.image) == 0u);
}

void DesignSizeBounds() {
  assert(viewport::ValidDesignSize(1280, 720));
  assert(viewport::ValidDesignSize(1920, 1080));
  assert(viewport::ValidDesignSize(256, 256));
  assert(viewport::ValidDesignSize(16384, 16384));
  for (const int32_t invalid : {-1, 0, 255, 16385, INT32_MAX}) {
    assert(!viewport::ValidDesignSize(invalid, 720));
    assert(!viewport::ValidDesignSize(1280, invalid));
  }
}

void NamedImportIdentity() {
  for (const char* dll : {"user32.dll", "USER32.DLL", "UsEr32.DlL"}) {
    TestImage test;
    test.WriteName(TestImage::kDll, dll);
    assert(viewport::FindGetKeyStateImport(test.image) == TestImage::kIat);
  }
  for (const char* symbol : {"GetAsyncKeyState", "getkeystate", "GetKeyStateEx"}) {
    TestImage test;
    test.WriteName(TestImage::kName + sizeof(WORD), symbol);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  for (const char* dll : {"kernel32.dll", "user32.dll.extra", "user32"}) {
    TestImage test;
    test.WriteName(TestImage::kDll, dll);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  TestImage test;
  test.Write(TestImage::kLookup, uint32_t{IMAGE_ORDINAL_FLAG32 | 1u});
  assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  test.Write(TestImage::kLookup, TestImage::kName);
  test.descriptor.OriginalFirstThunk = 0u;
  test.Write(TestImage::kImports, test.descriptor);
  assert(viewport::FindGetKeyStateImport(test.image) == 0u);
}

void ImportBoundsAndAmbiguity() {
  for (const uint32_t lookup : {TestImage::kSize - 2u, TestImage::kSize,
                                UINT32_MAX}) {
    TestImage test;
    test.descriptor.OriginalFirstThunk = lookup;
    test.Write(TestImage::kImports, test.descriptor);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  for (const uint32_t thunk : {0u, 0x420u, TestImage::kIat + 1u,
                               TestImage::kSize, UINT32_MAX}) {
    TestImage test;
    test.descriptor.FirstThunk = thunk;
    test.Write(TestImage::kImports, test.descriptor);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  for (const uint32_t name : {TestImage::kSize - 3u, TestImage::kSize,
                              UINT32_MAX - 1u}) {
    TestImage test;
    test.Write(TestImage::kLookup, name);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
    test.Write(TestImage::kLookup, TestImage::kName);
    test.descriptor.Name = name;
    test.Write(TestImage::kImports, test.descriptor);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  {
    TestImage test;
    test.Write(TestImage::kLookup + 4u, TestImage::kName);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  {
    TestImage test;
    // The import-name table must terminate inside the mapped image, even
    // after finding a valid symbol.
    test.descriptor.OriginalFirstThunk = TestImage::kSize - 4u;
    test.Write(TestImage::kSize - 4u, TestImage::kName);
    test.Write(TestImage::kImports, test.descriptor);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  {
    TestImage test;
    IMAGE_NT_HEADERS32 nt{};
    std::memcpy(&nt, test.bytes.data() + TestImage::kNt, sizeof(nt));
    nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size =
        TestImage::kSize;
    test.Write(TestImage::kNt, nt);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
    nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size =
        sizeof(IMAGE_IMPORT_DESCRIPTOR);  // Missing descriptor terminator.
    test.Write(TestImage::kNt, nt);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
  {
    TestImage test;
    test.image.sections[1].characteristics |= IMAGE_SCN_MEM_EXECUTE;
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
  }
}

constexpr uint32_t kBoundGetKeyState = 0x76543210u;

void UseBoundImport(TestImage& test) {
  test.descriptor.OriginalFirstThunk = 0u;
  test.Write(TestImage::kImports, test.descriptor);
}

void BoundImportIdentity() {
  for (const char* dll : {"user32.dll", "USER32.DLL", "UsEr32.DlL"}) {
    TestImage test;
    UseBoundImport(test);
    test.WriteName(TestImage::kDll, dll);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) ==
           TestImage::kIat);
    assert(viewport::FindGetKeyStateImport(test.image) == 0u);
    assert(viewport::FindGetKeyStateImport(test.image, 0u) == 0u);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState + 4u) ==
           0u);
  }
  for (const char* dll : {"kernel32.dll", "user32.dll.extra", "user32"}) {
    TestImage test;
    UseBoundImport(test);
    test.WriteName(TestImage::kDll, dll);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
  {
    TestImage test;
    UseBoundImport(test);
    // Another executable address is insufficient, even inside this image.
    test.Write(TestImage::kIat, uint32_t{TestImage::kBase + 0x420u});
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
  {
    TestImage test;
    UseBoundImport(test);
    // Locate the exact export after an unrelated resolved import.
    test.Write(TestImage::kIat, uint32_t{kBoundGetKeyState + 4u});
    test.Write(TestImage::kIat + 4u, kBoundGetKeyState);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) ==
           TestImage::kIat + 4u);
  }
#if defined(_WIN64)
  {
    TestImage test;
    UseBoundImport(test);
    // Truncating a host-sized export address must not match its low 32 bits.
    const uintptr_t too_wide = (uintptr_t{1u} << 32u) | kBoundGetKeyState;
    assert(viewport::FindGetKeyStateImport(test.image, too_wide) == 0u);
  }
#endif
  {
    TestImage test;
    // When OFT exists, import identity remains authoritative. Supplying an
    // export address must not turn a differently named symbol into a match.
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState + 4u) ==
           TestImage::kIat);
    test.WriteName(TestImage::kName + sizeof(WORD), "GetAsyncKeyState");
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
}

void BoundImportBoundsAndAmbiguity() {
  {
    TestImage test;
    UseBoundImport(test);
    test.Write(TestImage::kIat + 4u, kBoundGetKeyState);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
  for (const bool second_has_names : {false, true}) {
    TestImage test;
    UseBoundImport(test);
    IMAGE_NT_HEADERS32 nt{};
    std::memcpy(&nt, test.bytes.data() + TestImage::kNt, sizeof(nt));
    nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].Size =
        3u * sizeof(IMAGE_IMPORT_DESCRIPTOR);
    test.Write(TestImage::kNt, nt);
    IMAGE_IMPORT_DESCRIPTOR second = test.descriptor;
    second.FirstThunk = TestImage::kIat + 0x20u;
    second.OriginalFirstThunk = second_has_names ? TestImage::kLookup : 0u;
    test.Write(TestImage::kImports + sizeof(IMAGE_IMPORT_DESCRIPTOR), second);
    test.Write(second.FirstThunk, kBoundGetKeyState);
    // Ambiguity is global across user32 descriptors and both lookup modes.
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
  for (const uint32_t thunk : {0u, TestImage::kIat + 1u,
                               TestImage::kSize - 2u, TestImage::kSize,
                               UINT32_MAX}) {
    TestImage test;
    test.descriptor.FirstThunk = thunk;
    UseBoundImport(test);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
  {
    TestImage test;
    test.descriptor.FirstThunk = TestImage::kSize - 4u;
    UseBoundImport(test);
    test.Write(TestImage::kSize - 4u, kBoundGetKeyState);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
  {
    TestImage test;
    test.descriptor.FirstThunk = 0x420u;
    UseBoundImport(test);
    test.Write(0x420u, kBoundGetKeyState);
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
  constexpr std::array<uint32_t, 2u> invalid_roles = {
      IMAGE_SCN_MEM_WRITE,
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE};
  for (const uint32_t role : invalid_roles) {
    TestImage test;
    UseBoundImport(test);
    test.image.sections[1].characteristics = role;
    assert(viewport::FindGetKeyStateImport(test.image, kBoundGetKeyState) == 0u);
  }
}

void VerifiedUser32Imports() {
  constexpr uintptr_t target = 0x76543210u;
  for (const char* symbol : {"GetKeyboardState", "GetCursorPos",
                            "GetActiveWindow", "ScreenToClient"}) {
    TestImage test;
    test.WriteName(TestImage::kName + sizeof(WORD), symbol);
    assert(viewport::FindVerifiedUser32Import(test.image, symbol, target) ==
           TestImage::kIat);
    assert(viewport::FindGetKeyStateImport(test.image) == 0);
    assert(viewport::FindVerifiedUser32Import(test.image, symbol, 0) == 0);
    assert(viewport::FindVerifiedUser32Import(test.image, symbol, target + 4) == 0);
    assert(viewport::FindVerifiedUser32Import(test.image, "DifferentExport", target) == 0);
    test.Write(TestImage::kIat, uint32_t{0x12345678u});
    assert(viewport::FindVerifiedUser32Import(test.image, symbol, target) == 0);
    test.descriptor.OriginalFirstThunk = 0;
    test.Write(TestImage::kImports, test.descriptor);
    assert(viewport::FindVerifiedUser32Import(test.image, symbol, target) == 0);
    test.Write(TestImage::kIat, static_cast<uint32_t>(target));
    assert(viewport::FindVerifiedUser32Import(test.image, symbol, target) == TestImage::kIat);
    // Duplicate live bindings are ambiguous even when names have been stripped.
    test.Write(TestImage::kIat + 4, static_cast<uint32_t>(target));
    assert(viewport::FindVerifiedUser32Import(test.image, symbol, target) == 0);
  }
  TestImage test;
  assert(viewport::FindVerifiedUser32Import(test.image, nullptr, target) == 0);
  assert(viewport::FindVerifiedUser32Import(test.image, "", target) == 0);
}

}  // namespace

int main() {
  ConfigSlotRelocation();
  ConfigSlotSectionAndUniqueness();
  DesignSizeBounds();
  NamedImportIdentity();
  ImportBoundsAndAmbiguity();
  BoundImportIdentity();
  BoundImportBoundsAndAmbiguity();
  VerifiedUser32Imports();
  return 0;
}
