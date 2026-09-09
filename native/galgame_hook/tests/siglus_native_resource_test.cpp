#include <windows.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "siglus_native_resource.h"
#include <cassert>
#include <cstdio>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {
using namespace fushi_voice_hook;
using namespace fushi_voice_hook::siglus_native_resource;
int checks = 0;
void Check(bool value) {
  ++checks;
  assert(value);
}
struct Image {
  uint8_t *bytes = static_cast<uint8_t *>(
      VirtualAlloc(nullptr, 0x30000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  exact_lookup::LoadedPeImage view;
  uintptr_t voice, play, resource, builder, concat, formatter, crt, assign,
      ctor, ogg, read;
  uintptr_t archive, archive_read, copy;
  std::vector<std::pair<uintptr_t, exact_lookup::MaskedPattern>> anchors;
  std::vector<std::pair<uintptr_t, uintptr_t>> edges;
  std::vector<uintptr_t> literals;
  const bool compact;
  explicit Image(uintptr_t shift = 0, bool stack118 = false)
      : compact(stack118) {
    Check(bytes != nullptr);
    std::memset(bytes, 0xcc, 0x30000);
    view.base = bytes;
    view.size = 0x30000;
    view.absolute_base = 0x13000000;
    view.machine = IMAGE_FILE_MACHINE_I386;
    view.pointer_bits = 32;
    view.section_count = 2;
    view.sections[0] = {bytes + 0x1000, 0x28000, 0x1000,
                        IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    view.sections[1] = {bytes + 0x29000, 0x7000, 0x29000, IMAGE_SCN_MEM_READ};
    voice = 0x1000 + shift;
    play = 0x2000 + 2 * shift;
    resource = 0x4000 + 3 * shift;
    builder = 0x7000 + 4 * shift;
    concat = 0xa000 + 5 * shift;
    formatter = 0xc000 + 6 * shift;
    crt = 0xe000 + 7 * shift;
    assign = 0x10000 + 8 * shift;
    ctor = 0x12000 + 9 * shift;
    ogg = 0x14000 + 10 * shift;
    read = 0x16000 + 11 * shift;
    archive = 0x18000 + 12 * shift;
    archive_read = 0x1a000 + 13 * shift;
    copy = 0x1c000 + 14 * shift;
    anchors = {{voice, kVoice.pattern()},
               {play, kPlay.pattern()},
               {resource, kResource.pattern()},
               {builder, kBuilder.pattern()},
               {concat, kConcat.pattern()},
               {formatter, kFormatter.pattern()},
               {crt, kCrtFormat.pattern()},
               {assign, kAssign.pattern()},
               {ctor, kOggCtor.pattern()},
               {ogg, kOggOpen.pattern()},
               {read, kOggRead.pattern()},
               {archive, kArchiveOpen.pattern()},
               {archive_read, kArchiveRead.pattern()},
               {copy, kCopyUnion.pattern()},
               {resource + 0x2a3, kKind1.pattern()},
               {resource + 0x3e8, kKind2.pattern()},
               {resource + 0x52c, kArchive.pattern()},
               {resource + 0x5fc, kRows.pattern()},
               {resource + 0x73d, kMember.pattern()},
               {builder + 0x961, kOvkBuild.pattern()},
               {builder + 0xd7a, kBuilderResult.pattern()}};
    if (compact) {
      anchors[2].second = kResource118.pattern();
      anchors[3].second = kBuilder118.pattern();
      anchors[7].second = kAssign118.pattern();
      anchors[13].second = kCopyUnion118.pattern();
      anchors[14] = {resource + 0x2a0, kKind1118.pattern()};
      anchors[15] = {resource + 0x3d9, kKind2118.pattern()};
      anchors[16] = {resource + 0x511, kArchive118.pattern()};
      anchors[17] = {resource + 0x5e1, kRows118.pattern()};
      anchors[18] = {resource + 0x719, kMember118.pattern()};
      anchors[19] = {builder + 0x8a5, kOvkBuild118.pattern()};
      anchors[20] = {builder + 0xc0c, kBuilderResult118.pattern()};
    }
    for (const auto &a : anchors)
      Put(a.first, a.second);
    edges = {{voice + 0xae, play},
             {play + 0x55, resource},
             {resource + 0x100, builder},
             {resource + 0xdf, assign},
             {builder + 0x997, assign},
             {builder + 0xb05, assign},
             {builder + 0x9a3, formatter},
             {builder + 0xb2c, concat},
             {formatter + 0x6e, crt},
             {formatter + 0xac, assign},
             {resource + 0x567, archive},
             {resource + 0x628, archive_read},
             {resource + 0x679, archive_read},
             {resource + 0x687, archive_read},
             {resource + 0x797, ctor},
             {resource + 0xb4, copy},
             {builder + 0xd96, copy}};
    if (compact) {
      edges = {{voice + 0xae, play},
               {play + 0x55, resource},
               {resource + 0x103, builder},
               {resource + 0xe2, assign},
               {resource + 0xb7, copy},
               {builder + 0xc68, copy},
               {builder + 0x8d8, assign},
               {builder + 0xa0c, assign},
               {builder + 0x8e1, formatter},
               {builder + 0xa33, concat},
               {formatter + 0x6e, crt},
               {formatter + 0xac, assign},
               {resource + 0x54c, archive},
               {resource + 0x60a, archive_read},
               {resource + 0x65c, archive_read},
               {resource + 0x771, ctor}};
    }
    for (const auto &e : edges)
      Call(e.first, e.second);
    Literal(resource + (compact ? 0xd3 : 0xd0), L"koe");
    Literal(builder + (compact ? 0x8c6 : 0x985), L"z%04d");
    Literal(builder + (compact ? 0x9fa : 0xaf3), L"ovk");
    Literal(concat + 0x55, L"\\");
    Literal(concat + 0x80, L"\\");
    Literal(concat + 0xab, L"\\");
    Literal(concat + 0xd3, L".");
    Literal(resource + (compact ? 0x52a : 0x545), L"rb");
    Literal(ogg + 0x26, L"rb");
    Absolute(ctor + 0x52, 0x2b000);
    Absolute(0x2b004, ogg);
    Absolute(ogg + 0x70, read);
  }
  ~Image() { VirtualFree(bytes, 0, MEM_RELEASE); }
  Image(const Image &) = delete;
  Image &operator=(const Image &) = delete;
  void Put(uintptr_t at, const exact_lookup::MaskedPattern &pattern) {
    std::memcpy(bytes + at, pattern.bytes, pattern.size);
  }
  void Call(uintptr_t at, uintptr_t target) {
    assert(bytes[at] == 0xe8);
    const int32_t relative = static_cast<int32_t>(target - at - 5);
    std::memcpy(bytes + at + 1, &relative, 4);
  }
  void Absolute(uintptr_t at, uintptr_t target) {
    const uint32_t absolute =
        static_cast<uint32_t>(view.absolute_base + target);
    std::memcpy(bytes + at, &absolute, 4);
  }
  template <size_t N> void Literal(uintptr_t operand, const wchar_t (&s)[N]) {
    const uintptr_t target = 0x29000 + literals.size() * 0x80;
    Absolute(operand, target);
    std::memcpy(bytes + target, s, sizeof(s));
    literals.push_back(operand);
  }
  bool Resolve(SiglusNativeResourceMappingProfile *out) {
    return ResolveSiglusNativeResourceMappingProfile(view, voice, out);
  }
  void Accept() {
    SiglusNativeResourceMappingProfile out;
    Check(Resolve(&out));
    Check(out.voice_entry_rva == voice && out.resource_entry_rva == resource &&
          out.archive_builder_rva == builder && out.ogg_open_rva == ogg &&
          out.ogg_vtable_rva == 0x2b000 &&
          out.payload_return_rva == resource + (compact ? 0x7a7 : 0x7d0) &&
          out.frame == (compact ? SiglusNativeResourceFrame::kStack118
                                : SiglusNativeResourceFrame::kStack120));
  }
  void Reject() {
    SiglusNativeResourceMappingProfile out;
    out.ogg_open_rva = 99;
    Check(!Resolve(&out));
    Check(out.ogg_open_rva == 0);
  }
};

void TestResolver(bool compact) {
  Image first(0, compact);
  first.Accept();
  Image shifted(0x31, compact);
  shifted.Accept();
  for (const auto &e : first.edges) {
    Image bad(0, compact);
    bad.Call(e.first, e.second + 1);
    bad.Reject();
  }
  for (const auto &a : first.anchors) {
    Image bad(0, compact);
    bad.bytes[a.first] ^= 1;
    bad.Reject();
  }
  for (size_t i = 0; i < 14; ++i) {
    if (i == 6)
      continue; // CRT forwarding thunks may be duplicated by the linker.
    Image duplicate(0, compact);
    duplicate.Put(0x23000, first.anchors[i].second);
    duplicate.Reject();
  }
  {
    Image duplicate(0, compact);
    duplicate.Put(0x23000, kCrtFormat.pattern());
    duplicate.Accept();
  }
  for (size_t i = 0; i < first.literals.size(); ++i) {
    Image bad(0, compact);
    bad.bytes[0x29000 + i * 0x80] ^= 1;
    bad.Reject();
  }
  // Keep anchors present while changing arithmetic, archive kind/stride,
  // selected row field, payload argument order, indirect slot or cleanup.
  const std::vector<uintptr_t> mutations =
      compact
          ? std::vector<uintptr_t>{first.resource + 0x27,  // stack allocation
                                   first.resource + 0x51,  // frozen key local
                                   first.resource + 0x7d,  // radix multiplier
                                   first.resource + 0x9d,  // quotient shift
                                   first.resource + 0xac,  // remainder local
                                   first.resource + 0x2a7, // kind 1
                                   first.resource + 0x3db, // kind 2
                                   first.resource + 0x513, // kind 3
                                   first.resource +
                                       0x657, // 16-byte index count
                                   first.resource + 0x683, // member ID field
                                   first.resource +
                                       0x729, // selected offset sentinel
                                   first.resource +
                                       0x733, // selected length local
                                   first.resource +
                                       0x791, // payload length argument
                                   first.resource +
                                       0x79e, // payload vtable slot
                                   first.resource +
                                       0x7a5, // payload indirect call opcode
                                   first.builder + 0x47,  // root local
                                   first.builder + 0xad,  // radix shift
                                   first.builder + 0x8b4, // kind output
                                   first.builder + 0xc5c, // type copy source
                                   first.ogg + 0x13f}     // ret 12
          : std::vector<uintptr_t>{
                first.resource + 0x7d,  first.resource + 0x97,
                first.resource + 0x2aa, first.resource + 0x3ea,
                first.resource + 0x52e, first.resource + 0x6a5,
                first.resource + 0x6b5, first.resource + 0x73f,
                first.resource + 0x744, first.resource + 0x7c6,
                first.resource + 0x7cd, first.builder + 0xaa,
                first.builder + 0x971,  first.ogg + 0x13f};
  for (auto at : mutations) {
    Image bad(0, compact);
    bad.bytes[at] ^= 1;
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.Absolute(0x2b004, bad.ogg + 1);
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.Absolute(bad.ogg + 0x70, bad.read + 1);
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.Absolute(bad.ctor + 0x52, 0x2000);
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.view.machine = IMAGE_FILE_MACHINE_AMD64;
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.view.pointer_bits = 64;
    bad.Reject();
  }
  {
    Image bad(0, compact);
    ++bad.voice;
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.bytes[bad.ogg] = 0xe9;
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.view.sections[0].characteristics = IMAGE_SCN_MEM_READ;
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.view.sections[1].characteristics |= IMAGE_SCN_MEM_EXECUTE;
    bad.Reject();
  }
  {
    Image bad(0, compact);
    bad.view.sections[0].size = bad.resource + 0x7d0 - 0x1000;
    bad.Reject();
  }
  // A complete older source ABI cannot be combined with the Native one.
  {
    Image bad(0, compact);
    bad.Put(bad.resource, siglus_resource::kResource.pattern());
    bad.Reject();
  }
  Check(!ResolveSiglusNativeResourceMappingProfile(first.view, first.voice,
                                                   nullptr));
}

void TestFamilies() {
  for (bool compact : {false, true}) {
    Image other(0, !compact);
    // One valid family plus any alternative entry is ambiguous, even if the
    // alternate caller/body has not been supplied. Duplicate alternatives also
    // cannot be mistaken for "no alternate match".
    for (size_t anchor : {2u, 3u, 7u, 13u}) {
      Image bad(0, compact);
      bad.Put(0x23000, other.anchors[anchor].second);
      bad.Reject();
      bad.Put(0x25000, other.anchors[anchor].second);
      bad.Reject();
    }
    // Keep independently unique entries, but replace one with the other
    // compiler family. No Resource/Builder/string-helper mix may be admitted.
    for (size_t anchor : {2u, 3u, 7u, 13u}) {
      Image bad(0, compact);
      const auto at = bad.anchors[anchor].first;
      std::memset(bad.bytes + at, 0xcc,
                  (std::max)(bad.anchors[anchor].second.size,
                             other.anchors[anchor].second.size));
      bad.Put(at, other.anchors[anchor].second);
      bad.Reject();
    }
    // Valid resource entry with the other compiler's member dispatch, builder
    // body or result still rejects; a short shared prefix is not a proof.
    for (size_t anchor = 14; anchor < other.anchors.size(); ++anchor) {
      Image bad(0, compact);
      const auto at = bad.anchors[anchor].first;
      std::memset(bad.bytes + at, 0xcc, bad.anchors[anchor].second.size);
      bad.Put(at, other.anchors[anchor].second);
      bad.Reject();
    }
    // Copy a second internally connected Resource+Builder family, relocating
    // every edge to the shared proved helpers and its own string helpers.
    Image both(0, compact);
    auto relocate = [&](uintptr_t at) -> uintptr_t {
      if (at >= other.resource && at < other.resource + 0x1000)
        return 0x20000 + at - other.resource;
      if (at >= other.builder && at < other.builder + 0x1000)
        return 0x22000 + at - other.builder;
      if (at >= other.assign && at < other.assign + 0x1000)
        return 0x24000 + at - other.assign;
      if (at >= other.copy && at < other.copy + 0x1000)
        return 0x25000 + at - other.copy;
      return at;
    };
    for (size_t a : {2u, 3u, 7u, 13u, 14u, 15u, 16u, 17u, 18u, 19u, 20u}) {
      const auto &anchor = other.anchors[a];
      std::memcpy(both.bytes + relocate(anchor.first),
                  other.bytes + anchor.first, anchor.second.size);
    }
    for (const auto &edge : other.edges)
      if (relocate(edge.first) != edge.first)
        both.Call(relocate(edge.first), relocate(edge.second));
    both.Reject();
  }
}

struct Memory {
  std::map<uint32_t, uint8_t> bytes;
  bool operator()(uint32_t address, void *out, size_t length) {
    for (size_t i = 0; i < length; ++i) {
      auto it = bytes.find(address + static_cast<uint32_t>(i));
      if (it == bytes.end())
        return false;
      static_cast<uint8_t *>(out)[i] = it->second;
    }
    return true;
  }
  void Put(uint32_t address, const void *value, size_t length) {
    for (size_t i = 0; i < length; ++i)
      bytes[address + static_cast<uint32_t>(i)] =
          static_cast<const uint8_t *>(value)[i];
  }
  void Word(uint32_t address, uint32_t value) { Put(address, &value, 4); }
};
struct Fixture {
  Memory memory;
  SiglusNativeVoiceSourceCall call{0x5000, 0x2000, 0x3000, 0x3008};
  SiglusNativeVoiceSourceLayout layout{0x8000, 0x9000};
  explicit Fixture(bool compact = false) {
    layout.frame = compact ? SiglusNativeResourceFrame::kStack118
                           : SiglusNativeResourceFrame::kStack120;
    memory.Word(0x2000, 0x8000);
    memory.Word(0x2004, 0x2f38);
    memory.Word(0x2008, 0x100);
    memory.Word(0x200c, 0x40);
    memory.Word(0x2ff0, 0x3008);
    memory.Word(0x3010, 123456);
    memory.Word(compact ? 0x2efc : 0x2f00, 123456);
    memory.Word(compact ? 0x2ee8 : 0x2ee4, 0x5000);
    memory.Word(0x5000, 0x9000);
    memory.Word(compact ? 0x2fac : 0x2f7c, 0x100);
    memory.Word(compact ? 0x2f64 : 0x2ef8, 0x40);
    Path(L"C:\\synthetic\\z0001.ovk");
  }
  void Path(const wchar_t *path) {
    const uint32_t n = static_cast<uint32_t>(std::wcslen(path));
    uint32_t u[6] = {};
    u[0] = 0x6000;
    u[4] = n;
    u[5] = n < 8 ? 7 : n;
    memory.Put(0x2f38, u, sizeof(u));
    memory.Put(n < 8 ? 0x2f38 : 0x6000, path, (n + 1) * sizeof(wchar_t));
  }
  bool Capture(SiglusVoiceSourceTask *out) {
    return CaptureSiglusNativeVoiceSource(layout, call, memory, out);
  }
  void Reject() {
    SiglusVoiceSourceTask out;
    out.key = 999;
    Check(!Capture(&out));
    Check(out.key == 999);
  }
};
void TestCapture(bool compact) {
  Fixture first(compact);
  SiglusVoiceSourceTask out;
  Check(first.Capture(&out));
  Check(out.key == 123456 && out.offset == 0x100 && out.length == 0x40 &&
        std::wcscmp(out.path, L"C:\\synthetic\\z0001.ovk") == 0);
  // The other legal stack alignment keeps EBP fixed but changes original EBX.
  {
    Fixture f(compact);
    f.call.original_ebx = 0x300c;
    f.memory.Word(0x2ff0, 0x300c);
    f.memory.Word(0x3014, 123456);
    Check(f.Capture(&out));
  }
  const uint32_t fields[] = {0x2000,
                             0x2004,
                             0x2008,
                             0x200c,
                             0x2ff0,
                             0x3010,
                             (compact ? 0x2efcu : 0x2f00u),
                             (compact ? 0x2ee8u : 0x2ee4u),
                             0x5000,
                             (compact ? 0x2facu : 0x2f7cu),
                             (compact ? 0x2f64u : 0x2ef8u)};
  for (auto a : fields) {
    Fixture f(compact);
    uint32_t value = 0;
    Check(f.memory(a, &value, 4));
    f.memory.Word(a, value + 1);
    f.Reject();
    Fixture unreadable(compact);
    unreadable.memory.bytes.erase(a);
    unreadable.Reject();
  }
  for (auto path : {L"relative.ovk", L"D:relative.ovk", L"\\root.ovk",
                    L"\\\\server", L"\\\\server\\share", L"\\\\?\\C:\\x.ovk"}) {
    Fixture f(compact);
    f.Path(path);
    f.Reject();
  }
  for (auto path : {L"C:\\x.o", L"\\\\server\\share\\z0001.ovk"}) {
    Fixture f(compact);
    f.Path(path);
    Check(f.Capture(&out));
  }
  {
    Fixture f(compact);
    f.call.original_ebx = 0x40;
    f.Reject();
  }
  {
    Fixture f(compact);
    f.call.original_ebx = UINT32_MAX - 3;
    f.Reject();
  }
  {
    Fixture f(compact);
    f.call.caller_ebp += 4;
    f.Reject();
  }
  {
    Fixture f(compact);
    f.call.reader = 0;
    f.Reject();
  }
  {
    Fixture f(compact);
    f.layout.payload_return = 0;
    f.Reject();
  }
  {
    Fixture f(compact);
    f.memory.Word(0x3010, UINT32_MAX);
    f.memory.Word((compact ? 0x2efcu : 0x2f00u), UINT32_MAX);
    f.Reject();
  }
  {
    Fixture f(compact);
    f.memory.Word(0x2008, UINT32_MAX - 4);
    f.memory.Word((compact ? 0x2facu : 0x2f7cu), UINT32_MAX - 4);
    f.Reject();
  }
  {
    Fixture f(compact);
    f.memory.Word(0x200c, 0);
    f.memory.Word((compact ? 0x2f64u : 0x2ef8u), 0);
    f.Reject();
  }
  {
    Fixture f(compact);
    f.Path(std::wstring(520, L'x').c_str());
    f.Reject();
  }
  {
    Fixture f(compact);
    f.memory.Word(0x2f48, 0);
    f.Reject();
  }
  {
    Fixture f(compact);
    f.memory.Word(0x2f4c, 0);
    f.Reject();
  }
  {
    Fixture f(compact);
    f.memory.Word(0x2f38, UINT32_MAX - 3);
    f.Reject();
  }
  {
    Fixture f(compact);
    f.memory.bytes[0x6004] = 0;
    f.memory.bytes[0x6005] = 0;
    f.Reject();
  }
  {
    Fixture f(compact);
    int reads = 0;
    auto changing = [&](uint32_t a, void *p, size_t n) {
      const bool ok = f.memory(a, p, n);
      if (a == 0x2f38 && ++reads == 2)
        static_cast<uint32_t *>(p)[4]++;
      return ok;
    };
    Check(!CaptureSiglusNativeVoiceSource(f.layout, f.call, changing, &out));
  }
  {
    Fixture f(compact);
    f.layout.frame = compact ? SiglusNativeResourceFrame::kStack120
                             : SiglusNativeResourceFrame::kStack118;
    f.Reject();
  }
  {
    Fixture f(compact);
    f.layout.frame = static_cast<SiglusNativeResourceFrame>(99);
    f.Reject();
  }
  Check(!CaptureSiglusNativeVoiceSource(first.layout, first.call, first.memory,
                                        nullptr));
}
} // namespace
int main() {
  TestResolver(false);
  TestResolver(true);
  TestFamilies();
  TestCapture(false);
  TestCapture(true);
  std::printf("PASS Siglus Native resource %d checks\n", checks);
}
