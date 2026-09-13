#include <windows.h>

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdio>
#include <cstring>

#include "siglus_message_profile.h"

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_message;

struct Layout {
  uintptr_t message = 0x1000u;
  uintptr_t voice = 0x2000u;
  uintptr_t wrapper = 0x3000u;
  uintptr_t clear_layout = 0x4000u;
  uintptr_t clear_all = 0x5000u;
  uintptr_t prepare = 0x6000u;
  uintptr_t scenario = 0x7000u;
};

struct Image {
  uint8_t* bytes = static_cast<uint8_t*>(VirtualAlloc(
      nullptr, 0xa000u, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  exact_lookup::LoadedPeImage view;
  SiglusLookupProfile scenario;
  Layout layout;
  bool edi;

  explicit Image(bool owner_edi = false, Layout positions = {})
      : layout(positions), edi(owner_edi) {
    assert(bytes != nullptr);
    std::memset(bytes, 0xcc, 0xa000u);
    view.base = bytes;
    view.absolute_base = 0x400000u;
    view.size = 0xa000u;
    view.machine = IMAGE_FILE_MACHINE_I386;
    view.pointer_bits = 32u;
    view.section_count = 2u;
    view.sections[0] = {bytes + 0x1000u, 0x8000u, 0x1000u,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    view.sections[1] = {bytes + 0x9000u, 0x1000u, 0x9000u,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
    scenario.pe_machine = IMAGE_FILE_MACHINE_I386;
    scenario.pointer_bits = 32u;
    scenario.text_feed = SiglusLookupTextFeed::kLunaScenarioLane;
    scenario.exact_text_rva = layout.scenario;
    Put(layout.message, edi ? kMessageEdi.pattern() : kMessageEsi.pattern());
    Branch(layout.message + kMessageEsi.bytes.size(), layout.message + 0x400u);
    Put(layout.message + 0x100u,
        edi ? kSurfaceEdi.pattern() : kSurfaceEsi.pattern());
    Put(layout.message + 0x400u, kMessageCleanup.pattern());
    Put(layout.voice, kVoiceEntry.pattern());
    Branch(layout.voice + kVoiceEntry.bytes.size(), layout.voice + 0x200u);
    Put(layout.voice + 0x100u, kVoiceWrite.pattern());
    Put(layout.voice + 0x200u, kVoiceReturn.pattern());
    Put(layout.wrapper, kWrapper.pattern());
    Put(layout.clear_layout, kClearLayout.pattern());
    Put(layout.clear_all, kClearAll.pattern());
    Put(layout.prepare, kPrepare.pattern());
    std::memcpy(bytes + layout.scenario, "\x55\x8b\xec\x6a\xff", 5u);
    Put(layout.scenario + 5u, siglus_family::kScenarioEntryTail.pattern());
    Put(layout.scenario + 0x100u, siglus_family::kScenarioStringAbi.pattern());
    Put(layout.scenario + 0x800u, siglus_family::kScenarioReturn.pattern());
    Call(layout.message + 0x100u + kSurfaceCallOffset, layout.wrapper);
    Call(layout.wrapper + kWrapperCallOffset, layout.scenario);
    Call(layout.prepare + kPrepareClearLayoutOffset, layout.clear_layout);
    Call(layout.prepare + kPrepareSecondClearLayoutOffset, layout.clear_layout);
    Call(layout.prepare + kPrepareClearAllOffset, layout.clear_all);
  }
  ~Image() { VirtualFree(bytes, 0, MEM_RELEASE); }
  Image(const Image&) = delete;
  Image& operator=(const Image&) = delete;
  void Put(uintptr_t rva, const exact_lookup::MaskedPattern& pattern) {
    assert(rva + pattern.size <= view.size);
    std::memcpy(bytes + rva, pattern.bytes, pattern.size);
  }
  void Call(uintptr_t rva, uintptr_t target) {
    bytes[rva] = 0xe8u;
    const int32_t displacement = static_cast<int32_t>(target - rva - 5u);
    std::memcpy(bytes + rva + 1u, &displacement, 4u);
  }
  void Branch(uintptr_t rva, uintptr_t target) {
    bytes[rva] = 0x0fu;
    bytes[rva + 1u] = 0x84u;
    const int32_t displacement = static_cast<int32_t>(target - rva - 6u);
    std::memcpy(bytes + rva + 2u, &displacement, 4u);
  }
  void Check() {
    SiglusMessageProfile out;
    assert(ResolveSiglusMessageProfile(view, scenario, &out));
    assert(out.message_entry_rva == layout.message);
    assert(out.message_surface_return_rva ==
           layout.message + 0x100u + kSurfaceCallOffset + 5u);
    assert(out.surface_wrapper_rva == layout.wrapper);
    assert(out.scenario_return_rva == layout.wrapper + kWrapperCallOffset + 5u);
    assert(out.voice_entry_rva == layout.voice);
    assert(out.prepare_entry_rva == layout.prepare);
    assert(out.clear_layout_rva == layout.clear_layout);
    assert(out.clear_all_rva == layout.clear_all);
    assert(out.owner_register == (edi ? SiglusMessageOwnerRegister::kEdi
                                     : SiglusMessageOwnerRegister::kEsi));
    assert(out.owner_voice_key_offset == 0x1f8u);
    assert(out.owner_surface_index_offset == 0x1e0u);
    assert(out.owner_surface_begin_offset == 0x228u);
    assert(out.owner_surface_end_offset == 0x22cu);
    assert(out.surface_stride == 0x1c0u);
    assert(!out.voice_key_resource_mapping_proved);
  }
  void Reject() {
    SiglusMessageProfile out;
    out.message_entry_rva = 1u;
    out.owner_register = SiglusMessageOwnerRegister::kEsi;
    assert(!ResolveSiglusMessageProfile(view, scenario, &out));
    assert(out.message_entry_rva == 0u && out.voice_entry_rva == 0u);
    assert(out.surface_stride == 0u);
    assert(out.owner_register == SiglusMessageOwnerRegister::kNone);
  }
};
}  // namespace

int main() {
  Image{}.Check();
  Image{true}.Check();
  Layout moved;
  moved.message += 0x73u;
  moved.voice += 0x114u;
  moved.wrapper += 0x217u;
  moved.clear_layout += 0x38u;
  moved.clear_all += 0x45u;
  moved.prepare += 0x96u;
  moved.scenario += 0x83u;
  Image{false, moved}.Check();
  Image{true, moved}.Check();

  // No count/scan-order fallback for another complete or partial ABI.
  for (int which = 0; which != 10; ++which) {
    Image image;
    switch (which) {
      case 0: image.Put(0x8000u, kMessageEsi.pattern()); break;
      case 1: image.Put(0x8000u, kMessageEdi.pattern()); break;
      case 2: image.Put(0x8000u, kSurfaceEsi.pattern()); break;
      case 3: image.Put(0x8000u, kSurfaceEdi.pattern()); break;
      case 4: image.Put(0x8000u, kWrapper.pattern()); break;
      case 5: image.Put(0x8000u, kVoiceEntry.pattern()); break;
      case 6: image.Put(0x8000u, kVoiceWrite.pattern()); break;
      case 7: image.Put(0x8000u, kClearLayout.pattern()); break;
      case 8: image.Put(0x8000u, kClearAll.pattern()); break;
      case 9: image.Put(0x8000u, kPrepare.pattern()); break;
    }
    image.Reject();
  }
  for (int which = 0; which != 5; ++which) {
    Image image;
    const uintptr_t call = which == 0
        ? image.layout.message + 0x100u + kSurfaceCallOffset
        : which == 1 ? image.layout.wrapper + kWrapperCallOffset
        : which == 2 ? image.layout.prepare + kPrepareClearLayoutOffset
        : which == 3 ? image.layout.prepare + kPrepareSecondClearLayoutOffset
                     : image.layout.prepare + kPrepareClearAllOffset;
    image.Call(call, 0x8800u);
    image.Reject();
  }
  // Exact data/stack contracts, not just a call-shaped byte sequence.
  for (int which = 0; which != 10; ++which) {
    Image image;
    const uintptr_t byte = which == 0 ? image.layout.message + 1u
        : which == 1 ? image.layout.wrapper + 1u
        : which == 2 ? image.layout.wrapper + kWrapper.bytes.size() - 2u
        : which == 3 ? image.layout.message + 0x400u + kMessageCleanup.bytes.size() - 1u
        : which == 4 ? image.layout.message + 0x100u + 53u
        : which == 5 ? image.layout.message + 0x100u + 2u
        : which == 6 ? image.layout.voice + 0x100u + 28u
        : which == 7 ? image.layout.clear_layout + 26u
        : which == 8 ? image.layout.scenario + 0x100u + 3u
                     : image.layout.prepare + 5u;
    image.bytes[byte] ^= 1u;
    image.Reject();
  }
  {
    Image image;
    image.Call(image.layout.message + 0x200u, image.layout.wrapper);
    image.Reject();
  }
  {
    Image image;
    image.Put(image.layout.message + 0x100u, kSurfaceEdi.pattern());
    image.Reject();
  }
  {
    Image image;
    image.Branch(image.layout.message + kMessageEsi.bytes.size(), 0x8000u);
    image.Reject();
    image.Branch(image.layout.message + kMessageEsi.bytes.size(), 0x1000u);
    image.Reject();
  }
  {
    Image image;
    image.Put(0x8500u, kSurfaceEsi.pattern());
    std::memset(image.bytes + image.layout.message + 0x100u, 0xcc,
                kSurfaceEsi.bytes.size());
    image.Reject();
  }
  {
    Image image;
    image.scenario.text_feed = SiglusLookupTextFeed::kNativeEcxTextUnion;
    image.Reject();
  }
  {
    Image image;
    ++image.scenario.exact_text_rva;
    image.Reject();
  }
  {
    Image image;
    image.view.machine = IMAGE_FILE_MACHINE_AMD64;
    image.view.pointer_bits = 64u;
    image.Reject();
  }
  {
    Image image;
    image.view.sections[0].characteristics = IMAGE_SCN_MEM_READ;
    image.Reject();
  }
  {
    Image image;
    image.Put(0x9000u, kMessageEdi.pattern());  // Non-executable decoy.
    image.Check();
    image.view.size = 0x2000u;
    image.view.sections[0].size = 0x1000u;
    image.Reject();
  }
  {
    Image image;
    DWORD old = 0;
    assert(VirtualProtect(image.bytes + 0x2000u, 0x1000u, PAGE_NOACCESS, &old));
    image.Reject();
    assert(VirtualProtect(image.bytes + 0x2000u, 0x1000u, old, &old));
  }
  std::puts("Siglus message profile: relocated variants and negative contracts passed");
}
