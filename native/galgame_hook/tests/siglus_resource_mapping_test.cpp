#include <windows.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "siglus_resource_mapping.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <utility>
#include <vector>

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_resource;
struct Image {
  uint8_t *bytes = static_cast<uint8_t *>(VirtualAlloc(
      nullptr, 0x20000u, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  exact_lookup::LoadedPeImage view;
  uintptr_t voice, play, resource, builder, concat, formatter, crt;
  uintptr_t assign, archive_open, archive_read, ogg_ctor, ogg_open, ogg_read;
  std::vector<std::pair<uintptr_t, uintptr_t>> edges;
  std::vector<uintptr_t> strings;
  explicit Image(uintptr_t shift = 0u) {
    assert(bytes);
    std::memset(bytes, 0xcc, 0x20000u);
    view.base = bytes;
    view.size = 0x20000u;
    view.absolute_base = 0x13000000u;
    view.machine = IMAGE_FILE_MACHINE_I386;
    view.pointer_bits = 32u;
    view.section_count = 3u;
    view.sections[0] = {bytes + 0x1000u, 0x1b000u, 0x1000u,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    view.sections[1] = {bytes + 0x1c000u, 0x2000u, 0x1c000u,
                        IMAGE_SCN_MEM_READ};
    view.sections[2] = {bytes + 0x1e000u, 0x2000u, 0x1e000u,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
    // Components move independently; no module-relative fixed-address gate.
    voice = 0x1000u + shift;
    play = 0x2000u + 2u * shift;
    resource = 0x4000u + 3u * shift;
    builder = 0x7000u + 4u * shift;
    concat = 0xa000u + 5u * shift;
    formatter = 0xc000u + 6u * shift;
    crt = 0xe000u + 7u * shift;
    assign = 0x3000u + shift;
    archive_open = 0x6000u + shift;
    archive_read = 0x9000u + shift;
    ogg_ctor = 0xb000u + shift;
    ogg_open = 0xd000u + shift;
    ogg_read = 0xf000u + shift;
    Put(voice, kVoiceRequest.pattern());
    Put(play, kPlay.pattern());
    Put(resource, kResource.pattern());
    Put(builder, kBuilder.pattern());
    Put(concat, kConcat.pattern());
    Put(formatter, kFormatter.pattern());
    Put(crt, kCrtFormat.pattern());
    Put(assign, kWideAssign.pattern());
    Put(archive_open, kArchiveOpen.pattern());
    Put(archive_read, kArchiveRead.pattern());
    Put(ogg_ctor, kOggCtor.pattern());
    Put(ogg_open, kOggOpen.pattern());
    Put(ogg_read, kOggRead.pattern());
    edges = {{voice + 0xa1u, play},
             {play + 0x4bu, resource},
             {resource + 0x112u, builder},
             {builder + 0x2a2u, concat},
             {builder + 0x3c4u, concat},
             {builder + 0x4e0u, concat},
             {builder + 0x22bu, formatter},
             {builder + 0x34du, formatter},
             {builder + 0x469u, formatter},
             {formatter + 0x5cu, crt + 0x77u},
             {crt + 0x88u, crt},
             {resource + 0xeeu, assign},
             {builder + 0x222u, assign},
             {builder + 0x27bu, assign},
             {builder + 0x344u, assign},
             {builder + 0x39du, assign},
             {builder + 0x460u, assign},
             {builder + 0x4b9u, assign},
             {resource + 0x579u, archive_open},
             {resource + 0x626u, archive_read},
             {resource + 0x66eu, archive_read},
             {resource + 0x789u, ogg_ctor}};
    for (const auto &e : edges)
      Call(e.first, e.second);
    String(resource + 0xd9u, L"koe");
    String(builder + 0x21bu, L"%04d\\z%09d");
    String(builder + 0x33du, L"%04d\\z%09d");
    String(builder + 0x269u, L"wav");
    String(builder + 0x38bu, L"nwa");
    String(builder + 0x459u, L"z%04d");
    String(builder + 0x4a7u, L"ovk");
    String(concat + 0x47u, L"\\");
    String(concat + 0x7cu, L"\\");
    String(concat + 0xa7u, L"\\");
    String(concat + 0xcfu, L".");
    String(ogg_open + 0x26u, L"rb");
    Absolute(ogg_ctor + 0x52u, 0x1cf00u);
    Absolute(0x1cf04u, ogg_open);
    Absolute(ogg_open + 0x70u, ogg_read);
  }
  ~Image() { VirtualFree(bytes, 0, MEM_RELEASE); }
  Image(const Image &) = delete;
  Image &operator=(const Image &) = delete;
  void Put(uintptr_t rva, const exact_lookup::MaskedPattern &p) {
    std::memcpy(bytes + rva, p.bytes, p.size);
  }
  void Call(uintptr_t at, uintptr_t target) {
    assert(bytes[at] == 0xe8u);
    const int32_t rel = static_cast<int32_t>(target - at - 5u);
    std::memcpy(bytes + at + 1u, &rel, 4u);
  }
  void Absolute(uintptr_t at, uintptr_t rva) {
    const uint32_t va = static_cast<uint32_t>(view.absolute_base + rva);
    std::memcpy(bytes + at, &va, 4u);
  }
  template <size_t N> void String(uintptr_t at, const wchar_t (&s)[N]) {
    const uintptr_t rva = 0x1c000u + strings.size() * 0x80u;
    std::memcpy(bytes + rva, s, sizeof(s));
    Absolute(at, rva);
    strings.push_back(at);
  }
  void Check() {
    SiglusResourceMappingProfile out;
    assert(ResolveSiglusResourceMappingProfile(view, voice, &out));
    assert(out.voice_entry_rva == voice && out.resource_entry_rva == resource);
    assert(out.archive_builder_rva == builder);
    assert(out.ovk_path_return_rva == builder + 0x4e5u);
    assert(out.archive_open_rva == archive_open);
    assert(out.archive_open_return_rva == resource + 0x57eu);
    assert(out.archive_read_rva == archive_read);
    assert(out.archive_header_return_rva == resource + 0x62bu);
    assert(out.archive_table_return_rva == resource + 0x673u);
    assert(out.ogg_open_rva == ogg_open && out.ogg_read_rva == ogg_read);
    assert(out.payload_return_rva == resource + 0x7b6u);
    assert(out.ogg_vtable_rva == 0x1cf00u);
    assert(out.kVoiceKeyRadix == 100000u && out.kOvkResourceKind == 3u);
  }
  void Reject() {
    SiglusResourceMappingProfile out;
    out.voice_entry_rva = 1u;
    out.resource_entry_rva = 1u;
    out.archive_builder_rva = 1u;
    assert(!ResolveSiglusResourceMappingProfile(view, voice, &out));
    assert(out.voice_entry_rva == 0u && out.resource_entry_rva == 0u &&
           out.archive_builder_rva == 0u && out.ovk_path_return_rva == 0u);
  }
};
} // namespace
int main() {
  Image{}.Check();
  Image{0x31u}.Check();
  // A rel32 into some other executable code is not evidence of this chain.
  for (size_t i = 0; i < 22u; ++i) {
    Image x;
    x.Call(x.edges[i].first, 0x18000u);
    x.Reject();
  }
  // Image literals include their terminator; aliases and loose formats fail.
  for (size_t i = 0; i < 12u; ++i) {
    Image x;
    x.bytes[0x1c000u + i * 0x80u] ^= 1u;
    x.Reject();
  }
  {
    Image x;
    std::memcpy(x.bytes + 0x1c000u + 6u * 0x80u, L"wav", 8u);
    x.Reject();
  }
  {
    Image x;
    std::memcpy(x.bytes + 0x1c000u + 6u * 0x80u, L"nwa", 8u);
    x.Reject();
  }
  {
    Image x;
    x.bytes[0x1c000u + 5u * 0x80u + 10u] = L'x';
    x.Reject();
  }
  // Mutate the actual key/argument/arithmetic/kind/member-layout contract.
  for (int which = 0; which < 15; ++which) {
    Image x;
    uintptr_t at = 0;
    switch (which) {
    case 0:
      at = x.voice + 10u;
      break; // EDX key save
    case 1:
      at = x.play + 0x1cu;
      break; // first argument
    case 2:
      at = x.resource + 0x5fu;
      break; // signed /100000 magic
    case 3:
      at = x.resource + 0x91u;
      break; // multiply divisor 100000
    case 4:
      at = x.resource + 0x9fu;
      break; // saved remainder offset
    case 5:
      at = x.resource + 0x106u;
      break; // original key passed to builder
    case 6:
      at = x.resource + 0x20du;
      break; // returned resource kind
    case 7:
      at = x.resource + 0x52au;
      break; // OVK kind=3 branch
    case 8:
      at = x.resource + 0x691u;
      break; // member [row+8]
    case 9:
      at = x.resource + 0x69cu;
      break; // member stride 0x10
    case 10:
      at = x.builder + 0x85u;
      break; // builder /100000 magic
    case 11:
      at = x.builder + 0x438u;
      break; // formatted quotient stack local
    case 12:
      at = x.builder + 0x43fu;
      break; // OVK kind=3
    case 13:
      at = x.formatter + 0x42u;
      break; // actual varargs start
    case 14:
      at = x.concat + 0x41u;
      break; // basename argument
    }
    x.bytes[at] ^= 1u;
    x.Reject();
  }
  const exact_lookup::MaskedPattern candidates[] = {
      kVoiceRequest.pattern(), kPlay.pattern(),       kResource.pattern(),
      kBuilder.pattern(),      kConcat.pattern(),     kFormatter.pattern(),
      kCrtFormat.pattern(),    kWideAssign.pattern(), kArchiveOpen.pattern(),
      kArchiveRead.pattern(),  kOggCtor.pattern(),    kOggOpen.pattern(),
      kOggRead.pattern()};
  for (const auto &candidate : candidates) {
    Image x;
    x.Put(0x15000u, candidate);
    x.Reject();
  }
  {
    Image x;
    x.Put(0x1e000u, kBuilder.pattern());
    x.Check();
  }
  {
    Image x;
    x.view.machine = IMAGE_FILE_MACHINE_AMD64;
    x.Reject();
  }
  {
    Image x;
    x.view.pointer_bits = 64u;
    x.Reject();
  }
  {
    Image x;
    x.voice += 1u;
    x.Reject();
  }
  {
    Image x;
    x.view.sections[1].characteristics |= IMAGE_SCN_MEM_WRITE;
    x.Check();
  }
  {
    Image x;
    x.view.sections[1].characteristics |= IMAGE_SCN_MEM_EXECUTE;
    x.Reject();
  }
  {
    Image x;
    x.Absolute(x.strings[5], 0x1fffcu);
    x.Reject();
  }
  {
    Image x;
    x.Absolute(x.strings[5], 0x30000u);
    x.Reject();
  }
  {
    Image x;
    x.Absolute(0x1cf04u, x.ogg_read);
    x.Reject();
  }
  {
    Image x;
    x.Absolute(x.ogg_open + 0x70u, x.archive_read);
    x.Reject();
  }
  {
    Image x;
    x.Absolute(x.ogg_ctor + 0x52u, 0x1ffffu);
    x.Reject();
  }
  {
    Image x;
    x.bytes[x.resource + 0x7b5u] ^= 1u;
    x.Reject();
  } // payload vtable slot
  {
    Image x;
    x.bytes[x.ogg_open + 0x14au] ^= 1u;
    x.Reject();
  } // ret 12
  {
    Image x;
    uint32_t zero = 0;
    std::memcpy(x.bytes + x.strings[5], &zero, 4u);
    x.Reject();
  }
  {
    Image x;
    x.view.sections[0].characteristics = IMAGE_SCN_MEM_READ;
    x.Reject();
  }
  {
    Image x;
    DWORD old = 0;
    assert(VirtualProtect(x.bytes + 0x1c000u, 0x1000u, PAGE_NOACCESS, &old));
    x.Reject();
  }
  {
    Image x;
    DWORD old = 0;
    assert(VirtualProtect(x.bytes + 0x7000u, 0x1000u, PAGE_NOACCESS, &old));
    x.Reject();
  }
  std::puts("siglus_resource_mapping_test: passed");
}
