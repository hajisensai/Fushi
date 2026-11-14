// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "reallive_lookup_core.h"

namespace core = fushi_voice_hook::reallive_lookup;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

// ── site resolution fails closed ────────────────────────────────────────────

class BlankImage {
 public:
  static constexpr size_t kSize = 0x10000u;
  explicit BlankImage(WORD machine, uint32_t bits) {
    base = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    assert(base != nullptr);
    std::memset(base, 0xcc, kSize);
    image.base = base;
    image.size = kSize;
    image.machine = machine;
    image.pointer_bits = bits;
    image.section_count = 1u;
    image.sections[0] = {base, kSize, 0u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
  }
  ~BlankImage() { VirtualFree(base, 0u, MEM_RELEASE); }
  BlankImage(const BlankImage&) = delete;
  BlankImage& operator=(const BlankImage&) = delete;
  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

void TestResolveSitesFailsClosed() {
  core::ImportSlots imports;
  imports.get_keyboard_state = 0x100u;
  imports.get_focus = 0x104u;
  imports.get_glyph_outline = 0x108u;
  core::Sites sites;
  {
    BlankImage x64(IMAGE_FILE_MACHINE_AMD64, 64u);
    assert(core::ResolveSites(x64.image, imports, &sites) ==
           core::SiteResult::kNotX86);
    assert(sites.glyph_join == 0u);
  }
  BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
  core::ImportSlots missing = imports;
  missing.get_glyph_outline = 0u;
  assert(core::ResolveSites(x86.image, missing, &sites) ==
         core::SiteResult::kImportsMissing);
  // No engine bytes anywhere: nothing resolves, nothing is left half-set.
  assert(core::ResolveSites(x86.image, imports, &sites) ==
         core::SiteResult::kGlyphPathMissing);
  assert(sites.glyph_join == 0u && sites.key_join == 0u &&
         sites.composite_blit == 0u);
  assert(core::ResolveSites(x86.image, imports, nullptr) !=
         core::SiteResult::kResolved);
}

// ── import slots (synthetic x86 import directory) ───────────────────────────

// Writes a PE32 header plus an import directory with one descriptor per dll
// into a blank image, every symbol imported by name.  Returns the IAT slot
// RVA of each symbol in `out_slots` (dll-major order).
struct SyntheticDll {
  const char* name;
  const char* const* symbols;
  size_t count;
};

void WriteImportTable(BlankImage* image, const SyntheticDll* dlls,
                      size_t dll_count, uint32_t* out_slots) {
  constexpr uint32_t kNtOffset = 0x80u;
  constexpr uint32_t kDirectory = 0x1000u;
  constexpr uint32_t kStrings = 0x2000u;
  constexpr uint32_t kThunks = 0x3000u;
  uint8_t* base = image->base;
  std::memset(base, 0, 0x4000u);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  dos->e_magic = IMAGE_DOS_SIGNATURE;
  dos->e_lfanew = static_cast<LONG>(kNtOffset);
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(base + kNtOffset);
  nt->Signature = IMAGE_NT_SIGNATURE;
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
  nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
  nt->OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
  nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT]
      .VirtualAddress = kDirectory;
  uint32_t strings = kStrings;
  uint32_t thunks = kThunks;
  size_t slot_index = 0u;
  auto put_string = [&](const char* text, uint32_t prefix) {
    const uint32_t at = strings;
    std::memcpy(base + strings + prefix, text, std::strlen(text) + 1u);
    strings += prefix + static_cast<uint32_t>(std::strlen(text)) + 2u;
    return at;
  };
  for (size_t d = 0u; d < dll_count; ++d) {
    auto* desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(
        base + kDirectory + d * sizeof(IMAGE_IMPORT_DESCRIPTOR));
    desc->Name = put_string(dlls[d].name, 0u);
    const uint32_t lookup = thunks;
    const uint32_t iat = thunks + 0x100u;
    thunks += 0x200u;
    desc->OriginalFirstThunk = lookup;
    desc->FirstThunk = iat;
    for (size_t s = 0u; s < dlls[d].count; ++s) {
      const uint32_t hint_name = put_string(dlls[d].symbols[s], 2u);
      std::memcpy(base + lookup + s * 4u, &hint_name, 4u);
      std::memcpy(base + iat + s * 4u, &hint_name, 4u);
      out_slots[slot_index++] = iat + static_cast<uint32_t>(s) * 4u;
    }
  }
}

void TestGlyphOutlineImportAliases() {
  const char* const kUser32[] = {"GetKeyboardState", "GetFocus"};
  uint32_t slots[8] = {};
  {
    // The canonical ANSI name.
    const char* const gdi32[] = {"SelectObject", "GetGlyphOutlineA"};
    const SyntheticDll dlls[] = {{"GDI32.dll", gdi32, 2u},
                                 {"USER32.dll", kUser32, 2u}};
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteImportTable(&x86, dlls, 2u, slots);
    const core::ImportSlots imports = core::FindLookupImportSlots(x86.image);
    assert(imports.get_glyph_outline == slots[1]);
    assert(imports.get_keyboard_state == slots[2]);
    assert(imports.get_focus == slots[3]);
  }
  {
    // A rebuilt import table binding the rasteriser by gdi32's unsuffixed
    // ANSI export name is the same entry point.
    const char* const gdi32[] = {"GetGlyphOutline", "TextOutA"};
    const SyntheticDll dlls[] = {{"gdi32.dll", gdi32, 2u},
                                 {"user32.dll", kUser32, 2u}};
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteImportTable(&x86, dlls, 2u, slots);
    const core::ImportSlots imports = core::FindLookupImportSlots(x86.image);
    assert(imports.get_glyph_outline == slots[0]);
    assert(imports.get_keyboard_state == slots[2]);
    // Exact names only: no prefix match onto a longer or other-suffix name.
    assert(core::FindImportSlotRva(x86.image, "gdi32.dll",
                                   "GetGlyphOutlineA") == 0u);
  }
  {
    // Both names present: the `A` slot is offered first.
    const char* const gdi32[] = {"GetGlyphOutline", "GetGlyphOutlineA"};
    const SyntheticDll dlls[] = {{"gdi32.dll", gdi32, 2u},
                                 {"user32.dll", kUser32, 2u}};
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteImportTable(&x86, dlls, 2u, slots);
    assert(core::FindLookupImportSlots(x86.image).get_glyph_outline ==
           slots[1]);
  }
  {
    // The wide rasteriser takes a UTF-16 code, not the engine's Shift_JIS
    // one: never accepted, so the resolver reports missing imports.
    const char* const gdi32[] = {"GetGlyphOutlineW"};
    const SyntheticDll dlls[] = {{"gdi32.dll", gdi32, 1u},
                                 {"user32.dll", kUser32, 2u}};
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteImportTable(&x86, dlls, 2u, slots);
    const core::ImportSlots imports = core::FindLookupImportSlots(x86.image);
    assert(imports.get_glyph_outline == 0u);
    assert(imports.get_keyboard_state != 0u && imports.get_focus != 0u);
    core::Sites sites;
    assert(core::ResolveSites(x86.image, imports, &sites) ==
           core::SiteResult::kImportsMissing);
  }
  {
    // The alias name under another dll is not gdi32's rasteriser.
    const char* const other[] = {"GetGlyphOutline"};
    const SyntheticDll dlls[] = {{"gdi32full.dll", other, 1u},
                                 {"user32.dll", kUser32, 2u}};
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteImportTable(&x86, dlls, 2u, slots);
    assert(core::FindLookupImportSlots(x86.image).get_glyph_outline == 0u);
  }
}

// ── site resolution on a synthetic engine image ─────────────────────────────

// Code in [0, 0x8000), data in [0x8000, 0x10000); absolute operands are
// written against a fake preferred base so the image works in x64 too.
constexpr uintptr_t kFakeBase = 0x400000u;
constexpr uint32_t kGlyphPathRva = 0x1000u;
constexpr uint32_t kEpilogueRva = 0x1100u;
constexpr uint32_t kRasterRva = 0x1400u;
constexpr uint32_t kKeyPathRva = 0x2000u;
constexpr uint32_t kFocusRva = 0x2400u;
constexpr uint32_t kCompositeRva = 0x3000u;
constexpr uint32_t kBlitRva = 0x3400u;
constexpr uint32_t kFontSizeRva = 0x9000u;
constexpr uint32_t kWindowRva = 0x9010u;
constexpr uint32_t kScreenHRva = 0x9020u;
constexpr uint32_t kScreenWRva = 0x9024u;
constexpr uint32_t kScreenBitsRva = 0x9028u;
constexpr uint32_t kGlyphSlotRva = 0x9100u;
constexpr uint32_t kKeyboardSlotRva = 0x9104u;
constexpr uint32_t kFocusSlotRva = 0x9108u;

void PutAbsolute(uint8_t* base, uint32_t at, uint32_t rva) {
  const uint32_t absolute = static_cast<uint32_t>(kFakeBase) + rva;
  std::memcpy(base + at, &absolute, 4u);
}

void PutRel32Call(uint8_t* base, uint32_t at, uint32_t target) {
  base[at] = 0xe8u;
  const int32_t rel = static_cast<int32_t>(target) -
                      static_cast<int32_t>(at + 5u);
  std::memcpy(base + at + 1u, &rel, 4u);
}

void WriteEngineSites(BlankImage* x86, const core::KeyPathShape& key) {
  uint8_t* base = x86->base;
  x86->image.absolute_base = kFakeBase;
  x86->image.section_count = 2u;
  x86->image.sections[0] = {base, 0x8000u, 0u,
                            IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
  x86->image.sections[1] = {base + 0x8000u, 0x8000u, 0x8000u,
                            IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
  // Text render path, its join (0x60 past the cache jump) and epilogue.
  std::memcpy(base + kGlyphPathRva, core::kGlyphPathBytes,
              sizeof(core::kGlyphPathBytes));
  PutAbsolute(base, kGlyphPathRva + core::kGlyphPathSizeOperand,
              kFontSizeRva);
  PutRel32Call(base, kGlyphPathRva + core::kGlyphPathRasterCall, kRasterRva);
  const uint32_t join = kGlyphPathRva + core::kGlyphPathCacheJump + 2u + 0x60u;
  std::memcpy(base + join, core::kGlyphJoinBytes,
              sizeof(core::kGlyphJoinBytes));
  PutAbsolute(base, join + core::kGlyphJoinSizeOperand, kFontSizeRva);
  std::memcpy(base + kEpilogueRva, core::kGlyphEpilogueBytes,
              sizeof(core::kGlyphEpilogueBytes));
  // Rasteriser: `call [glyph outline slot]`.
  base[kRasterRva] = 0xffu;
  base[kRasterRva + 1u] = 0x15u;
  PutAbsolute(base, kRasterRva + 2u, kGlyphSlotRva);
  // Key poll of the given shape and its Focused().
  std::memcpy(base + kKeyPathRva, key.bytes, key.size);
  PutRel32Call(base, kKeyPathRva + core::kKeyPathFocusCall, kFocusRva);
  PutAbsolute(base, kKeyPathRva + static_cast<uint32_t>(key.keyboard_operand),
              kKeyboardSlotRva);
  std::memcpy(base + kFocusRva, core::kFocusBytes, sizeof(core::kFocusBytes));
  PutAbsolute(base, kFocusRva + core::kFocusForegroundOperand, kFocusSlotRva);
  PutAbsolute(base, kFocusRva + core::kFocusWindowOperand, kWindowRva);
  // Compositor call into the blitter.
  std::memcpy(base + kCompositeRva, core::kCompositeCallBytes,
              sizeof(core::kCompositeCallBytes));
  PutAbsolute(base, kCompositeRva + core::kCompositeHeightOperand,
              kScreenHRva);
  PutAbsolute(base, kCompositeRva + core::kCompositeWidthOperand, kScreenWRva);
  PutAbsolute(base, kCompositeRva + core::kCompositeScreenOperand,
              kScreenBitsRva);
  PutRel32Call(base, kCompositeRva + core::kCompositeBlitCall, kBlitRva);
  std::memcpy(base + kBlitRva, core::kBlitPrologueBytes,
              sizeof(core::kBlitPrologueBytes));
}

core::ImportSlots SyntheticImports() {
  core::ImportSlots imports;
  imports.get_glyph_outline = kGlyphSlotRva;
  imports.get_keyboard_state = kKeyboardSlotRva;
  imports.get_focus = kFocusSlotRva;
  return imports;
}

void TestResolveSitesBothKeyPollShapes() {
  constexpr size_t kShapes =
      sizeof(core::kKeyPathShapes) / sizeof(core::kKeyPathShapes[0]);
  static_assert(kShapes == 2u, "plain and normalised key polls");
  for (size_t index = 0u; index < kShapes; ++index) {
    const core::KeyPathShape& shape = core::kKeyPathShapes[index];
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteEngineSites(&x86, shape);
    const uintptr_t base = reinterpret_cast<uintptr_t>(x86.base);
    core::Sites sites;
    assert(core::ResolveSites(x86.image, SyntheticImports(), &sites) ==
           core::SiteResult::kResolved);
    assert(sites.key_join == base + kKeyPathRva + shape.join);
    assert(sites.raster == base + kRasterRva);
    assert(sites.composite_blit == base + kBlitRva);
    assert(sites.font_size_rva == kFontSizeRva &&
           sites.window_rva == kWindowRva &&
           sites.screen_bits_rva == kScreenBitsRva &&
           sites.screen_width_rva == kScreenWRva &&
           sites.screen_height_rva == kScreenHRva);
    // The key table sits at esp+0x10 at the join in every shape: the bytes
    // right after the join read VK_UP at [esp+0x36].
    const uint8_t* after_join = x86.base + kKeyPathRva + shape.join;
    assert(after_join[0] == 0x8au || after_join[0] == 0x38u);
    assert(after_join[2] == 0x24u && after_join[3] == 0x36u);

    // The rasteriser must load the slot the imports name.
    core::ImportSlots wrong = SyntheticImports();
    wrong.get_glyph_outline = kGlyphSlotRva + 0x40u;
    assert(core::ResolveSites(x86.image, wrong, &sites) ==
           core::SiteResult::kRasterInvalid);
    // GetKeyboardState through another slot is not the key poll.
    wrong = SyntheticImports();
    wrong.get_keyboard_state = kKeyboardSlotRva + 0x40u;
    assert(core::ResolveSites(x86.image, wrong, &sites) ==
           core::SiteResult::kKeyPathMissing);
    assert(sites.key_join == 0u && sites.glyph_join == 0u);
  }
  {
    // A key poll of each shape in one image is ambiguous: nothing installs.
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteEngineSites(&x86, core::kKeyPathShapes[0]);
    const core::KeyPathShape& other = core::kKeyPathShapes[1];
    std::memcpy(x86.base + 0x5000u, other.bytes, other.size);
    PutRel32Call(x86.base, 0x5000u + core::kKeyPathFocusCall, kFocusRva);
    PutAbsolute(x86.base, 0x5000u + static_cast<uint32_t>(other.keyboard_operand),
                kKeyboardSlotRva);
    core::Sites sites;
    assert(core::ResolveSites(x86.image, SyntheticImports(), &sites) ==
           core::SiteResult::kKeyPathMissing);
  }
  {
    // The shape table's branch offsets agree with its bytes, and a
    // normalised poll whose `je` skips anything but the normalisation loop
    // (here: the plain shape's distance) is not the key poll.
    BlankImage x86(IMAGE_FILE_MACHINE_I386, 32u);
    WriteEngineSites(&x86, core::kKeyPathShapes[1]);
    const core::KeyPathShape& shape = core::kKeyPathShapes[1];
    assert(core::ShortJumpTarget(x86.base + kKeyPathRva, shape.zero_jump) ==
           shape.zero_path);
    assert(core::ShortJumpTarget(x86.base + kKeyPathRva, shape.join_jump) ==
           shape.join);
    x86.base[kKeyPathRva + shape.zero_jump + 1u] = 0x0du;
    core::Sites sites;
    assert(core::ResolveSites(x86.image, SyntheticImports(), &sites) ==
           core::SiteResult::kKeyPathMissing);
  }
}

// ── glyph codes ─────────────────────────────────────────────────────────────

void TestGlyphCodes() {
  assert(core::DecodeGlyphCode(0x82a0u) == 0x3042u);  // あ
  assert(core::DecodeGlyphCode(0x9271u) == 0x667au);  // 智
  assert(core::DecodeGlyphCode('A') == 'A');
  assert(core::DecodeGlyphCode(0xb1u) == 0xff71u);    // half-width ｱ
  assert(core::DecodeGlyphCode(0u) == 0u);
  assert(core::DecodeGlyphCode(0x0au) == 0u);         // control
  assert(core::DecodeGlyphCode(0x10000u) == 0u);      // not one code unit
  assert(core::DecodeGlyphCode(0x82ffu) == 0u);       // invalid trail byte
  assert(core::GlyphCellWidth(0x82a0u, 26) == 26);
  assert(core::GlyphCellWidth('A', 26) == 13);
  assert(core::GlyphCellWidth('A', 1) == 1);
}

// ── tracker ─────────────────────────────────────────────────────────────────

constexpr uintptr_t kScreen = 0x5000000u;
constexpr int32_t kScreenW = 800;
constexpr int32_t kScreenH = 600;
constexpr uintptr_t kText = 0x6000000u;
constexpr int32_t kTextW = 640;
constexpr int32_t kTextH = 120;
constexpr uintptr_t kStage = 0x7000000u;

core::CompositeBlit Blit(uintptr_t src, int32_t src_w, int32_t src_h,
                         int32_t dx, int32_t dy) {
  core::CompositeBlit blit;
  blit.dst = kScreen;
  blit.dst_w = kScreenW;
  blit.dst_h = kScreenH;
  blit.src = src;
  blit.src_w = src_w;
  blit.src_h = src_h;
  blit.dx = dx;
  blit.dy = dy;
  blit.clip_x0 = 0;
  blit.clip_y0 = 0;
  blit.clip_x1 = kScreenW - 1;
  blit.clip_y1 = kScreenH - 1;
  return blit;
}

// 「うん、いつもあるな」 rendered at font size 26 from pen (24, 8).
const uint16_t kLine[] = {0x8175u, 0x82a4u, 0x82f1u, 0x8141u, 0x82a2u,
                          0x82c2u, 0x82e0u, 0x82a0u, 0x82e9u, 0x82c8u,
                          0x8176u};
constexpr size_t kLineCount = sizeof(kLine) / sizeof(kLine[0]);

void RenderLine(core::GlyphTracker* tracker) {
  for (size_t index = 0u; index < kLineCount; ++index) {
    assert(tracker->RecordGlyph(kText, kTextW, kTextH, kLine[index],
                                24 + static_cast<int32_t>(index) * 26, 8, 26));
  }
}

void TestTrackerVisibility() {
  core::GlyphTracker tracker;
  // Rejects bad arguments / cells outside the surface / absurd font sizes.
  assert(!tracker.RecordGlyph(0u, kTextW, kTextH, 0x82a0u, 0, 0, 26));
  assert(!tracker.RecordGlyph(kText, kTextW, kTextH, 0x82a0u, 630, 0, 26));
  assert(!tracker.RecordGlyph(kText, kTextW, kTextH, 0x82a0u, 0, 0, 2));
  RenderLine(&tracker);
  const core::SurfaceRecord* slot = nullptr;
  for (const auto& candidate : tracker.slots()) {
    if (candidate.bits == kText) slot = &candidate;
  }
  assert(slot != nullptr && slot->count == kLineCount && !slot->placed);

  core::LineGlyph glyphs[core::kMaxSurfaceGlyphs];
  // Not composited yet: nothing is visible.
  assert(core::CollectVisibleGlyphs(*slot, glyphs, core::kMaxSurfaceGlyphs) ==
         0u);
  // Blits into another buffer never change visibility.
  core::CompositeBlit off = Blit(kText, kTextW, kTextH, 80, 460);
  off.dst = 0x1234u;
  assert(!tracker.RecordComposite(off, kScreen, kScreenW, kScreenH));

  // The compositor blits the text surface at (80, 460): every glyph shows.
  assert(tracker.RecordComposite(Blit(kText, kTextW, kTextH, 80, 460), kScreen,
                                 kScreenW, kScreenH));
  size_t count =
      core::CollectVisibleGlyphs(*slot, glyphs, core::kMaxSurfaceGlyphs);
  assert(count == kLineCount);
  assert(glyphs[0].x == 104 && glyphs[0].y == 468);
  assert(glyphs[1].codepoint == 0x3046u);  // う

  // Hiding the window re-blits the stage over the text with no text blit
  // after it: every glyph under the stage is covered.
  assert(tracker.RecordComposite(Blit(kStage, kScreenW, kScreenH, 0, 0),
                                 kScreen, kScreenW, kScreenH));
  assert(core::CollectVisibleGlyphs(*slot, glyphs, core::kMaxSurfaceGlyphs) ==
         0u);
  // A partial redraw of the text reveals only the glyphs it touches.
  core::CompositeBlit partial = Blit(kText, kTextW, kTextH, 80, 460);
  partial.clip_x0 = 104;
  partial.clip_x1 = 104 + 2 * 26 - 1;
  tracker.RecordComposite(partial, kScreen, kScreenW, kScreenH);
  count = core::CollectVisibleGlyphs(*slot, glyphs, core::kMaxSurfaceGlyphs);
  assert(count == 2u);

  // Drawing over an existing cell starts a new page in the same surface.
  assert(tracker.RecordGlyph(kText, kTextW, kTextH, 0x82a0u, 24, 8, 26));
  const core::SurfaceRecord* again = nullptr;
  for (const auto& candidate : tracker.slots()) {
    if (candidate.bits == kText) again = &candidate;
  }
  assert(again != nullptr && again->count == 1u);
}

void TestCellTrimming() {
  core::GlyphTracker tracker;
  // Letter spacing tighter than the font size: 26 px glyphs every 24 px.
  for (int32_t index = 0; index < 3; ++index) {
    assert(tracker.RecordGlyph(kText, kTextW, kTextH, 0x82a0u, index * 24, 0,
                               26));
  }
  // Not overlapping each other's origin, so all three stay on one page...
  const core::SurfaceRecord* slot = nullptr;
  for (const auto& candidate : tracker.slots()) {
    if (candidate.bits == kText) slot = &candidate;
  }
  // Neighbours overlapping by 2 px are not a page redraw (measured on the
  // real engine: 69 glyphs rendered, 65 bogus resets before this rule).
  assert(slot != nullptr && slot->count == 3u);
  assert(tracker.stats().page_resets == 0u);
  tracker.RecordComposite(Blit(kText, kTextW, kTextH, 0, 0), kScreen, kScreenW,
                          kScreenH);
  core::LineGlyph glyphs[4];
  assert(core::CollectVisibleGlyphs(*slot, glyphs, 4u) == 3u);
  assert(glyphs[0].w == 24 && glyphs[1].w == 24 && glyphs[2].w == 26);
}

// ── suffix mapping, projection, hit test ────────────────────────────────────

void TestSuffixMappingAndHitTest() {
  core::GlyphTracker tracker;
  RenderLine(&tracker);
  tracker.RecordComposite(Blit(kText, kTextW, kTextH, 80, 460), kScreen,
                          kScreenW, kScreenH);
  const core::SurfaceRecord* slot = nullptr;
  for (const auto& candidate : tracker.slots()) {
    if (candidate.bits == kText) slot = &candidate;
  }
  core::LineGlyph glyphs[core::kMaxSurfaceGlyphs];
  const size_t count =
      core::CollectVisibleGlyphs(*slot, glyphs, core::kMaxSurfaceGlyphs);

  const wchar_t kSelected[] = L"「うん、いつもあるな」";
  const size_t first = core::MapSelectedSuffix(glyphs, count, kSelected,
                                               wcslen(kSelected));
  assert(first == 0u);
  assert(glyphs[4].source_index == 4u);  // い
  // Whitespace in the selected line is ignored.
  const wchar_t kSpaced[] = L"「うん、 いつもあるな」\n";
  assert(core::MapSelectedSuffix(glyphs, count, kSpaced, wcslen(kSpaced)) ==
         0u);
  // A shorter selection maps only the suffix and leaves the prefix unmapped.
  const wchar_t kTail[] = L"あるな」";
  assert(core::MapSelectedSuffix(glyphs, count, kTail, wcslen(kTail)) == 7u);
  assert(glyphs[0].source_index == core::kNoSource);
  // Text that is not on screen maps nothing.
  const wchar_t kOther[] = L"「いいじゃないか」";
  assert(core::MapSelectedSuffix(glyphs, count, kOther, wcslen(kOther)) ==
         count);
  for (size_t index = 0u; index < count; ++index) {
    assert(glyphs[index].source_index == core::kNoSource);
  }
  const wchar_t kLonger[] = L"朋也「うん、いつもあるな」";
  assert(core::MapSelectedSuffix(glyphs, count, kLonger, wcslen(kLonger)) ==
         count);

  assert(core::MapSelectedSuffix(glyphs, count, kSelected,
                                 wcslen(kSelected)) == 0u);
  size_t hit = 0u;
  // Centre of い (index 4): screen x 104 + 4*26 .. +26, y 468..494.
  assert(core::HitTestLine(glyphs, count, 104 + 4 * 26 + 13, 480, &hit));
  assert(hit == 4u);
  assert(!core::HitTestLine(glyphs, count, 10, 10, &hit));
  assert(!core::HitTestLine(glyphs, count, 104 + 4 * 26 + 13, 400, &hit));

  core::PixelRect rect;
  // 800x600 presented 1:1 on a 1600x1200 DPI-stretched client.
  assert(core::ProjectCell(glyphs[4], kScreenW, kScreenH, 1600, 1200, &rect));
  assert(rect.x == 416 && rect.y == 936 && rect.w == 52 && rect.h == 52);
  // Exclusive fullscreen at the game's own resolution: identity.
  assert(core::ProjectCell(glyphs[4], kScreenW, kScreenH, 800, 600, &rect));
  assert(rect.x == 208 && rect.y == 468 && rect.w == 26 && rect.h == 26);
  core::LineGlyph outside = glyphs[4];
  outside.x = 790;
  assert(!core::ProjectCell(outside, kScreenW, kScreenH, 800, 600, &rect));
  assert(!core::ProjectCell(glyphs[4], 0, kScreenH, 800, 600, &rect));
}

// ── presented-pixel proof ───────────────────────────────────────────────────

void TestPresentationProof() {
  const int32_t sw = 64, sh = 32, cw = 128, ch = 64;
  std::vector<uint32_t> surface(static_cast<size_t>(sw) * sh, 0u);
  std::vector<uint32_t> screen(static_cast<size_t>(cw) * ch, 0xff203040u);
  // An 8x8 opaque glyph at surface (4, 4), placed with origin (10, 20).
  for (int32_t y = 4; y < 12; ++y) {
    for (int32_t x = 4; x < 12; ++x) {
      surface[static_cast<size_t>(y) * sw + x] = 0xffeeddccu;
    }
  }
  auto count = [&]() {
    return core::CountPresentedPixels(surface.data(), sw, sh, screen.data(),
                                      cw, ch, 10, 20, 4, 4, 8, 8);
  };
  assert(!core::GlyphPresented(count()));  // not revealed yet
  for (int32_t y = 0; y < 8; ++y) {
    for (int32_t x = 0; x < 8; ++x) {
      screen[static_cast<size_t>(24 + y) * cw + 14 + x] = 0x00eeddccu;
    }
  }
  const core::PresentationCount shown = count();
  assert(shown.opaque == 64u && shown.matched == 64u);
  assert(core::GlyphPresented(shown));
  // An overlay (e.g. a menu) over part of the glyph breaks the proof.
  for (int32_t x = 0; x < 8; ++x) {
    screen[static_cast<size_t>(24) * cw + 14 + x] = 0xff000000u;
    screen[static_cast<size_t>(25) * cw + 14 + x] = 0xff000000u;
  }
  assert(!core::GlyphPresented(count()));
  // Out-of-range geometry counts nothing.
  assert(core::CountPresentedPixels(surface.data(), sw, sh, screen.data(), cw,
                                    ch, 120, 20, 4, 4, 8, 8)
             .opaque == 0u);
}

// ── click claim ─────────────────────────────────────────────────────────────

void TestClaimReducer() {
  core::ClaimState claim;
  // Idle, then a press on a glyph: claimed and masked until release.
  core::ClaimDecision d = core::DecideLeftButton(0x00u, false, &claim);
  assert(!d.mask && !d.submit);
  assert(core::IsFreshPress(0x80u, claim));
  d = core::DecideLeftButton(0x80u, true, &claim);
  assert(d.fresh_press && d.mask && d.submit && claim.owned);
  d = core::DecideLeftButton(0x81u, true, &claim);  // held
  assert(!d.fresh_press && d.mask && !d.submit);
  d = core::DecideLeftButton(0x00u, true, &claim);  // released
  assert(!d.mask && !claim.owned);
  // A press that is not eligible is left alone for the whole press.
  d = core::DecideLeftButton(0x80u, false, &claim);
  assert(d.fresh_press && !d.mask && !d.submit && !claim.owned);
  d = core::DecideLeftButton(0x80u, true, &claim);  // eligibility changes mid-press
  assert(!d.fresh_press && !d.mask && !d.submit);
  d = core::DecideLeftButton(0x00u, true, &claim);
  assert(!d.mask);
  assert(!core::DecideLeftButton(0x80u, true, nullptr).mask);
}

}  // namespace

int main() {
  TestResolveSitesFailsClosed();
  TestGlyphOutlineImportAliases();
  TestResolveSitesBothKeyPollShapes();
  TestGlyphCodes();
  TestTrackerVisibility();
  TestCellTrimming();
  TestSuffixMappingAndHitTest();
  TestPresentationProof();
  TestClaimReducer();
  std::puts("reallive_lookup_test: ok");
  return 0;
}
