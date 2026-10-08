// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "artemis_lookup_core.h"
#include "../artemis_pfs.h"

namespace core = fushi_voice_hook::artemis_lookup;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

// ── synthetic PE image ──────────────────────────────────────────────────────
//
// One committed region split into an executable "code" section and a
// read-only "data" section.  Every engine proof is laid out the way a real
// executable arranges it, with the relative operands pointing at the fake
// targets, so ResolveSites is exercised end to end without a game binary.
// Two measured builds are reproduced byte for byte around the proofs:
// アマナツ (EH-framed factory, r11-based constructor, Input::Update(input,
// now)) and アマカノ3 (frameless factory with a fifth constructor argument,
// rdi-based constructor, queue-draining Input::Update(input)).

enum class Layout { kAmanatsu, kAmakano3 };

// アマナツ: Layer::CreateGlyph, new(0x108) at +34, ctor call at +61.
constexpr uint8_t kAmanatsuFactory[] = {
    0x40, 0x57, 0x48, 0x83, 0xec, 0x40, 0x48, 0xc7, 0x44, 0x24, 0x30, 0xfe,
    0xff, 0xff, 0xff, 0x48, 0x89, 0x5c, 0x24, 0x50, 0x48, 0x89, 0x74, 0x24,
    0x58, 0x49, 0x8b, 0xd8, 0x48, 0x8b, 0xfa, 0x48, 0x8b, 0xf1, 0xb9, 0x08,
    0x01, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x48, 0x89, 0x44, 0x24,
    0x68, 0x4c, 0x8b, 0xcb, 0x4c, 0x8b, 0xc7, 0x48, 0x8b, 0xd6, 0x48, 0x8b,
    0xc8, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x90};
constexpr size_t kAmanatsuNewCall = 39u;
constexpr size_t kAmanatsuCtorCall = 61u;
// `call base; nop; lea rax,[rip+vtable]; mov [r11],rax`.
constexpr uint8_t kAmanatsuCtorVtable[] = {0xe8, 0x00, 0x00, 0x00, 0x00, 0x90,
                                           0x48, 0x8d, 0x05, 0x00, 0x00, 0x00,
                                           0x00, 0x49, 0x89, 0x03};
// `mov [r11+0x88],r12; mov [r11+0x90],r12`.
constexpr uint8_t kAmanatsuCtorCell[] = {0x4d, 0x89, 0xa3, 0x88, 0x00,
                                         0x00, 0x00, 0x4d, 0x89, 0xa3,
                                         0x90, 0x00, 0x00, 0x00};
// Input::Update(input, now) prologue up to the 256-key loop bound, then the
// cursor mapping's `mov rcx,[rdi+0x3158]` (moved next to the loop here).
constexpr uint8_t kAmanatsuUpdate[] = {
    0x48, 0x89, 0x5c, 0x24, 0x10, 0x48, 0x89, 0x6c, 0x24, 0x18, 0x56, 0x57,
    0x41, 0x54, 0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xec, 0x90, 0x00, 0x00,
    0x00, 0x48, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00, 0x48, 0x33, 0xc4, 0x48,
    0x89, 0x84, 0x24, 0x80, 0x00, 0x00, 0x00, 0x8b, 0x99, 0x48, 0x31, 0x00,
    0x00, 0x4c, 0x8d, 0xb1, 0x38, 0x08, 0x00, 0x00, 0x48, 0x8d, 0x71, 0x18,
    0x89, 0x54, 0x24, 0x28, 0x4d, 0x8b, 0xc6, 0x4c, 0x8b, 0xd6, 0x44, 0x8b,
    0xfa, 0x48, 0x8b, 0xf9, 0x41, 0xbb, 0x00, 0x01, 0x00, 0x00, 0x48, 0x8b,
    0x8f, 0x58, 0x31, 0x00, 0x00};
constexpr size_t kAmanatsuKeyStateDisp = 59u;  // `lea rsi,[rcx+0x18]`

// アマカノ3: Layer::CreateGlyph, new(0x108) at +29, ctor call at +59.
constexpr uint8_t kAmakano3Factory[] = {
    0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48,
    0x83, 0xec, 0x30, 0x49, 0x8b, 0xd8, 0x48, 0x8b, 0xfa, 0x48, 0x8b, 0xf1,
    0xb9, 0x08, 0x01, 0x00, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00, 0x48, 0x89,
    0x44, 0x24, 0x58, 0xc7, 0x44, 0x24, 0x20, 0x01, 0x00, 0x00, 0x00, 0x4c,
    0x8b, 0xcb, 0x4c, 0x8b, 0xc7, 0x48, 0x8b, 0xd6, 0x48, 0x8b, 0xc8, 0xe8,
    0x00, 0x00, 0x00, 0x00, 0x90};
constexpr size_t kAmakano3NewCall = 29u;
constexpr size_t kAmakano3CtorCall = 59u;
// `call base; nop; lea rax,[rip+vtable]; mov [rdi],rax`.
constexpr uint8_t kAmakano3CtorVtable[] = {0xe8, 0x00, 0x00, 0x00, 0x00, 0x90,
                                           0x48, 0x8d, 0x05, 0x00, 0x00, 0x00,
                                           0x00, 0x48, 0x89, 0x07};
// `mov [rdi+0x88],r12; mov [rdi+0x90],r12`.
constexpr uint8_t kAmakano3CtorCell[] = {0x4c, 0x89, 0xa7, 0x88, 0x00,
                                         0x00, 0x00, 0x4c, 0x89, 0xa7,
                                         0x90, 0x00, 0x00, 0x00};
// Input::Update(input, now): `mov r11d,[rcx+0x3148]`, queue/key-state leas,
// the 256-key bound in r10d, then the cursor mapping's
// `mov rcx,[rdi+0x3158]` (moved next to the loop here).
constexpr uint8_t kAmakano3Update[] = {
    0x48, 0x89, 0x5c, 0x24, 0x10, 0x48, 0x89, 0x6c, 0x24, 0x18, 0x56, 0x57,
    0x41, 0x54, 0x41, 0x56, 0x41, 0x57, 0x48, 0x81, 0xec, 0x90, 0x00, 0x00,
    0x00, 0x48, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00, 0x48, 0x33, 0xc4, 0x48,
    0x89, 0x84, 0x24, 0x80, 0x00, 0x00, 0x00, 0x44, 0x8b, 0x99, 0x48, 0x31,
    0x00, 0x00, 0x4c, 0x8d, 0xb1, 0x38, 0x08, 0x00, 0x00, 0x48, 0x8d, 0x71,
    0x18, 0x89, 0x54, 0x24, 0x28, 0x4d, 0x8b, 0xc6, 0x4c, 0x8b, 0xce, 0x44,
    0x8b, 0xfa, 0x48, 0x8b, 0xf9, 0x41, 0xba, 0x00, 0x01, 0x00, 0x00, 0x48,
    0x8b, 0x8f, 0x58, 0x31, 0x00, 0x00};
constexpr size_t kAmakano3KeyStateDisp = 60u;  // `lea rsi,[rcx+0x18]`
// The queue-flush helper next to it: same queues, same loop, no cursor.
constexpr uint8_t kAmakano3QueueFlush[] = {
    0x48, 0x89, 0x5c, 0x24, 0x08, 0x4c, 0x8b, 0xc9, 0x4c, 0x8d, 0x81, 0x38,
    0x08, 0x00, 0x00, 0x4c, 0x8d, 0x51, 0x18, 0x33, 0xdb, 0x41, 0xbb, 0x00,
    0x01, 0x00, 0x00, 0x41, 0x8b, 0x81, 0x48, 0x31, 0x00, 0x00, 0xc3};

constexpr uint8_t kCtorMultibyte[] = {0x83, 0xf0, 0x20, 0x2d,
                                      0xa1, 0x00, 0x00, 0x00};

class SyntheticImage {
 public:
  static constexpr size_t kSize = 0x10000u;
  static constexpr size_t kCode = 0x0000u;
  static constexpr size_t kData = 0x8000u;
  static constexpr size_t kFactory = 0x0100u;
  static constexpr size_t kCtor = 0x0400u;
  static constexpr size_t kDrawSibling = 0x1000u;
  static constexpr size_t kDraw = 0x1100u;
  static constexpr size_t kUpdate = 0x2000u;
  static constexpr size_t kCursor = 0x3000u;
  static constexpr size_t kVtable = kData + 0x100u;
  static constexpr size_t kLayerVtable = kData + 0x400u;
  static constexpr size_t kInputVtable = kData + 0x500u;

  explicit SyntheticImage(Layout layout = Layout::kAmanatsu) : layout(layout) {
    base = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    assert(base != nullptr);
    std::memset(base, 0xcc, kSize);
    std::memset(base + kData, 0x00, kSize - kData);
    image.base = base;
    image.size = kSize;
    image.machine = IMAGE_FILE_MACHINE_AMD64;
    image.pointer_bits = 64u;
    image.section_count = 2u;
    image.sections[0] = {base + kCode, kData, kCode,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {base + kData, kSize - kData, kData,
                         IMAGE_SCN_MEM_READ};
    WriteAll();
  }
  ~SyntheticImage() { VirtualFree(base, 0u, MEM_RELEASE); }
  SyntheticImage(const SyntheticImage&) = delete;
  SyntheticImage& operator=(const SyntheticImage&) = delete;

  void WriteRel32(size_t at, size_t target) {
    const int32_t displacement = static_cast<int32_t>(
        static_cast<intptr_t>(target) - static_cast<intptr_t>(at + 4u));
    std::memcpy(base + at, &displacement, sizeof(displacement));
  }

  bool amanatsu() const { return layout == Layout::kAmanatsu; }

  // Writes one Layer::CreateGlyph at `at` whose constructor is `ctor`.
  void WriteFactory(size_t at, size_t ctor) {
    if (amanatsu()) {
      std::memcpy(base + at, kAmanatsuFactory, sizeof(kAmanatsuFactory));
      WriteRel32(at + kAmanatsuNewCall + 1u, 0x7000u);  // operator new
      WriteRel32(at + kAmanatsuCtorCall + 1u, ctor);
    } else {
      std::memcpy(base + at, kAmakano3Factory, sizeof(kAmakano3Factory));
      WriteRel32(at + kAmakano3NewCall + 1u, 0x7000u);
      WriteRel32(at + kAmakano3CtorCall + 1u, ctor);
    }
  }

  size_t KeyStateDisp() const {
    return kUpdate +
           (amanatsu() ? kAmanatsuKeyStateDisp : kAmakano3KeyStateDisp);
  }

  void WriteAll() {
    WriteFactory(kFactory, kCtor);
    SetPointer(kLayerVtable, kFactory);

    // Constructor: vtable lea, cell zeroing and the SJIS width test.
    const uint8_t* vtable_store =
        amanatsu() ? kAmanatsuCtorVtable : kAmakano3CtorVtable;
    std::memcpy(base + kCtor + 0x90u, vtable_store,
                sizeof(kAmanatsuCtorVtable));
    WriteRel32(kCtor + 0x90u + 1u, 0x7100u);
    WriteRel32(kCtor + 0x90u + core::kCtorVtableLeaOffset + 3u, kVtable);
    std::memcpy(base + kCtor + 0xc0u,
                amanatsu() ? kAmanatsuCtorCell : kAmakano3CtorCell,
                sizeof(kAmanatsuCtorCell));
    std::memcpy(base + kCtor + 0x170u, kCtorMultibyte, sizeof(kCtorMultibyte));

    std::memcpy(base + kDrawSibling, core::kGlyphDrawBytes,
                sizeof(core::kGlyphDrawBytes));
    base[kDrawSibling + core::kGlyphDrawForwardSlotByte] = 0x10u;
    std::memcpy(base + kDraw, core::kGlyphDrawBytes,
                sizeof(core::kGlyphDrawBytes));
    SetVtableSlot(core::kGlyphDrawSiblingSlot, kDrawSibling);
    SetVtableSlot(core::kGlyphDrawSlot, kDraw);

    if (amanatsu()) {
      std::memcpy(base + kUpdate, kAmanatsuUpdate, sizeof(kAmanatsuUpdate));
    } else {
      std::memcpy(base + kUpdate, kAmakano3Update, sizeof(kAmakano3Update));
    }
    SetPointer(kInputVtable, kUpdate);
    std::memcpy(base + kCursor, core::kCursorMappingBytes,
                sizeof(core::kCursorMappingBytes));
  }

  void SetPointer(size_t at, size_t target) {
    const uintptr_t absolute =
        target == 0u ? 0u : reinterpret_cast<uintptr_t>(base + target);
    std::memcpy(base + at, &absolute, sizeof(absolute));
  }

  void SetVtableSlot(size_t slot, size_t target) {
    SetPointer(kVtable + slot * sizeof(uintptr_t), target);
  }

  uintptr_t At(size_t offset) const {
    return reinterpret_cast<uintptr_t>(base + offset);
  }

  Layout layout;
  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

core::SiteResult Resolve(SyntheticImage& fixture, core::Sites* sites) {
  return core::ResolveSites(fixture.image, sites);
}

void TestResolveSitesLayout(Layout layout) {
  {
    SyntheticImage fixture(layout);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kResolved);
    assert(sites.glyph_factory == fixture.At(SyntheticImage::kFactory));
    assert(sites.glyph_ctor == fixture.At(SyntheticImage::kCtor));
    assert(sites.glyph_vtable == fixture.At(SyntheticImage::kVtable));
    assert(sites.glyph_draw == fixture.At(SyntheticImage::kDraw));
    assert(sites.input_update == fixture.At(SyntheticImage::kUpdate));
  }
  {
    // An x86 image never matches the x64 ABI proofs.
    SyntheticImage fixture(layout);
    fixture.image.machine = IMAGE_FILE_MACHINE_I386;
    fixture.image.pointer_bits = 32u;
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kNotX64);
    assert(sites.glyph_draw == 0u);
  }
  {
    // Two complete factories (both virtual, both building a glyph):
    // ambiguous, fail closed.
    SyntheticImage fixture(layout);
    fixture.WriteFactory(0x5000u, SyntheticImage::kCtor);
    fixture.SetPointer(SyntheticImage::kLayerVtable + 8u, 0x5000u);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kFactoryMissing);
    assert(sites.glyph_factory == 0u);
  }
  {
    // A factory whose entry nothing references is not a function the
    // engine calls: no entry, no hook.
    SyntheticImage fixture(layout);
    fixture.SetPointer(SyntheticImage::kLayerVtable, 0u);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kFactoryMissing);
  }
  {
    // An int3 run between the referenced address and the allocation means
    // the allocation lives in a different function.
    SyntheticImage fixture(layout);
    fixture.base[SyntheticImage::kFactory + 2u] = 0xccu;
    fixture.base[SyntheticImage::kFactory + 3u] = 0xccu;
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kFactoryMissing);
  }
  {
    // The factory must call a constructor that measures one multibyte char.
    SyntheticImage fixture(layout);
    std::memset(fixture.base + SyntheticImage::kCtor + 0x170u, 0x90,
                sizeof(kCtorMultibyte));
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kCtorInvalid);
  }
  {
    // A cell field at a different offset is a different layout.
    SyntheticImage fixture(layout);
    fixture.base[SyntheticImage::kCtor + 0xc0u + 3u] = 0x80u;
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kCtorInvalid);
  }
  {
    // Width and height must come from the same register into the same base.
    SyntheticImage fixture(layout);
    fixture.base[SyntheticImage::kCtor + 0xc0u + 9u] ^= 0x08u;
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kCtorInvalid);
  }
  {
    // The vtable store must write rax to the object base.
    SyntheticImage fixture(layout);
    fixture.base[SyntheticImage::kCtor + 0x90u + 15u] |= 0x08u;  // reg != rax
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kCtorInvalid);
  }
  {
    // A vtable in an executable section is not a vtable.
    SyntheticImage fixture(layout);
    fixture.WriteRel32(SyntheticImage::kCtor + 0x90u +
                           core::kCtorVtableLeaOffset + 3u,
                       0x4000u);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kVtableInvalid);
  }
  {
    // Slot 4 must forward the draw pass (+0x18) and slot 3 its sibling.
    SyntheticImage fixture(layout);
    fixture.SetVtableSlot(core::kGlyphDrawSlot, SyntheticImage::kDrawSibling);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kDrawInvalid);
  }
  {
    SyntheticImage fixture(layout);
    fixture.SetVtableSlot(core::kGlyphDrawSiblingSlot, SyntheticImage::kDraw);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kDrawInvalid);
  }
  {
    // A different key-state array offset is not the measured Input::Update.
    SyntheticImage fixture(layout);
    fixture.base[fixture.KeyStateDisp()] = 0x20u;  // lea r,[rcx+0x20]
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kUpdateMissing);
  }
  {
    // A referenced queue-flush helper drains the same queues but never maps
    // the cursor: it is not Update and does not make Update ambiguous.
    SyntheticImage fixture(layout);
    std::memcpy(fixture.base + 0x2800u, kAmakano3QueueFlush,
                sizeof(kAmakano3QueueFlush));
    fixture.SetPointer(SyntheticImage::kInputVtable + 8u, 0x2800u);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kResolved);
    assert(sites.input_update == fixture.At(SyntheticImage::kUpdate));
  }
  {
    // Without the game-window access the loop is only a queue drain.
    SyntheticImage fixture(layout);
    const size_t update_bytes =
        fixture.amanatsu() ? sizeof(kAmanatsuUpdate) : sizeof(kAmakano3Update);
    fixture.base[SyntheticImage::kUpdate + update_bytes - 3u] = 0x30u;
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kUpdateMissing);
  }
  {
    // Input::Update must be a function the engine references.
    SyntheticImage fixture(layout);
    fixture.SetPointer(SyntheticImage::kInputVtable, 0u);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kUpdateMissing);
  }
  {
    // A direct call is as good a reference as a vtable slot.
    SyntheticImage fixture(layout);
    fixture.SetPointer(SyntheticImage::kInputVtable, 0u);
    fixture.base[0x4800u] = 0xe8u;
    fixture.WriteRel32(0x4801u, SyntheticImage::kUpdate);
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kResolved);
    assert(sites.input_update == fixture.At(SyntheticImage::kUpdate));
  }
  {
    // Without the cursor mapping the projection offsets are unproven.
    SyntheticImage fixture(layout);
    fixture.base[SyntheticImage::kCursor + 63u] = 0x18u;  // subss [rbx+0x18]
    core::Sites sites;
    assert(Resolve(fixture, &sites) == core::SiteResult::kCursorMappingMissing);
    assert(sites.glyph_factory == 0u);
  }
}

void TestResolveSitesFromStructure() {
  TestResolveSitesLayout(Layout::kAmanatsu);
  TestResolveSitesLayout(Layout::kAmakano3);
}

void TestFactoryCharacterDecode() {
  const uint8_t ore_utf8[] = {0xe4, 0xbf, 0xba, 0x00};
  assert(core::DecodeFactoryCharacter(ore_utf8) == 0x4ffau);
  const uint8_t ascii[] = {'A', 0x00};
  assert(core::DecodeFactoryCharacter(ascii) == 0x41u);
  const uint8_t ore_sjis[] = {0x89, 0xb4, 0x00};
  assert(core::DecodeFactoryCharacter(ore_sjis) == 0x4ffau);
  const uint8_t kana_sjis[] = {0xb1, 0x00};  // half-width ｱ
  assert(core::DecodeFactoryCharacter(kana_sjis) == 0xff71u);
  const uint8_t emoji[] = {0xf0, 0x9f, 0x98, 0x80, 0x00};
  assert(core::DecodeFactoryCharacter(emoji) == 0x1f600u);
  const uint8_t two_chars[] = {'a', 'b', 0x00};
  assert(core::DecodeFactoryCharacter(two_chars) == 0u);
  const uint8_t overlong[] = {0xe0, 0x80, 0x80, 0x00};
  assert(core::DecodeFactoryCharacter(overlong) == 0u);
  const uint8_t lone_continuation[] = {0x80, 0x00};
  assert(core::DecodeFactoryCharacter(lone_continuation) == 0u);
  const uint8_t empty[] = {0x00};
  assert(core::DecodeFactoryCharacter(empty) == 0u);
  const uint8_t unterminated[] = {'a', 'b', 'c', 'd', 'e', 'f'};
  assert(core::DecodeFactoryCharacter(unterminated) == 0u);
}

void TestGlyphCodeTable() {
  static core::GlyphCodeTable<16u, 4u> table;
  table.Clear();
  core::GlyphCode code;
  assert(!table.Find(0x1000u, &code));
  table.Remember(0x1000u, 0x4ffau, 1u);
  assert(table.Find(0x1000u, &code) && code.codepoint == 0x4ffau &&
         code.seq == 1u);
  // A freed glyph's address reused by a later glyph takes the new identity.
  table.Remember(0x1000u, 0x306fu, 9u);
  assert(table.Find(0x1000u, &code) && code.codepoint == 0x306fu &&
         code.seq == 9u);
  // Unknown characters are remembered as unknown, never as a match.
  table.Remember(0x2000u, 0u, 10u);
  assert(!table.Find(0x2000u, &code));
  // Filling far past capacity keeps the newest entries findable.
  for (uintptr_t index = 0; index < 64u; ++index) {
    table.Remember(0x10000u + index * 0x110u, 0x3042u, 100u + index);
  }
  size_t newest_found = 0u;
  for (uintptr_t index = 60u; index < 64u; ++index) {
    if (table.Find(0x10000u + index * 0x110u, &code)) ++newest_found;
  }
  assert(newest_found == 4u);
}

void TestCellBounds() {
  const float identity[6] = {1.0f, 0.0f, 340.0f, 0.0f, 1.0f, 552.0f};
  core::CellBounds bounds;
  assert(core::ComputeCellBounds(identity, 27.0f, 41.0f, &bounds));
  assert(bounds.left == 340.0f && bounds.top == 552.0f &&
         bounds.right == 367.0f && bounds.bottom == 593.0f);
  const float scaled[6] = {2.0f, 0.0f, 10.0f, 0.0f, 0.5f, 20.0f};
  assert(core::ComputeCellBounds(scaled, 10.0f, 10.0f, &bounds));
  assert(bounds.left == 10.0f && bounds.right == 30.0f &&
         bounds.top == 20.0f && bounds.bottom == 25.0f);
  const float mirrored[6] = {-1.0f, 0.0f, 100.0f, 0.0f, 1.0f, 0.0f};
  assert(core::ComputeCellBounds(mirrored, 10.0f, 10.0f, &bounds));
  assert(bounds.left == 90.0f && bounds.right == 100.0f);
  const float singular[6] = {0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f};
  assert(!core::ComputeCellBounds(singular, 10.0f, 10.0f, &bounds));
  assert(!core::ComputeCellBounds(identity, 0.0f, 41.0f, &bounds));
  const float broken[6] = {1.0f, 0.0f, NAN, 0.0f, 1.0f, 0.0f};
  assert(!core::ComputeCellBounds(broken, 27.0f, 41.0f, &bounds));
}

void TestProjection() {
  const core::CellBounds cell = {340.0f, 552.0f, 367.0f, 593.0f};
  core::PixelRect rect;
  // 1280x720 client, design 1280x720, no DPI virtualization.
  core::EngineProjection same = {1.0f, 0.0f, 0.0f, 1280, 720};
  assert(core::ProjectCell(cell, same, 1280, 720, &rect));
  assert(rect.x == 340 && rect.y == 552 && rect.w == 27 && rect.h == 41);
  // Measured letterbox: 960x600 client -> k = 4/3, off_y = 30.  The world
  // matrix of the glyph laid out at design (340,552) already carries the root
  // transform: {0.75, 0, 255, 0, 0.75, 444}.
  const float root = 1.0f / (4.0f / 3.0f);
  const float letterboxed[6] = {root, 0.0f, 255.0f, 0.0f, root, 444.0f};
  core::EngineProjection letterbox = {4.0f / 3.0f, 0.0f, 30.0f, 960, 600};
  assert(core::GlyphInEngineClientSpace(letterboxed,
                                        letterbox.design_per_client));
  core::CellBounds letterboxed_cell;
  assert(core::ComputeCellBounds(letterboxed, 27.0f, 41.0f, &letterboxed_cell));
  assert(core::ProjectCell(letterboxed_cell, letterbox, 960, 600, &rect));
  assert(rect.x == 255 && rect.y == 444 && rect.w == 21 && rect.h == 31);
  // A renderer whose world stayed in design units (a == 1 while k == 4/3),
  // or a glyph under its own zoom/rotation effect, is not in client space.
  const float design_space[6] = {1.0f, 0.0f, 340.0f, 0.0f, 1.0f, 552.0f};
  assert(!core::GlyphInEngineClientSpace(design_space,
                                         letterbox.design_per_client));
  assert(core::GlyphInEngineClientSpace(design_space, 1.0f));
  const float zoomed[6] = {1.2f, 0.0f, 340.0f, 0.0f, 1.2f, 552.0f};
  assert(!core::GlyphInEngineClientSpace(zoomed, 1.0f));
  const float rotated[6] = {0.0f, -1.0f, 340.0f, 1.0f, 0.0f, 552.0f};
  assert(!core::GlyphInEngineClientSpace(rotated, 1.0f));
  assert(!core::GlyphInEngineClientSpace(design_space, 0.0f));
  // A DPI-virtualized engine: logical 1280x720, physical 1920x1080.
  assert(core::ProjectCell(cell, same, 1920, 1080, &rect));
  assert(rect.x == 510 && rect.y == 828 && rect.w == 41 && rect.h == 62);
  // Off-screen cells (the engine parks unused glyphs at y=-200) are rejected.
  const core::CellBounds parked = {0.0f, -200.0f, 8.0f, -180.0f};
  assert(!core::ProjectCell(parked, same, 1280, 720, &rect));
  const core::CellBounds past_right = {1270.0f, 10.0f, 1290.0f, 20.0f};
  assert(!core::ProjectCell(past_right, same, 1280, 720, &rect));
  core::EngineProjection broken = {0.0f, 0.0f, 0.0f, 1280, 720};
  assert(!core::ProjectCell(cell, broken, 1280, 720, &rect));
  core::EngineProjection no_client = {1.0f, 0.0f, 0.0f, 0, 0};
  assert(!core::ProjectCell(cell, no_client, 1280, 720, &rect));
}

core::FrameGlyph Glyph(uint64_t seq, uint32_t codepoint, float x) {
  core::FrameGlyph glyph;
  glyph.seq = seq;
  glyph.codepoint = codepoint;
  glyph.bounds = {x, 552.0f, x + 27.0f, 593.0f};
  return glyph;
}

void TestOrderFrameGlyphs() {
  core::FrameGlyph glyphs[] = {Glyph(5, L'b', 30.0f), Glyph(3, L'a', 0.0f),
                               Glyph(5, L'b', 30.0f), Glyph(4, 0u, 10.0f),
                               Glyph(7, L'c', 60.0f)};
  const size_t count = core::OrderFrameGlyphs(glyphs, 5u);
  assert(count == 3u);
  assert(glyphs[0].seq == 3u && glyphs[1].seq == 5u && glyphs[2].seq == 7u);
}

void TestSelectedSuffix() {
  // Frame: an older unrelated label, then the name plate and the dialogue.
  const wchar_t* frame_text = L"古い遥斗「……」";
  std::vector<core::FrameGlyph> glyphs;
  for (size_t index = 0; frame_text[index] != 0; ++index) {
    glyphs.push_back(
        Glyph(10u + index, frame_text[index], 27.0f * index));
  }
  core::TextMapping mapping;
  const wchar_t* selected = L"遥斗「……」";
  assert(core::ResolveSelectedSuffix(glyphs.data(), glyphs.size(), selected,
                                     wcslen(selected), &mapping));
  assert(mapping.first_glyph == 2u);
  assert(mapping.source_index[0] == core::kNoSource);
  assert(mapping.source_index[1] == core::kNoSource);
  for (size_t index = 2; index < glyphs.size(); ++index) {
    assert(mapping.source_index[index] == index - 2u);
    assert(mapping.source_length[index] == 1u);
  }

  // LunaHook without the name plate maps only the dialogue.
  const wchar_t* dialogue = L"「……」";
  assert(core::ResolveSelectedSuffix(glyphs.data(), glyphs.size(), dialogue,
                                     wcslen(dialogue), &mapping));
  assert(mapping.first_glyph == 4u);
  assert(mapping.source_index[3] == core::kNoSource);
  assert(mapping.source_index[4] == 0u);

  // Whitespace on either side is not identity.
  const wchar_t* spaced = L"遥斗\n「……」　";
  assert(core::ResolveSelectedSuffix(glyphs.data(), glyphs.size(), spaced,
                                     wcslen(spaced), &mapping));
  assert(mapping.source_index[4] == 3u);

  // Not the newest visible text (e.g. the typewriter is still on a new line,
  // or the window shows another line): no mapping.
  const wchar_t* other = L"遥斗「…」";
  assert(!core::ResolveSelectedSuffix(glyphs.data(), glyphs.size(), other,
                                      wcslen(other), &mapping));
  const wchar_t* longer = L"とても古い遥斗「……」";
  assert(!core::ResolveSelectedSuffix(glyphs.data(), glyphs.size(), longer,
                                      wcslen(longer), &mapping));
  const wchar_t* blank = L" 　";
  assert(!core::ResolveSelectedSuffix(glyphs.data(), glyphs.size(), blank,
                                      wcslen(blank), &mapping));

  // A supplementary-plane glyph covers two UTF-16 units.
  core::FrameGlyph supplementary[] = {Glyph(1, 0x20bb7u, 0.0f),
                                      Glyph(2, L'野', 27.0f)};
  const wchar_t* yoshino = L"\U00020BB7野";
  assert(core::ResolveSelectedSuffix(supplementary, 2u, yoshino,
                                     wcslen(yoshino), &mapping));
  assert(mapping.source_index[0] == 0u && mapping.source_length[0] == 2u);
  assert(mapping.source_index[1] == 2u && mapping.source_length[1] == 1u);

  // A full-width space glyph inside the line is skipped, not mapped.
  core::FrameGlyph with_space[] = {Glyph(1, L'あ', 0.0f),
                                   Glyph(2, 0x3000u, 27.0f),
                                   Glyph(3, L'い', 54.0f)};
  const wchar_t* ai = L"あい";
  assert(core::ResolveSelectedSuffix(with_space, 3u, ai, wcslen(ai),
                                     &mapping));
  assert(mapping.first_glyph == 0u);
  assert(mapping.source_index[1] == core::kNoSource);
  assert(mapping.source_index[2] == 1u);
}

std::vector<core::FrameGlyph> GlyphRun(uint64_t first_seq, const wchar_t* text) {
  std::vector<core::FrameGlyph> glyphs;
  for (size_t index = 0; text[index] != 0; ++index) {
    glyphs.push_back(Glyph(first_seq + index, text[index], 27.0f * index));
  }
  return glyphs;
}

// Records every glyph as created (drawn or not) in seq order.
core::CreationLog LogOf(const std::vector<core::FrameGlyph>& glyphs) {
  core::CreationLog log;
  for (const auto& glyph : glyphs) log.Record(glyph.seq, glyph.codepoint);
  return log;
}

void TestFactoryCreationCode() {
  const uint8_t newline[] = {'\n', 0};
  const uint8_t tab[] = {'\t', 0};
  const uint8_t a[] = {'a', 0};
  const uint8_t two_controls[] = {'\r', '\n', 0};
  const uint8_t empty[] = {0};
  assert(core::FactoryCreationCode(newline) == core::kCreatedControl);
  assert(core::FactoryCreationCode(tab) == core::kCreatedControl);
  assert(core::FactoryCreationCode(a) == u'a');
  assert(core::FactoryCreationCode(two_controls) == 0u);
  assert(core::FactoryCreationCode(empty) == core::kCreatedControl);
  const uint8_t invalid_utf8[] = {0x81, 0};  // lone lead byte
  assert(core::FactoryCreationCode(invalid_utf8) == 0u);
  assert(core::FactoryCreationCode(nullptr) == 0u);
}

void TestRevealedLine() {
  std::wstring text;
  uint64_t first_seq = 0u;
  // A persistent UI glyph (old seq) plus the newest burst: name plate and
  // dialogue are one consecutive creation run.
  std::vector<core::FrameGlyph> frame = GlyphRun(25u, L"\u3000");
  const auto line = GlyphRun(153u, L"ミサ「さゆ\u3000です」\u3000");
  frame.insert(frame.end(), line.begin(), line.end());
  const uint64_t newest = 153u + line.size() - 1u;
  core::CreationLog log = LogOf(frame);
  assert(core::ComposeRevealedLine(frame.data(), frame.size(), newest, log,
                                   &text, &first_seq));
  assert(text == L"ミサ「さゆ\u3000です」");
  assert(first_seq == 153u);

  // The engine created visible glyphs that are not drawn (choice menu hover
  // labels, a line still being revealed): not a revealed line.
  core::CreationLog later = log;
  for (uint64_t seq = newest + 1u; seq <= newest + 3u; ++seq) {
    later.Record(seq, L'x');
  }
  assert(!core::ComposeRevealedLine(frame.data(), frame.size(), newest + 3u,
                                    later, &text, &first_seq));
  // ...but a trailing line break or space created after the last drawn glyph
  // does not hide the line.
  later = log;
  later.Record(newest + 1u, core::kCreatedControl);
  later.Record(newest + 2u, L' ');
  assert(core::ComposeRevealedLine(frame.data(), frame.size(), newest + 2u,
                                   later, &text, &first_seq));
  assert(text == L"ミサ「さゆ\u3000です」" && first_seq == 153u);

  // A wrapped line: the line break and an undrawn space are created between
  // the two rows; the rows are one line, the break is dropped, the space kept.
  std::vector<core::FrameGlyph> wrapped = GlyphRun(25u, L"\u3000");
  const auto row1 = GlyphRun(200u, L"鴻さん「もう、");
  const auto row2 = GlyphRun(209u, L"Hi」");
  wrapped.insert(wrapped.end(), row1.begin(), row1.end());
  wrapped.insert(wrapped.end(), row2.begin(), row2.end());
  core::CreationLog wrap_log = LogOf(wrapped);
  wrap_log.Record(207u, core::kCreatedControl);
  wrap_log.Record(208u, L' ');
  wrap_log.Record(211u, L'」');  // Record keeps the newest seq, as on the game thread
  assert(core::ComposeRevealedLine(wrapped.data(), wrapped.size(), 211u,
                                   wrap_log, &text, &first_seq));
  assert(text == L"鴻さん「もう、 Hi」" && first_seq == 200u);
  // A hole holding a character that failed to decode (0) or a visible
  // character that was not drawn is not bridged: only the newest row.
  core::CreationLog unknown = wrap_log;
  unknown.codes[207u & (core::kCreationLogSize - 1u)] = 0u;
  assert(core::ComposeRevealedLine(wrapped.data(), wrapped.size(), 211u,
                                   unknown, &text, &first_seq));
  assert(text == L"Hi」" && first_seq == 208u + 1u);
  unknown.codes[207u & (core::kCreationLogSize - 1u)] = L'X';
  assert(core::ComposeRevealedLine(wrapped.data(), wrapped.size(), 211u,
                                   unknown, &text, &first_seq));
  assert(text == L"Hi」");
  // A hole that fell out of the log window is unknown, never bridged.
  core::CreationLog stale = wrap_log;
  stale.newest = 211u + core::kCreationLogSize;
  assert(core::ComposeRevealedLine(wrapped.data(), wrapped.size(), 211u,
                                   stale, &text, &first_seq));
  assert(text == L"Hi」" && first_seq == 209u);

  // A creation gap of other text splits runs: only the newest run is the line.
  std::vector<core::FrameGlyph> choices = GlyphRun(94u, L"はい");
  const auto no = GlyphRun(97u, L"いいえ");
  choices.insert(choices.end(), no.begin(), no.end());
  core::CreationLog choice_log = LogOf(choices);
  choice_log.Record(96u, L'?');
  choice_log.Record(99u, L'え');
  assert(core::ComposeRevealedLine(choices.data(), choices.size(), 99u,
                                   choice_log, &text, &first_seq));
  assert(text == L"いいえ" && first_seq == 97u);

  // Whitespace only, nothing created yet, empty frames, unknown characters.
  const auto blank = GlyphRun(25u, L"\u3000 ");
  assert(!core::ComposeRevealedLine(blank.data(), blank.size(), 26u,
                                    LogOf(blank), &text, &first_seq));
  assert(!core::ComposeRevealedLine(frame.data(), frame.size(), 0u, log, &text,
                                    &first_seq));
  assert(!core::ComposeRevealedLine(frame.data(), 0u, newest, log, &text,
                                    &first_seq));
  assert(!core::ComposeRevealedLine(frame.data(), frame.size(), newest - 1u,
                                    log, &text, &first_seq));
  core::FrameGlyph bad[] = {Glyph(1u, 0xd800u, 0.0f)};
  core::CreationLog bad_log;
  bad_log.Record(1u, 0xd800u);
  assert(!core::ComposeRevealedLine(bad, 1u, 1u, bad_log, &text, &first_seq));

  // A supplementary-plane glyph keeps both UTF-16 units.
  std::vector<core::FrameGlyph> supplementary = {Glyph(4u, 0x20bb7u, 0.0f),
                                                 Glyph(5u, L'野', 27.0f)};
  assert(core::ComposeRevealedLine(supplementary.data(), 2u, 5u,
                                   LogOf(supplementary), &text, &first_seq));
  assert(text == L"\U00020BB7野" && first_seq == 4u);
}

void TestArchiveSetLeaf() {
  using fushi_voice_hook::artemis::IsArchiveSetLeaf;
  assert(IsArchiveSetLeaf(L"Amakano3.pfs"));
  assert(IsArchiveSetLeaf(L"Amakano3.pfs.000"));
  assert(IsArchiveSetLeaf(L"game.PFS.012"));
  assert(IsArchiveSetLeaf(L"a.b.pfs.1"));
  assert(!IsArchiveSetLeaf(L".pfs"));
  assert(!IsArchiveSetLeaf(L"game.pfs."));
  assert(!IsArchiveSetLeaf(L"game.pfs.0000"));
  assert(!IsArchiveSetLeaf(L"game.pfs.bak"));
  assert(!IsArchiveSetLeaf(L"game.pfsx"));
  assert(!IsArchiveSetLeaf(L"game.pf8"));
  assert(!IsArchiveSetLeaf(nullptr));
}

void TestRangeStartingAt() {
  using fushi_voice_hook::artemis::FindRangeStartingAt;
  struct Range {
    uint64_t offset;
    uint32_t size;
  };
  // Measured アマカノ3 layout: X.ogg, X.vol.csv (not a voice range), X+1.ogg.
  const Range voices[] = {{3607859u, 46049u}, {3655733u, 39997u}};
  assert(FindRangeStartingAt(voices, 2, 3607859u) == 0);
  assert(FindRangeStartingAt(voices, 2, 3655733u) == 1);
  // Streaming continuation inside a voice: not a new playback.
  assert(FindRangeStartingAt(voices, 2, 3607859u + 65536u - 46049u) == -1);
  assert(FindRangeStartingAt(voices, 2, 3607860u) == -1);
  assert(FindRangeStartingAt(voices, 2, 3653907u) == -1);
  // The sidecar read starts in the gap; its buffer running into X+1 is not a
  // read of X+1.
  assert(FindRangeStartingAt(voices, 2, 3653908u) == -1);
  assert(FindRangeStartingAt(voices, 2, 3655732u) == -1);
  assert(FindRangeStartingAt(voices, 2, 3695730u) == -1);
  assert(FindRangeStartingAt(voices, 2, 0u) == -1);
  assert(FindRangeStartingAt(voices, 0, 3607859u) == -1);
  assert(FindRangeStartingAt<Range>(nullptr, 2, 3607859u) == -1);
}

void TestLeftButtonClaim() {
  using core::kKeyStateHeld;
  using core::kKeyStateIdle;
  using core::kKeyStatePressed;
  using core::kKeyStateReleased;
  core::ClaimState claim;
  // Press on a glyph: every frame through the release edge is masked and
  // exactly one lookup is submitted.
  auto decision = core::DecideLeftButton(kKeyStatePressed, true, &claim);
  assert(decision.mask && decision.submit && claim.owned);
  decision = core::DecideLeftButton(kKeyStateHeld, true, &claim);
  assert(decision.mask && !decision.submit);
  decision = core::DecideLeftButton(kKeyStateHeld, false, &claim);
  assert(decision.mask && !decision.submit);
  decision = core::DecideLeftButton(kKeyStateReleased, false, &claim);
  assert(decision.mask && !decision.submit && !claim.owned);
  decision = core::DecideLeftButton(kKeyStateIdle, false, &claim);
  assert(!decision.mask && !decision.submit);

  // Masking a held button makes the engine re-report "pressed" on the next
  // poll; the claim keeps owning it and never submits twice.
  claim = core::ClaimState();
  decision = core::DecideLeftButton(kKeyStatePressed, true, &claim);
  assert(decision.submit);
  decision = core::DecideLeftButton(kKeyStatePressed, true, &claim);
  assert(decision.mask && !decision.submit && claim.owned);
  decision = core::DecideLeftButton(kKeyStateIdle, false, &claim);
  assert(decision.mask && !claim.owned);

  // A press that is not on a mapped glyph belongs to the game.
  claim = core::ClaimState();
  decision = core::DecideLeftButton(kKeyStatePressed, false, &claim);
  assert(!decision.mask && !decision.submit && !claim.owned);
  decision = core::DecideLeftButton(kKeyStateHeld, true, &claim);
  assert(!decision.mask && !decision.submit && !claim.owned);
}

void TestSubFrameTap() {
  core::TapLatch latch;
  // A touch tap: down and up on the same glyph, the sampler never saw it.
  core::ArmTap(&latch, true, 7u, 3u, 2u);
  assert(latch.armed);
  assert(core::ReleaseTap(&latch, 7u, true, 3u, 2u));
  assert(!latch.armed);
  // One down is at most one lookup.
  assert(!core::ReleaseTap(&latch, 7u, true, 3u, 2u));

  // A mouse press the sampler saw between down and up stays the claim's.
  core::ArmTap(&latch, true, 7u, 3u, 2u);
  assert(!core::ReleaseTap(&latch, 8u, true, 3u, 2u));
  assert(!latch.armed);

  // Released off the glyph, on another glyph, or after the model changed.
  core::ArmTap(&latch, true, 7u, 3u, 2u);
  assert(!core::ReleaseTap(&latch, 7u, false, 0u, 0u));
  core::ArmTap(&latch, true, 7u, 3u, 2u);
  assert(!core::ReleaseTap(&latch, 7u, true, 3u, 1u));
  core::ArmTap(&latch, true, 7u, 3u, 2u);
  assert(!core::ReleaseTap(&latch, 7u, true, 4u, 2u));

  // A down that is not on a glyph (or has no model) arms nothing and forgets
  // an older armed press.
  core::ArmTap(&latch, true, 7u, 3u, 2u);
  core::ArmTap(&latch, false, 7u, 3u, 2u);
  assert(!latch.armed);
  assert(!core::ReleaseTap(&latch, 7u, true, 3u, 2u));
  core::ArmTap(&latch, true, 7u, 0u, 2u);
  assert(!latch.armed);
  // An up without a down never submits.
  assert(!core::ReleaseTap(&latch, 7u, true, 3u, 2u));
  core::ArmTap(nullptr, true, 7u, 3u, 2u);
  assert(!core::ReleaseTap(nullptr, 7u, true, 3u, 2u));
}

void TestHitTest() {
  core::ModelGlyph glyphs[3];
  glyphs[0].rect = {340, 552, 27, 41};
  glyphs[0].source_index = 0u;
  glyphs[0].source_length = 1u;
  glyphs[1].rect = {367, 552, 27, 41};
  glyphs[1].source_index = 1u;
  glyphs[1].source_length = 1u;
  glyphs[2].rect = {394, 552, 27, 41};  // unmapped (whitespace)
  size_t hit = 99u;
  assert(core::HitTestModel(glyphs, 3u, 1280, 720, 1280, 720, 350, 570,
                            &hit) &&
         hit == 0u);
  assert(core::HitTestModel(glyphs, 3u, 1280, 720, 1280, 720, 367, 570,
                            &hit) &&
         hit == 1u);
  assert(!core::HitTestModel(glyphs, 3u, 1280, 720, 1280, 720, 400, 570,
                             &hit));
  assert(!core::HitTestModel(glyphs, 3u, 1280, 720, 1280, 720, 350, 540,
                             &hit));
  // Engine cursor in logical pixels, model in physical pixels (150%).
  core::ModelGlyph physical[1];
  physical[0].rect = {510, 828, 41, 62};
  physical[0].source_index = 0u;
  physical[0].source_length = 1u;
  assert(core::HitTestModel(physical, 1u, 1920, 1080, 1280, 720, 345, 560,
                            &hit) &&
         hit == 0u);
  // Overlapping candidates are ambiguous.
  core::ModelGlyph overlap[2];
  overlap[0] = glyphs[0];
  overlap[1] = glyphs[0];
  overlap[1].source_index = 1u;
  assert(!core::HitTestModel(overlap, 2u, 1280, 720, 1280, 720, 350, 570,
                             &hit));
}

// Records a run as created on `layer` during game frame `frame`.
void RecordRun(core::CreationLog* log, const std::vector<core::FrameGlyph>& run,
               uintptr_t layer, uint64_t frame) {
  for (const auto& glyph : run) {
    log->Record(glyph.seq, glyph.codepoint, layer, frame);
  }
}

// Measured on the x64 build: the name plate and the body are separate layers
// laid out in one frame; hovering the Config button creates its tooltip on a
// third layer 2400 frames later, with seqs that follow the body's directly.
void TestTooltipIsNotPartOfTheLine() {
  std::wstring text;
  uint64_t first_seq = 0u;
  const auto ui = GlyphRun(25u, L"　");
  const auto name = GlyphRun(154u, L"ミサ");
  const auto body = GlyphRun(156u, L"「さゆが手伝ってくれた」");
  const uint64_t body_last = 156u + body.size() - 1u;
  const auto tip = GlyphRun(body_last + 1u, L"コンフィグ画面を開きます。");
  const uintptr_t kUi = 0x53393de0u, kName = 0x5e5e0e70u,
                  kBody = 0x6eb5d400u, kTip = 0x6eb6b450u;
  core::CreationLog log;
  RecordRun(&log, ui, kUi, 5u);
  RecordRun(&log, name, kName, 13523u);
  RecordRun(&log, body, kBody, 13523u);

  std::vector<core::FrameGlyph> frame = ui;
  frame.insert(frame.end(), name.begin(), name.end());
  frame.insert(frame.end(), body.begin(), body.end());
  assert(core::ComposeRevealedLine(frame.data(), frame.size(), body_last, log,
                                   &text, &first_seq));
  assert(text == L"ミサ「さゆが手伝ってくれた」" && first_seq == 154u);
  // Nothing published yet, or the run is on the published layer: no overlay.
  assert(!core::OverlaysPublishedLine(frame.data(), frame.size(), kBody, 0u,
                                      0u));
  assert(!core::OverlaysPublishedLine(frame.data(), frame.size(), kBody,
                                      body_last, kBody));

  // The tooltip appears over the still-visible line: it splits off, and it
  // overlays the published line.
  RecordRun(&log, tip, kTip, 15920u);
  const uint64_t tip_last = body_last + tip.size();
  frame.insert(frame.end(), tip.begin(), tip.end());
  assert(core::ComposeRevealedLine(frame.data(), frame.size(), tip_last, log,
                                   &text, &first_seq));
  assert(text == L"コンフィグ画面を開きます。" && first_seq == body_last + 1u);
  assert(core::OverlaysPublishedLine(frame.data(), frame.size(), kTip,
                                     body_last, kBody));

  // The next message: the old line is cleared before the new one is laid out,
  // so a run on another layer is the next line, not an overlay.
  const auto next = GlyphRun(tip_last + 1u, L"アコ「おお」");
  const uintptr_t kNext = 0x6eb63b10u;
  RecordRun(&log, next, kNext, 16000u);
  std::vector<core::FrameGlyph> next_frame = ui;
  next_frame.insert(next_frame.end(), next.begin(), next.end());
  assert(core::ComposeRevealedLine(next_frame.data(), next_frame.size(),
                                   tip_last + next.size(), log, &text,
                                   &first_seq));
  assert(text == L"アコ「おお」");
  assert(!core::OverlaysPublishedLine(next_frame.data(), next_frame.size(),
                                      kNext, body_last, kBody));

  // Text appended to the message in a later frame stays one line: same layer.
  core::CreationLog append_log;
  const auto part1 = GlyphRun(300u, L"「それで");
  const auto part2 = GlyphRun(304u, L"……」");
  RecordRun(&append_log, part1, kBody, 100u);
  RecordRun(&append_log, part2, kBody, 160u);
  std::vector<core::FrameGlyph> appended = part1;
  appended.insert(appended.end(), part2.begin(), part2.end());
  assert(core::ComposeRevealedLine(appended.data(), appended.size(), 306u,
                                   append_log, &text, &first_seq));
  assert(text == L"「それで……」" && first_seq == 300u);
}

}  // namespace

int main() {
  TestResolveSitesFromStructure();
  TestFactoryCharacterDecode();
  TestGlyphCodeTable();
  TestCellBounds();
  TestProjection();
  TestOrderFrameGlyphs();
  TestSelectedSuffix();
  TestFactoryCreationCode();
  TestRevealedLine();
  TestTooltipIsNotPartOfTheLine();
  TestArchiveSetLeaf();
  TestRangeStartingAt();
  TestLeftButtonClaim();
  TestSubFrameTap();
  TestHitTest();
  std::puts("artemis_lookup_test: ok");
  return 0;
}
