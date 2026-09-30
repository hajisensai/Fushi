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

namespace core = fushi_voice_hook::artemis_lookup;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

// ── synthetic PE image ──────────────────────────────────────────────────────
//
// One committed region split into an executable "code" section and a
// read-only "data" section.  Every engine proof is laid out the way the real
// executable arranges it, with the relative operands pointing at the fake
// targets, so ResolveSites is exercised end to end without a game binary.
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

  SyntheticImage() {
    base = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    assert(base != nullptr);
    std::memset(base, 0xcc, kSize);
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

  void WriteAll() {
    std::memcpy(base + kFactory, core::kGlyphFactoryBytes,
                sizeof(core::kGlyphFactoryBytes));
    WriteRel32(kFactory + core::kGlyphFactoryCtorCallOffset + 1u, kCtor);
    WriteRel32(kFactory + 40u, 0x7000u);  // operator new, unchecked

    // Constructor: vtable lea, cell zeroing and the SJIS width test.
    std::memcpy(base + kCtor + 0x90u, core::kCtorVtableBytes,
                sizeof(core::kCtorVtableBytes));
    WriteRel32(kCtor + 0x90u + 1u, 0x7100u);
    WriteRel32(kCtor + 0x90u + core::kCtorVtableLeaOffset + 3u, kVtable);
    std::memcpy(base + kCtor + 0xc0u, core::kCtorCellBytes,
                sizeof(core::kCtorCellBytes));
    std::memcpy(base + kCtor + 0x170u, core::kCtorMultibyteBytes,
                sizeof(core::kCtorMultibyteBytes));

    std::memcpy(base + kDrawSibling, core::kGlyphDrawBytes,
                sizeof(core::kGlyphDrawBytes));
    base[kDrawSibling + core::kGlyphDrawForwardSlotByte] = 0x10u;
    std::memcpy(base + kDraw, core::kGlyphDrawBytes,
                sizeof(core::kGlyphDrawBytes));
    SetVtableSlot(core::kGlyphDrawSiblingSlot, kDrawSibling);
    SetVtableSlot(core::kGlyphDrawSlot, kDraw);

    std::memcpy(base + kUpdate, core::kInputUpdateBytes,
                sizeof(core::kInputUpdateBytes));
    std::memcpy(base + kCursor, core::kCursorMappingBytes,
                sizeof(core::kCursorMappingBytes));
  }

  void SetVtableSlot(size_t slot, size_t target) {
    const uintptr_t absolute = reinterpret_cast<uintptr_t>(base + target);
    std::memcpy(base + kVtable + slot * sizeof(uintptr_t), &absolute,
                sizeof(absolute));
  }

  uintptr_t At(size_t offset) const {
    return reinterpret_cast<uintptr_t>(base + offset);
  }

  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

void TestResolveSitesFromStructure() {
  {
    SyntheticImage fixture;
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kResolved);
    assert(sites.glyph_factory == fixture.At(SyntheticImage::kFactory));
    assert(sites.glyph_ctor == fixture.At(SyntheticImage::kCtor));
    assert(sites.glyph_vtable == fixture.At(SyntheticImage::kVtable));
    assert(sites.glyph_draw == fixture.At(SyntheticImage::kDraw));
    assert(sites.input_update == fixture.At(SyntheticImage::kUpdate));
  }
  {
    // An x86 image never matches the x64 ABI proofs.
    SyntheticImage fixture;
    fixture.image.machine = IMAGE_FILE_MACHINE_I386;
    fixture.image.pointer_bits = 32u;
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kNotX64);
    assert(sites.glyph_draw == 0u);
  }
  {
    // Two factories: ambiguous, fail closed.
    SyntheticImage fixture;
    std::memcpy(fixture.base + 0x5000u, core::kGlyphFactoryBytes,
                sizeof(core::kGlyphFactoryBytes));
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kFactoryMissing);
    assert(sites.glyph_factory == 0u);
  }
  {
    // The factory must call a constructor that measures one multibyte char.
    SyntheticImage fixture;
    std::memset(fixture.base + SyntheticImage::kCtor + 0x170u, 0x90,
                sizeof(core::kCtorMultibyteBytes));
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kCtorInvalid);
  }
  {
    // A cell field at a different offset is a different layout.
    SyntheticImage fixture;
    fixture.base[SyntheticImage::kCtor + 0xc0u + 3u] = 0x80u;
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kCtorInvalid);
  }
  {
    // A vtable in an executable section is not a vtable.
    SyntheticImage fixture;
    fixture.WriteRel32(SyntheticImage::kCtor + 0x90u +
                           core::kCtorVtableLeaOffset + 3u,
                       0x4000u);
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kVtableInvalid);
  }
  {
    // Slot 4 must forward the draw pass (+0x18) and slot 3 its sibling.
    SyntheticImage fixture;
    fixture.SetVtableSlot(core::kGlyphDrawSlot, SyntheticImage::kDrawSibling);
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kDrawInvalid);
  }
  {
    SyntheticImage fixture;
    fixture.SetVtableSlot(core::kGlyphDrawSiblingSlot, SyntheticImage::kDraw);
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kDrawInvalid);
  }
  {
    // A different key-state array offset is not the measured Input::Update.
    SyntheticImage fixture;
    fixture.base[SyntheticImage::kUpdate + 59u] = 0x20u;  // lea rsi,[rcx+0x20]
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kUpdateMissing);
  }
  {
    // Without the cursor mapping the projection offsets are unproven.
    SyntheticImage fixture;
    fixture.base[SyntheticImage::kCursor + 63u] = 0x18u;  // subss [rbx+0x18]
    core::Sites sites;
    assert(core::ResolveSites(fixture.image, &sites) ==
           core::SiteResult::kCursorMappingMissing);
    assert(sites.glyph_factory == 0u);
  }
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

}  // namespace

int main() {
  TestResolveSitesFromStructure();
  TestFactoryCharacterDecode();
  TestGlyphCodeTable();
  TestCellBounds();
  TestProjection();
  TestOrderFrameGlyphs();
  TestSelectedSuffix();
  TestLeftButtonClaim();
  TestHitTest();
  std::puts("artemis_lookup_test: ok");
  return 0;
}
