#include <windows.h>

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <cstring>

#include "siglus_autoprofile.h"

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_family;

struct Layout {
  uintptr_t glyph = 0x1000u;
  uintptr_t dialogue = 0x2400u;
  uintptr_t scenario = 0x3000u;
  uintptr_t input = 0x5000u;
  uintptr_t main_call = 0x5400u;
  uintptr_t keyboard = 0x5800u;
  uintptr_t writer = 0x6000u;
  uintptr_t iat = 0x7000u;
};

struct Image {
  uint8_t* bytes = static_cast<uint8_t*>(VirtualAlloc(
      nullptr, 0x9000u, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
  exact_lookup::LoadedPeImage view;
  Layout layout;

  explicit Image(Layout positions = {}) : layout(positions) {
    assert(bytes != nullptr);
    std::memset(bytes, 0xcc, 0x9000u);
    view.base = bytes;
    // x86 absolute operands refer to a simulated preferred base, even when
    // this test itself is an x64 process with an allocation above 4 GiB.
    view.absolute_base = 0x400000u;
    view.size = 0x9000u;
    view.machine = IMAGE_FILE_MACHINE_I386;
    view.pointer_bits = 32u;
    view.section_count = 3u;
    view.sections[0] = {bytes + 0x1000u, 0x3000u, 0x1000u,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    view.sections[1] = {bytes + 0x4000u, 0x3000u, 0x4000u,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    view.sections[2] = {bytes + 0x7000u, 0x2000u, 0x7000u,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
    Put(layout.glyph, siglus_exact::kGlyphLayoutEntryPattern);
    bytes[layout.glyph + siglus_exact::kGlyphLayoutStackByteOffset] = 0xecu;
    Put(layout.glyph + 0x40u, kGlyphFastReturn.pattern());
    Put(layout.glyph + 0x100u, kGlyphFontArguments.pattern());
    Put(layout.glyph + 0x200u, kGlyphCoordinates.pattern());
    Put(layout.glyph + 0xd00u, kGlyphReturn.pattern());
    Put(layout.dialogue, kDialogueCall.pattern());
    Put(layout.scenario + 5u, kScenarioEntryTail.pattern());
    std::memcpy(bytes + layout.scenario, "\x55\x8b\xec\x6a\xff", 5u);
    Put(layout.scenario + 0x100u, kScenarioStringAbi.pattern());
    Put(layout.scenario + 0x800u, kScenarioReturn.pattern());
    Put(layout.input, siglus_exact::kSprbInputMessageEntryPattern);
    Put(layout.input + 0x41u, kInputReturn.pattern());
    Put(layout.main_call, kMainInputCall.pattern());
    Put(layout.keyboard, kKeyboardLoop.pattern());
    Put(layout.keyboard + 0x6bu, kLeftButtonConsumer.pattern());
    Put(layout.writer, kCoordinateWriter.pattern());
    Call(layout.dialogue + kDialogueCallOffset, layout.glyph);
    Call(layout.main_call + kMainInputCallOffset, layout.input);
    Call(layout.glyph + 0x200u + kCoordinateCallOffset, layout.writer);
    const uint32_t absolute_iat =
        static_cast<uint32_t>(view.absolute_base + layout.iat);
    std::memcpy(bytes + layout.keyboard + 2u, &absolute_iat, 4u);
  }
  ~Image() { VirtualFree(bytes, 0u, MEM_RELEASE); }
  Image(const Image&) = delete;
  Image& operator=(const Image&) = delete;

  void Put(uintptr_t rva, const exact_lookup::MaskedPattern& pattern) {
    assert(rva + pattern.size <= view.size);
    std::memcpy(bytes + rva, pattern.bytes, pattern.size);
  }
  void Call(uintptr_t call, uintptr_t target) {
    bytes[call] = 0xe8u;
    const int32_t displacement = static_cast<int32_t>(target - call - 5u);
    std::memcpy(bytes + call + 1u, &displacement, sizeof(displacement));
  }
  bool Resolve(SiglusLookupProfile* result) {
    return ResolveSiglusFamilyProfile(view, layout.iat, result);
  }
  void Check() {
    SiglusLookupProfile result;
    assert(Resolve(&result));
    assert(result.text_feed == SiglusLookupTextFeed::kLunaScenarioLane);
    assert(result.glyph_layout_rva == layout.glyph);
    assert(result.dialogue_glyph_return_rva ==
           layout.dialogue + kDialogueCallOffset + 5u);
    assert(result.exact_text_rva == layout.scenario);
    assert(result.exact_text_return_rva == 0u);
    assert(result.input_message_rva == layout.input);
    assert(result.main_input_message_return_rva ==
           layout.main_call + kMainInputCallOffset + 5u);
    assert(result.get_key_state_return_rva == layout.keyboard + 15u);
    assert(result.viewport_width == 0 && result.viewport_height == 0);
    assert((result.executable_sha256 == std::array<uint8_t, 32>{}));
  }
  void Reject() {
    SiglusLookupProfile result = kAnemoiSiglusLookupProfile;
    assert(!Resolve(&result));
    assert(result.glyph_layout_rva == 0u);
  }
};
}  // namespace

int main() {
  Image{}.Check();
  // Each independently located component moves by a different amount. No
  // original RVA, whole-image displacement, hash or shared delta can pass this.
  Layout moved;
  moved.glyph += 0x70u;
  moved.dialogue += 0x89u;
  moved.scenario += 0x101u;
  moved.input += 0x71u;
  moved.main_call += 0x36u;
  moved.keyboard += 0x65u;
  moved.writer += 0x129u;
  moved.iat += 0x40u;
  Image{moved}.Check();

  for (int which = 0; which != 8; ++which) {
    Image image;
    switch (which) {
      case 0: image.Put(0x6800u, siglus_exact::kGlyphLayoutEntryPattern); break;
      case 1: image.Put(0x6800u, kDialogueCall.pattern()); break;
      case 2: image.Put(0x6800u, kScenarioEntryTail.pattern()); break;
      case 3: image.Put(0x6800u, siglus_exact::kSprbInputMessageEntryPattern); break;
      case 4: image.Put(0x6800u, kMainInputCall.pattern()); break;
      case 5: image.Put(0x6800u, kKeyboardLoop.pattern()); break;
      case 6: image.Put(0x6800u, kGlyphCoordinates.pattern()); break;
      case 7: image.Put(0x6800u, kCoordinateWriter.pattern()); break;
    }
    image.Reject();
  }
  for (int which = 0; which != 3; ++which) {
    Image image;
    const uintptr_t call = which == 0 ? image.layout.dialogue + kDialogueCallOffset
        : which == 1 ? image.layout.main_call + kMainInputCallOffset
                     : image.layout.glyph + 0x200u + kCoordinateCallOffset;
    image.Call(call, 0x6900u);
    image.Reject();
  }
  {
    Image image;
    const uint32_t wrong_iat = 0x407004u;
    std::memcpy(image.bytes + image.layout.keyboard + 2u, &wrong_iat, 4u);
    image.Reject();
  }
  {
    Image image;
    image.view.sections[2].characteristics |= IMAGE_SCN_MEM_EXECUTE;
    image.Reject();
  }
  {
    Image image;
    image.view.machine = IMAGE_FILE_MACHINE_AMD64;
    image.Reject();
  }
  // ABI changes: callee stack cleanup, field offsets, scenario argument and
  // input sampling semantics must fail even if every call still links up.
  for (int which = 0; which != 7; ++which) {
    Image image;
    const uintptr_t corrupt[] = {
        image.layout.glyph + 0xd00u + 20u,
        image.layout.glyph + 0x40u + 20u,
        image.layout.glyph + 0x100u + 5u,
        image.layout.writer + 49u,
        image.layout.scenario + 5u + 45u,
        image.layout.input + 0x41u + 4u,
        image.layout.keyboard + 29u,
    };
    image.bytes[corrupt[which]] ^= 1u;
    image.Reject();
  }
  {
    Image image;
    // First five bytes may belong to an existing Luna trampoline, but an
    // internal jump (or random bytes) does not prove the original function.
    image.bytes[image.layout.scenario] = 0xe9u;
    const int32_t outside = 0x100000;
    std::memcpy(image.bytes + image.layout.scenario + 1u, &outside, 4u);
    image.Check();
    const int32_t inside = 0x100;
    std::memcpy(image.bytes + image.layout.scenario + 1u, &inside, 4u);
    image.Reject();
  }
  {
    Image image;
    image.Put(0x7800u, kKeyboardLoop.pattern());
    image.Check();  // Non-executable data cannot introduce an ambiguous anchor.
    std::memset(image.bytes + image.layout.keyboard, 0xcc,
                kKeyboardLoop.bytes.size());
    image.Reject();  // A data-only signature cannot replace executable code.
  }
  {
    Image image;
    DWORD old = 0u;
    assert(VirtualProtect(image.bytes + 0x6000u, 0x1000u, PAGE_NOACCESS, &old));
    image.Reject();
    assert(VirtualProtect(image.bytes + 0x6000u, 0x1000u, old, &old));
  }
  assert(!ResolveSiglusFamilyProfile({}, 0u, nullptr));
  return 0;
}
