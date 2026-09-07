#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <array>
#include <cstdint>
#include <cstring>

#include "siglus_native_viewport.h"

namespace {

namespace viewport = fushi_voice_hook::siglus_native_viewport;
using fushi_voice_hook::exact_lookup::LoadedPeImage;

class TestImage {
 public:
  static constexpr uint32_t kBase = 0x400000u;
  static constexpr uint32_t kSlot = 0x1200u;

  TestImage() {
    image.base = bytes.data();
    image.absolute_base = kBase;
    image.size = bytes.size();
    image.machine = IMAGE_FILE_MACHINE_I386;
    image.pointer_bits = 32u;
    image.section_count = 2u;
    image.sections[0] = {bytes.data() + 0x400u, 0xc00u, 0x400u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {bytes.data() + 0x1000u, 0x1000u, 0x1000u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
  }

  void Pattern(uint32_t rva, bool render, uint32_t slot = kSlot,
               uint32_t base = kBase) {
    const auto& pattern = render ? viewport::kRenderSizePattern
                                 : viewport::kNormalizeSizePattern;
    assert(rva <= bytes.size() && pattern.size <= bytes.size() - rva);
    std::memcpy(bytes.data() + rva, pattern.bytes, pattern.size);
    const uint32_t address = base + slot;
    std::memcpy(bytes.data() + rva + 2u, &address, sizeof(address));
  }

  std::array<uint8_t, 0x2000u> bytes{};
  LoadedPeImage image{};
};

void IndependentLocations() {
  for (const uint32_t render : {0x440u, 0x640u}) {
    for (const uint32_t normalize : {0x800u, 0xb00u}) {
      TestImage test;
      test.Pattern(render, true);
      test.Pattern(normalize, false);
      assert(viewport::ResolveNativeConfigSlot(test.image) == TestImage::kSlot);
      test.Pattern(normalize, false, TestImage::kSlot + 4u);
      assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
      // The slot itself and loaded base can move independently of code.
      test.image.absolute_base = 0x180000u;
      test.Pattern(render, true, 0x1500u, 0x180000u);
      test.Pattern(normalize, false, 0x1500u, 0x180000u);
      assert(viewport::ResolveNativeConfigSlot(test.image) == 0x1500u);
    }
  }
}

void InvalidGlobalsAndSections() {
  for (const uint32_t slot : {0x200u, 0x800u, 0x1201u, 0x2000u}) {
    TestImage test;
    test.Pattern(0x440u, true, slot);
    test.Pattern(0x800u, false, slot);
    assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  }
  constexpr std::array<uint32_t, 3u> invalid_roles = {
      IMAGE_SCN_MEM_READ, IMAGE_SCN_MEM_WRITE,
      IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE};
  for (const uint32_t role : invalid_roles) {
    TestImage test;
    test.Pattern(0x440u, true);
    test.Pattern(0x800u, false);
    test.image.sections[1].characteristics = role;
    assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  }
  TestImage test;
  test.Pattern(0x440u, true, 0u, TestImage::kBase - 4u);
  test.Pattern(0x800u, false, 0u, TestImage::kBase - 4u);
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  for (const bool render_in_data : {false, true}) {
    TestImage data;
    data.Pattern(render_in_data ? 0x1600u : 0x440u, true);
    data.Pattern(render_in_data ? 0x800u : 0x1600u, false);
    assert(viewport::ResolveNativeConfigSlot(data.image) == 0u);
  }
}

void AmbiguityAndMissingPatterns() {
  for (const bool render : {false, true}) {
    TestImage test;
    test.Pattern(0x440u, true);
    test.Pattern(0x800u, false);
    test.Pattern(0xc00u, render);
    assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
    // The same duplicate in data is not executable ambiguity.
    std::memset(test.bytes.data() + 0xc00u, 0, 0x100u);
    test.Pattern(0x1600u, render);
    assert(viewport::ResolveNativeConfigSlot(test.image) == TestImage::kSlot);
    test.image.sections[2] = {test.bytes.data() + 0x1600u, 0x100u, 0x1600u,
                             IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    test.image.section_count = 3u;
    assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  }
  for (const bool render : {false, true}) {
    TestImage test;
    test.Pattern(0x440u, render);
    assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  }
  TestImage test;
  test.Pattern(0x440u, true);
  test.Pattern(0x800u, false);
  // A different config field displacement is an ABI mismatch.
  test.bytes[0x440u + 47u] = 0x78u;
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
}

void EmptyAndArchitecture() {
  assert(viewport::ResolveNativeConfigSlot(LoadedPeImage{}) == 0u);
  TestImage test;
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  test.Pattern(0x440u, true);
  test.Pattern(0x800u, false);
  test.image.machine = IMAGE_FILE_MACHINE_AMD64;
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  test.image.machine = IMAGE_FILE_MACHINE_I386;
  test.image.pointer_bits = 64u;
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  test.image.pointer_bits = 32u;
  test.image.base = nullptr;
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  test.image.base = test.bytes.data();
  test.image.size = 0u;
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  test.image.size = test.bytes.size();
  test.image.section_count = test.image.sections.size() + 1u;
  assert(viewport::ResolveNativeConfigSlot(test.image) == 0u);
  assert(fushi_voice_hook::siglus_viewport::ValidDesignSize(1920, 1080));
  assert(fushi_voice_hook::siglus_viewport::ValidDesignSize(1280, 720));
}

}  // namespace

int main() {
  IndependentLocations();
  InvalidGlobalsAndSections();
  AmbiguityAndMissingPatterns();
  EmptyAndArchitecture();
  return 0;
}
