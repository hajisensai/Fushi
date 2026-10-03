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
  TestGlyphCodes();
  TestTrackerVisibility();
  TestCellTrimming();
  TestSuffixMappingAndHitTest();
  TestPresentationProof();
  TestClaimReducer();
  std::puts("reallive_lookup_test: ok");
  return 0;
}
