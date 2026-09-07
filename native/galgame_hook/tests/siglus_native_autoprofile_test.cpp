#include <windows.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include "siglus_native_autoprofile.h"

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_native_family;
struct Layout {
  uintptr_t glyph = 0x1000u, dialogue = 0x2200u, text = 0x2800u;
  uintptr_t text_caller = 0x3000u, input = 0x3800u, main_call = 0x4000u;
  uintptr_t keyboard = 0x4400u, writer = 0x5000u, assignment = 0x5400u;
  uintptr_t key_slot = 0x7000u, text_slot = 0x7100u;
};
struct Image {
  uint8_t* bytes = static_cast<uint8_t*>(VirtualAlloc(
      nullptr, 0x9000u, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
  exact_lookup::LoadedPeImage view;
  Layout p;
  static constexpr uint32_t kExport = 0x76543210u;
  explicit Image(Layout layout = {}) : p(layout) {
    assert(bytes);
    std::memset(bytes, 0xcc, 0x9000u);
    view.base = bytes; view.absolute_base = 0x110000u;
    view.size = 0x9000u; view.machine = IMAGE_FILE_MACHINE_I386;
    view.pointer_bits = 32u; view.section_count = 2u;
    view.sections[0] = {bytes + 0x1000u, 0x6000u, 0x1000u,
                       IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    view.sections[1] = {bytes + 0x7000u, 0x2000u, 0x7000u,
                       IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
    Put(p.glyph, siglus_exact::kGlyphLayoutEntryPattern);
    bytes[p.glyph + 19u] = 0xdcu;
    Put(p.glyph + 0x40u, siglus_family::kGlyphFastReturn.pattern());
    Put(p.glyph + 0x100u, kGlyphFontArguments.pattern());
    Put(p.glyph + 0x200u, kGlyphCoordinates.pattern());
    Put(p.glyph + 0x800u, kGlyphReturn.pattern());
    Put(p.dialogue, kDialogueCall.pattern());
    bytes[p.text] = 0x53u; bytes[p.text + 1u] = 0x8bu;
    bytes[p.text + 2u] = 0x1du;
    U32(p.text + 3u, static_cast<uint32_t>(view.absolute_base + p.text_slot));
    Put(p.text + 7u, kTextTail.pattern());
    Put(p.text + 0x80u, kTextCopy.pattern());
    Put(p.text + 0x200u, kTextReturn.pattern());
    Put(p.text_caller, kTextCaller.pattern());
    Put(p.input, siglus_exact::kAnemoiInputMessageEntryPattern);
    Put(p.input + 0x40u, kInputReturn.pattern());
    Put(p.main_call, kMainInputCall.pattern());
    Put(p.keyboard, kKeyboardLoop.pattern());
    Put(p.keyboard + 0x200u, kLeftButtonConsumer.pattern());
    Put(p.writer, kCoordinateWriter.pattern());
    Call(p.dialogue + kDialogueCallOffset, p.glyph);
    Call(p.glyph + 0x200u + 16u, p.writer);
    Call(p.text_caller + kTextCallOffset, p.text);
    Call(p.text + 7u + 31u, p.assignment);
    Call(p.text + 0x80u + 22u, p.assignment);
    Call(p.main_call + kMainInputCallOffset, p.input);
    U32(p.keyboard + 2u, static_cast<uint32_t>(view.absolute_base + p.key_slot));
    U32(p.key_slot, kExport);
  }
  ~Image() { VirtualFree(bytes, 0u, MEM_RELEASE); }
  Image(const Image&) = delete;
  Image& operator=(const Image&) = delete;
  void U32(uintptr_t at, uint32_t value) { std::memcpy(bytes + at, &value, 4u); }
  void Put(uintptr_t at, exact_lookup::MaskedPattern pattern) {
    assert(at + pattern.size < view.size);
    std::memcpy(bytes + at, pattern.bytes, pattern.size);
  }
  void Call(uintptr_t at, uintptr_t target) {
    bytes[at] = 0xe8u;
    U32(at + 1u, static_cast<uint32_t>(target - at - 5u));
  }
  bool Resolve(SiglusLookupProfile* result) {
    return ResolveSiglusNativeFamilyProfile(view, kExport, result);
  }
  void Check() {
    SiglusLookupProfile result;
    assert(Resolve(&result));
    assert(result.glyph_layout_rva == p.glyph);
    assert(result.dialogue_glyph_return_rva == p.dialogue + 49u);
    assert(result.exact_text_rva == p.text);
    assert(result.exact_text_return_rva == p.text_caller + 16u);
    assert(result.input_message_rva == p.input);
    assert(result.main_input_message_return_rva == p.main_call + 22u);
    assert(result.get_key_state_return_rva == p.keyboard + 17u);
    assert(result.viewport_width == 0 && result.viewport_height == 0);
    assert(result.text_feed == SiglusLookupTextFeed::kNativeEcxTextUnion);
    assert((result.executable_sha256 == std::array<uint8_t, 32>{}));
    assert(!ResolveSiglusFamilyProfile(view, p.key_slot, &result));
  }
  void Reject() {
    SiglusLookupProfile result = kAnemoiSiglusLookupProfile;
    assert(!Resolve(&result));
    assert(result.glyph_layout_rva == 0u && result.exact_text_rva == 0u);
  }
};
}
int main() {
  Image{}.Check();
  Layout moved;
  moved.glyph += 0x35u; moved.dialogue += 0x81u; moved.text += 0x127u;
  moved.text_caller += 0x42u; moved.input += 0x31u;
  moved.main_call += 0x79u; moved.keyboard += 0x13u;
  moved.writer += 0x97u; moved.assignment += 0x25u;
  moved.key_slot += 0x44u; moved.text_slot += 0x64u;
  Image{moved}.Check();
  // Uniqueness applies to every independent executable anchor.
  const exact_lookup::MaskedPattern anchors[] = {
      siglus_exact::kGlyphLayoutEntryPattern, kDialogueCall.pattern(),
      kTextTail.pattern(), kTextCaller.pattern(),
      siglus_exact::kAnemoiInputMessageEntryPattern, kMainInputCall.pattern(),
      kKeyboardLoop.pattern(), kGlyphCoordinates.pattern(), kCoordinateWriter.pattern()};
  for (auto pattern : anchors) {
    Image image; image.Put(0x6000u, pattern); image.Reject();
  }
  for (int i = 0; i != 5; ++i) {
    Image image;
    const uintptr_t calls[] = {image.p.dialogue + 44u, image.p.glyph + 0x210u,
        image.p.text_caller + 11u, image.p.main_call + 17u,
        image.p.text + 0x80u + 22u};
    image.Call(calls[i], 0x6600u); image.Reject();
  }
  // Incompatible string/object offsets, stack cleanup and key semantics.
  for (int i = 0; i != 10; ++i) {
    Image image;
    const uintptr_t corrupt[] = {image.p.glyph + 19u,
        image.p.glyph + 0x100u + 5u, image.p.glyph + 0x800u + 21u,
        image.p.writer + 50u, image.p.text + 7u + 5u,
        image.p.text + 7u + 17u, image.p.text + 0x200u + 4u,
        image.p.input + 0x40u + 5u, image.p.keyboard + 34u,
        image.p.keyboard + 0x200u + 11u};
    image.bytes[corrupt[i]] ^= 1u; image.Reject();
  }
  { Image image; image.U32(image.p.key_slot, Image::kExport + 1u); image.Reject(); }
  { Image image; image.U32(image.p.keyboard + 2u, 0x119001u); image.Reject(); }
  { Image image; image.U32(image.p.text + 3u, 0x111000u); image.Reject(); }
  { Image image; image.view.sections[1].characteristics |= IMAGE_SCN_MEM_EXECUTE; image.Reject(); }
  { Image image; image.view.machine = IMAGE_FILE_MACHINE_AMD64; image.Reject(); }
  { Image image; image.view.pointer_bits = 64u; image.Reject(); }
  { Image image; image.bytes[image.p.text] = 0xe9u; image.Reject(); }
  { Image image; image.Put(0x7800u, kKeyboardLoop.pattern()); image.Check(); }
  { Image image; image.view.sections[0].size = image.p.writer + 5u - 0x1000u; image.Reject(); }
  {
    Image image; DWORD old = 0;
    assert(VirtualProtect(image.bytes + 0x7000u, 0x1000u, PAGE_NOACCESS, &old));
    image.Reject();
    assert(VirtualProtect(image.bytes + 0x7000u, 0x1000u, old, &old));
  }
  { Image image; SiglusLookupProfile result;
    assert(!ResolveSiglusNativeFamilyProfile(image.view, 0u, &result));
    assert(!ResolveSiglusNativeFamilyProfile(image.view, Image::kExport, nullptr)); }
}
