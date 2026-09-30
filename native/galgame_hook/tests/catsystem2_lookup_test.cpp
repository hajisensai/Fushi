// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "catsystem2_lookup_core.h"

namespace core = fushi_voice_hook::catsystem2_lookup;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

// ── synthetic x86 image ─────────────────────────────────────────────────────

constexpr uintptr_t kAbsoluteBase = 0x00400000u;

class SyntheticImage {
 public:
  static constexpr size_t kSize = 0x10000u;
  explicit SyntheticImage(WORD machine = IMAGE_FILE_MACHINE_I386,
                          uint32_t bits = 32u) {
    base = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    assert(base != nullptr);
    std::memset(base, 0xcc, kSize);
    image.base = base;
    image.size = kSize;
    image.absolute_base = kAbsoluteBase;
    image.machine = machine;
    image.pointer_bits = bits;
    image.section_count = 1u;
    image.sections[0] = {base, kSize, 0u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
  }
  ~SyntheticImage() { VirtualFree(base, 0u, MEM_RELEASE); }
  SyntheticImage(const SyntheticImage&) = delete;
  SyntheticImage& operator=(const SyntheticImage&) = delete;

  void Put(size_t rva, const uint8_t* bytes, size_t size) {
    assert(rva + size <= kSize);
    std::memcpy(base + rva, bytes, size);
  }
  void Rel32(size_t at, size_t target) {  // `e8 rel32` at `at`
    base[at] = 0xe8u;
    const int32_t rel = static_cast<int32_t>(static_cast<intptr_t>(target) -
                                             static_cast<intptr_t>(at + 5u));
    std::memcpy(base + at + 1u, &rel, 4u);
  }
  void CallSlot(size_t at, size_t slot_rva) {  // `ff 15 [abs]`
    base[at] = 0xffu;
    base[at + 1u] = 0x15u;
    const uint32_t absolute = static_cast<uint32_t>(kAbsoluteBase + slot_rva);
    std::memcpy(base + at + 2u, &absolute, 4u);
  }
  uintptr_t At(size_t rva) const {
    return reinterpret_cast<uintptr_t>(base + rva);
  }

  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

// Layout of the synthetic engine.
constexpr size_t kPage = 0x1000u;           // ClearPage; RenderChar at +64
constexpr size_t kRender = kPage + core::kPageRenderOffset;
constexpr size_t kCharImage = 0x1400u;
constexpr size_t kRaster = 0x1600u;
constexpr size_t kUpdate = 0x2000u;
constexpr size_t kReveal = 0x2100u;
constexpr size_t kSync = 0x2300u;
constexpr size_t kLayerQuery = 0x3000u;
constexpr size_t kScreenQuery = 0x3100u;
constexpr size_t kSceneVisible = 0x3200u;
constexpr size_t kSceneFind = 0x3300u;
constexpr size_t kInput = 0x4000u;
constexpr size_t kSlotGlyph = 0xf000u;
constexpr size_t kSlotSetCapture = 0xf004u;
constexpr size_t kSlotReleaseCapture = 0xf008u;
constexpr size_t kSlotWindowFromPoint = 0xf00cu;
constexpr size_t kSlotForeground = 0xf010u;

core::ImportSlots Imports() {
  core::ImportSlots imports;
  imports.get_glyph_outline = kSlotGlyph;
  imports.set_capture = kSlotSetCapture;
  imports.release_capture = kSlotReleaseCapture;
  imports.window_from_point = kSlotWindowFromPoint;
  imports.get_foreground_window = kSlotForeground;
  return imports;
}

void BuildEngine(SyntheticImage* img) {
  // ClearPage + RenderChar prologue, record pen / record char bytes.
  img->Put(kPage, core::kPageBytes, sizeof(core::kPageBytes));
  img->Rel32(kPage + 13u, 0x1800u);  // layout reset (any code)
  img->Rel32(kPage + core::kPageFillCall, 0x1810u);
  img->Put(kRender + core::kRecordPenOffset, core::kRecordPenBytes,
           sizeof(core::kRecordPenBytes));
  img->Put(kRender + core::kRecordCharOffset, core::kRecordCharBytes,
           sizeof(core::kRecordCharBytes));
  img->Rel32(kRender + core::kRecordCharOffset + core::kRecordCharImageCall,
             kCharImage);
  // GetCharImage: two calls into the rasteriser, which calls
  // GetGlyphOutlineA through its slot (the entry itself may be patched).
  img->Rel32(kCharImage + 0x20u, kRaster);
  img->Rel32(kCharImage + 0x60u, kRaster);
  img->Rel32(kCharImage + 0x90u, 0x1820u);  // unrelated helper
  img->CallSlot(kRaster + 0x40u, kSlotGlyph);
  // Window::Update → reveal (renders through RenderChar), sync (screen copy).
  img->Put(kUpdate, core::kUpdateBytes, sizeof(core::kUpdateBytes));
  img->Rel32(kUpdate + 14u, 0x1830u);
  img->Rel32(kUpdate + core::kUpdateRevealCall, kReveal);
  img->Rel32(kUpdate + core::kUpdateSyncCall, kSync);
  img->Rel32(kReveal + 0x40u, kRender);
  img->Put(kSync + 0x30u, core::kSyncScreenBytes,
           sizeof(core::kSyncScreenBytes));
  // Layer query chain.
  img->Put(kLayerQuery, core::kLayerQueryBytes,
           sizeof(core::kLayerQueryBytes));
  img->Rel32(kLayerQuery + core::kLayerQueryCall, kScreenQuery);
  img->Put(kScreenQuery, core::kScreenQueryBytes,
           sizeof(core::kScreenQueryBytes));
  img->Rel32(kScreenQuery + 21u, 0x1840u);
  img->Rel32(kScreenQuery + core::kScreenQuerySceneCall, kSceneVisible);
  img->Put(kSceneVisible, core::kSceneVisibleBytes,
           sizeof(core::kSceneVisibleBytes));
  img->Rel32(kSceneVisible + core::kSceneVisibleFindCall, kSceneFind);
  img->Put(kSceneVisible + 0x50u, core::kNodeVisibleReadBytes,
           sizeof(core::kNodeVisibleReadBytes));
  img->Put(kSceneFind, core::kSceneFindBytes, sizeof(core::kSceneFindBytes));
  img->Put(kSceneFind + 0x70u, core::kNodeIdCompareBytes,
           sizeof(core::kNodeIdCompareBytes));
  // Input::Handle with its capture bookkeeping imports.
  img->Put(kInput, core::kInputBytes, sizeof(core::kInputBytes));
  img->CallSlot(kInput + 0x100u, kSlotReleaseCapture);
  img->CallSlot(kInput + 0x300u, kSlotWindowFromPoint);
  img->CallSlot(kInput + 0x420u, kSlotSetCapture);
}

void TestResolveSites() {
  core::Sites sites;
  {
    SyntheticImage x64(IMAGE_FILE_MACHINE_AMD64, 64u);
    BuildEngine(&x64);
    assert(core::ResolveSites(x64.image, Imports(), &sites) ==
           core::SiteResult::kNotX86);
    assert(sites.render_char == 0u);
  }
  {
    SyntheticImage blank;
    core::ImportSlots missing = Imports();
    missing.get_foreground_window = 0u;
    assert(core::ResolveSites(blank.image, missing, &sites) ==
           core::SiteResult::kImportsMissing);
    assert(core::ResolveSites(blank.image, Imports(), &sites) ==
           core::SiteResult::kPageMissing);
    assert(sites.clear_page == 0u && sites.input_handler == 0u);
    assert(core::ResolveSites(blank.image, Imports(), nullptr) !=
           core::SiteResult::kResolved);
  }
  SyntheticImage img;
  BuildEngine(&img);
  assert(core::ResolveSites(img.image, Imports(), &sites) ==
         core::SiteResult::kResolved);
  assert(sites.clear_page == img.At(kPage));
  assert(sites.render_char == img.At(kRender));
  assert(sites.char_image == img.At(kCharImage));
  assert(sites.rasteriser == img.At(kRaster));
  assert(sites.window_update == img.At(kUpdate));
  assert(sites.input_handler == img.At(kInput));

  // Several parts share the base-class layer query; copies that agree on the
  // screen query are one proof, not an ambiguity.
  img.Put(0x5800u, core::kLayerQueryBytes, sizeof(core::kLayerQueryBytes));
  img.Rel32(0x5800u + core::kLayerQueryCall, kScreenQuery);
  assert(core::ResolveSites(img.image, Imports(), &sites) ==
         core::SiteResult::kResolved);
}

// Each structural proof, broken alone, installs nothing.
void TestResolveSitesEachProofFailsClosed() {
  struct Breaker {
    void (*apply)(SyntheticImage*);
    core::SiteResult expected;
  };
  const Breaker breakers[] = {
      // A second ClearPage/RenderChar pair is ambiguous.
      {[](SyntheticImage* img) {
         img->Put(0x5000u, core::kPageBytes, sizeof(core::kPageBytes));
       },
       core::SiteResult::kPageMissing},
      // Record offsets moved.
      {[](SyntheticImage* img) {
         img->base[kRender + core::kRecordPenOffset + 9u] = 0x18u;
       },
       core::SiteResult::kRecordInvalid},
      {[](SyntheticImage* img) {
         img->base[kRender + core::kRecordCharOffset + 2u] = 0x20u;
       },
       core::SiteResult::kRecordInvalid},
      // GetCharImage reaches the rasteriser only once.
      {[](SyntheticImage* img) { std::memset(img->base + kCharImage + 0x60u,
                                             0xcc, 5u); },
       core::SiteResult::kRasteriserInvalid},
      // The rasteriser does not call GetGlyphOutlineA.
      {[](SyntheticImage* img) {
         img->CallSlot(kRaster + 0x40u, kSlotSetCapture);
       },
       core::SiteResult::kRasteriserInvalid},
      // Two different rasterisers.
      {[](SyntheticImage* img) {
         img->Rel32(kCharImage + 0x60u, 0x1700u);
         img->CallSlot(0x1700u + 0x40u, kSlotGlyph);
       },
       core::SiteResult::kRasteriserInvalid},
      // Update missing.
      {[](SyntheticImage* img) { img->base[kUpdate + 52u] = 0xa8u; },
       core::SiteResult::kUpdateMissing},
      // The reveal loop does not render through RenderChar.
      {[](SyntheticImage* img) { std::memset(img->base + kReveal + 0x40u,
                                             0xcc, 5u); },
       core::SiteResult::kRevealInvalid},
      // SyncLayer does not hand the page to screen+0x68.
      {[](SyntheticImage* img) { img->base[kSync + 0x32u] = 0x6cu; },
       core::SiteResult::kSyncInvalid},
      // Layer query missing.
      {[](SyntheticImage* img) { img->base[kLayerQuery + 8u] = 0x08u; },
       core::SiteResult::kLayerQueryMissing},
      // A second copy of the part method calling another screen query.
      {[](SyntheticImage* img) {
         img->Put(0x5800u, core::kLayerQueryBytes,
                  sizeof(core::kLayerQueryBytes));
         img->Rel32(0x5800u + core::kLayerQueryCall, 0x1850u);
       },
       core::SiteResult::kLayerQueryMissing},
      // Scene list layout differs.
      {[](SyntheticImage* img) { img->base[kScreenQuery + 37u] = 0x0cu; },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img) { img->base[kSceneVisible + 32u] = 0x18u; },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img) { img->base[kSceneVisible + 0x52u] = 0x10u; },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img) { img->base[kSceneFind + 0x72u] = 0x0cu; },
       core::SiteResult::kSceneInvalid},
      // Input handler missing / without capture imports.
      {[](SyntheticImage* img) { img->base[kInput + 13u] = 0x03u; },
       core::SiteResult::kInputMissing},
      {[](SyntheticImage* img) {
         std::memset(img->base + kInput + 0x420u, 0xcc, 6u);
       },
       core::SiteResult::kInputImportsInvalid},
  };
  for (const Breaker& breaker : breakers) {
    SyntheticImage img;
    BuildEngine(&img);
    breaker.apply(&img);
    core::Sites sites;
    sites.render_char = 1u;
    const auto result = core::ResolveSites(img.image, Imports(), &sites);
    if (result != breaker.expected) {
      std::fprintf(stderr, "expected %u got %u\n",
                   static_cast<unsigned>(breaker.expected),
                   static_cast<unsigned>(result));
    }
    assert(result == breaker.expected);
    assert(sites.render_char == 0u && sites.clear_page == 0u &&
           sites.window_update == 0u && sites.input_handler == 0u);
  }
}

// ── glyph codes ─────────────────────────────────────────────────────────────

void TestGlyphCodes() {
  assert(core::DecodeGlyphCode(0x82a0u) == 0x3042u);  // あ
  assert(core::DecodeGlyphCode(0x8a88u) == 0x6d3bu);  // 活
  assert(core::DecodeGlyphCode('A') == 'A');
  assert(core::DecodeGlyphCode(0xb1u) == 0xff71u);    // half-width ｱ
  assert(core::DecodeGlyphCode(0u) == 0u);
  assert(core::DecodeGlyphCode(0x0au) == 0u);
  assert(core::DecodeGlyphCode(0x10000u) == 0u);
  assert(core::DecodeGlyphCode(0x82ffu) == 0u);
  assert(core::GlyphCellWidth(0x82a0u, 26, 26) == 26);
  assert(core::GlyphCellWidth(0x82a0u, 24, 26) == 24);  // engine advance
  assert(core::GlyphCellWidth('A', 0, 26) == 13);       // no advance
  assert(core::GlyphCellWidth('A', 99, 26) == 13);      // absurd advance
}

// ── placement ───────────────────────────────────────────────────────────────

constexpr int32_t kPageW = 806;
constexpr int32_t kPageH = 121;
constexpr int32_t kTextLayer = 15;

core::LayerNode Node(int32_t id, bool visible, float x, float y, float w,
                     float h) {
  core::LayerNode node;
  node.id = id;
  node.visible = visible;
  node.has_sprite = true;
  node.x = x;
  node.y = y;
  node.w = w;
  node.h = h;
  if (visible) {
    node.box[0] = static_cast<int32_t>(x) - 1;
    node.box[1] = static_cast<int32_t>(y) - 1;
    node.box[2] = static_cast<int32_t>(x + w);
    node.box[3] = static_cast<int32_t>(y + h);
  }
  return node;
}

// The measured dialogue scene: backgrounds, the window frame, the text page
// at (293, 583) and the name plate after it (not overlapping).
std::vector<core::LayerNode> DialogueScene() {
  std::vector<core::LayerNode> nodes;
  nodes.push_back(Node(7, false, 0, 0, 1280, 720));
  nodes.push_back(Node(29, true, 512, 288, 1536, 850));
  nodes.push_back(Node(27, true, 0, 420, 1280, 300));
  nodes.push_back(Node(28, true, 0, 439, 293, 281));
  nodes.push_back(Node(kTextLayer, true, 293, 583, kPageW, kPageH));
  nodes.push_back(Node(16, true, 251, 541, 439, 40));
  core::LayerNode none;
  none.id = 4;
  nodes.push_back(none);  // no sprite
  return nodes;
}

void TestPlacement() {
  auto nodes = DialogueScene();
  auto placement = core::ResolvePlacement(nodes.data(), nodes.size(),
                                          kTextLayer, kPageW, kPageH);
  assert(placement.valid && placement.visible);
  assert(placement.x == 293 && placement.y == 583);
  assert(placement.cover_count == 0u);  // name plate ends at y 581

  // Hidden window: valid but not visible.
  nodes[4].visible = false;
  placement = core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                     kPageW, kPageH);
  assert(placement.valid && !placement.visible);

  // System menu drawn after the text covers it.
  nodes = DialogueScene();
  nodes.push_back(Node(81, true, 0, 0, 1280, 720));
  placement = core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                     kPageW, kPageH);
  assert(placement.visible && placement.cover_count == 1u);
  assert(placement.covers[0].x0 == 293 && placement.covers[0].y1 == 704);

  // A layer drawn *before* the text never covers it.
  nodes = DialogueScene();
  nodes.insert(nodes.begin() + 1, Node(81, true, 0, 0, 1280, 720));
  placement = core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                     kPageW, kPageH);
  assert(placement.visible && placement.cover_count == 0u);

  // Fail closed: unknown id, duplicate id, page/sprite size mismatch,
  // fractional (scaled) position, inconsistent drawn box.
  nodes = DialogueScene();
  assert(!core::ResolvePlacement(nodes.data(), nodes.size(), 99, kPageW,
                                 kPageH).valid);
  nodes.push_back(Node(kTextLayer, true, 0, 0, kPageW, kPageH));
  assert(!core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                 kPageW, kPageH).valid);
  nodes = DialogueScene();
  assert(!core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer, 800,
                                 kPageH).valid);
  nodes[4].x = 293.5f;
  assert(!core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                 kPageW, kPageH).valid);
  nodes = DialogueScene();
  nodes[4].box[2] += 40;  // drawn wider than its size: scaled
  assert(!core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                 kPageW, kPageH).valid);
  assert(!core::ResolvePlacement(nullptr, 0u, kTextLayer, kPageW, kPageH)
              .valid);

  // Too many covers: overflow (caller treats the page as hidden).
  nodes = DialogueScene();
  for (int32_t i = 0; i < 10; ++i) {
    nodes.push_back(Node(100 + i, true, 300.0f + 20 * i, 600, 10, 10));
  }
  placement = core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                     kPageW, kPageH);
  assert(placement.covers_overflow);

  int32_t w = 0, h = 0;
  assert(core::DesignSize(1280, 720, 1280, 720, &w, &h) && w == 1280 &&
         h == 720);
  assert(!core::DesignSize(1280, 720, 1920, 1080, &w, &h));
  assert(!core::DesignSize(0, 0, 0, 0, &w, &h));
}

// ── tracker ─────────────────────────────────────────────────────────────────

constexpr uintptr_t kRenderer = 0x6000000u;
constexpr uintptr_t kNameRenderer = 0x6100000u;

// 「そんな彼女のことを人は「活動家」と呼ぶ。」 in the measured layout: font
// size 26, pen advance 26, first row at (0, 8).
const uint16_t kLine[] = {0x82bbu, 0x82f1u, 0x82c8u, 0x94deu, 0x8f97u,
                          0x82ccu, 0x82b1u, 0x82c6u, 0x82f0u, 0x906cu,
                          0x82cdu, 0x8175u, 0x8a88u, 0x93aeu, 0x89c6u,
                          0x8176u, 0x82c6u, 0x8cc4u, 0x82d4u, 0x8142u};
constexpr size_t kLineCount = sizeof(kLine) / sizeof(kLine[0]);
const wchar_t kLineText[] =
    L"そんな彼女のことを人は「活動家」と呼ぶ。";

void RenderLine(core::GlyphTracker* tracker, size_t count = kLineCount) {
  for (size_t index = 0u; index < count; ++index) {
    assert(tracker->RecordGlyph(kRenderer, kPageW, kPageH, kLine[index],
                                static_cast<int32_t>(index) * 26, 8, 26, 26));
  }
}

const core::SurfaceRecord* Slot(const core::GlyphTracker& tracker,
                                uintptr_t renderer) {
  for (const auto& candidate : tracker.slots()) {
    if (candidate.renderer == renderer) return &candidate;
  }
  return nullptr;
}

core::Placement VisiblePlacement() {
  auto nodes = DialogueScene();
  return core::ResolvePlacement(nodes.data(), nodes.size(), kTextLayer,
                                kPageW, kPageH);
}

void TestTracker() {
  core::GlyphTracker tracker;
  assert(!tracker.RecordGlyph(0u, kPageW, kPageH, 0x82a0u, 0, 8, 26, 26));
  assert(!tracker.RecordGlyph(kRenderer, kPageW, kPageH, 0x82a0u, 800, 8, 26,
                              26));  // cell outside the page
  assert(!tracker.RecordGlyph(kRenderer, kPageW, kPageH, 0x82a0u, 0, 8, 26,
                              2));   // absurd size
  assert(!tracker.RecordGlyph(kRenderer, 0, kPageH, 0x82a0u, 0, 8, 26, 26));
  RenderLine(&tracker);
  const core::SurfaceRecord* slot = Slot(tracker, kRenderer);
  assert(slot != nullptr && slot->count == kLineCount && !slot->bound);

  // Unbound / unplaced surfaces publish nothing.
  core::LineGlyph lines[core::kMaxSurfaceGlyphs];
  assert(core::CollectVisibleGlyphs(*slot, lines, core::kMaxSurfaceGlyphs) ==
         0u);
  const uint64_t before_bind = tracker.version();
  tracker.Bind(kRenderer, kTextLayer);
  assert(tracker.version() != before_bind);
  assert(core::CollectVisibleGlyphs(*slot, lines, core::kMaxSurfaceGlyphs) ==
         0u);
  tracker.SetPlacement(kRenderer, VisiblePlacement());
  size_t count =
      core::CollectVisibleGlyphs(*slot, lines, core::kMaxSurfaceGlyphs);
  assert(count == kLineCount);
  assert(lines[0].x == 293 && lines[0].y == 591 && lines[0].w == 26 &&
         lines[0].h == 26 && lines[0].codepoint == 0x305du);
  assert(lines[19].x == 293 + 19 * 26);

  // An unchanged placement does not bump the version; a changed one does.
  const uint64_t placed = tracker.version();
  tracker.SetPlacement(kRenderer, VisiblePlacement());
  assert(tracker.version() == placed);

  // A cover over the start of the line hides exactly those glyphs.
  auto nodes = DialogueScene();
  nodes.push_back(Node(90, true, 293, 591, 52, 26));
  tracker.SetPlacement(kRenderer,
                       core::ResolvePlacement(nodes.data(), nodes.size(),
                                              kTextLayer, kPageW, kPageH));
  assert(tracker.version() != placed);
  count = core::CollectVisibleGlyphs(*slot, lines, core::kMaxSurfaceGlyphs);
  // The cover box is {292, 590, 345, 617}: glyphs 0..1 (x < 345) and glyph
  // 2 (x 345 is outside; 344 is inside the cell of glyph 1) → 2 hidden.
  assert(count == kLineCount - 2u);

  // Hidden window: nothing.
  nodes = DialogueScene();
  nodes[4].visible = false;
  tracker.SetPlacement(kRenderer,
                       core::ResolvePlacement(nodes.data(), nodes.size(),
                                              kTextLayer, kPageW, kPageH));
  assert(core::CollectVisibleGlyphs(*slot, lines, core::kMaxSurfaceGlyphs) ==
         0u);

  // ClearPage forgets the page; a second renderer is independent.
  tracker.SetPlacement(kRenderer, VisiblePlacement());
  assert(tracker.RecordGlyph(kNameRenderer, 439, 40, 0x8d4bu, 0, 6, 26, 26));
  const uint64_t before_clear = tracker.version();
  tracker.ClearPage(kRenderer);
  assert(tracker.version() != before_clear);
  assert(Slot(tracker, kRenderer)->count == 0u);
  assert(Slot(tracker, kNameRenderer)->count == 1u);
  assert(tracker.stats().page_clears == 1u);

  // Defensive: drawing mostly over an existing glyph starts a new page, a
  // few pixels of neighbour overlap (tight pen advance) does not.
  RenderLine(&tracker, 3u);
  assert(tracker.RecordGlyph(kRenderer, kPageW, kPageH, 0x82a0u, 3 * 26 - 3,
                             8, 26, 26));
  assert(Slot(tracker, kRenderer)->count == 4u);
  assert(tracker.RecordGlyph(kRenderer, kPageW, kPageH, 0x82a0u, 2, 8, 26,
                             26));
  assert(Slot(tracker, kRenderer)->count == 1u);
  assert(tracker.stats().page_resets == 1u);

  // A reallocated page of another size starts clean but keeps the binding.
  assert(tracker.RecordGlyph(kRenderer, 900, kPageH, 0x82a0u, 0, 8, 26, 26));
  slot = Slot(tracker, kRenderer);
  assert(slot->count == 1u && slot->page_w == 900 && slot->bound &&
         slot->layer_id == kTextLayer);

  // Overflow publishes nothing.
  core::GlyphTracker full;
  full.Bind(kRenderer, kTextLayer);
  for (int32_t i = 0; i < 300; ++i) {
    full.RecordGlyph(kRenderer, 4096, 4096, 0x82a0u, (i % 150) * 26,
                     (i / 150) * 30, 26, 26);
  }
  full.Bind(kRenderer, kTextLayer);
  full.SetPlacement(kRenderer, VisiblePlacement());
  assert(core::CollectVisibleGlyphs(*Slot(full, kRenderer), lines,
                                    core::kMaxSurfaceGlyphs) == 0u);
}

// ── suffix mapping, projection, hit test ────────────────────────────────────

void TestSuffixAndHit() {
  core::GlyphTracker tracker;
  // A previous sentence on the same page, then the selected one on row 2.
  const uint16_t prev[] = {0x82a0u, 0x82a2u, 0x8142u};  // あい。
  for (size_t i = 0u; i < 3u; ++i) {
    assert(tracker.RecordGlyph(kRenderer, kPageW, kPageH, prev[i],
                               static_cast<int32_t>(i) * 26, 8, 26, 26));
  }
  for (size_t index = 0u; index < kLineCount; ++index) {
    assert(tracker.RecordGlyph(kRenderer, kPageW, kPageH, kLine[index],
                               static_cast<int32_t>(index) * 26, 38, 26, 26));
  }
  tracker.Bind(kRenderer, kTextLayer);
  tracker.SetPlacement(kRenderer, VisiblePlacement());
  core::LineGlyph lines[core::kMaxSurfaceGlyphs];
  const size_t count = core::CollectVisibleGlyphs(*Slot(tracker, kRenderer),
                                                  lines,
                                                  core::kMaxSurfaceGlyphs);
  assert(count == 3u + kLineCount);
  const size_t text_len = wcslen(kLineText);
  const size_t first =
      core::MapSelectedSuffix(lines, count, kLineText, text_len);
  assert(first == 3u);
  assert(lines[0].source_index == core::kNoSource);
  assert(lines[3].source_index == 0u && lines[22].source_index == 19u);

  // Whitespace in the selected line is ignored.
  core::LineGlyph copy[core::kMaxSurfaceGlyphs];
  std::memcpy(copy, lines, sizeof(copy));
  const wchar_t spaced[] = L"そんな彼女の ことを人は「活動家」と呼ぶ。\n";
  assert(core::MapSelectedSuffix(copy, count, spaced, wcslen(spaced)) == 3u);
  // A different line maps nothing and leaves nothing mapped.
  std::memcpy(copy, lines, sizeof(copy));
  const wchar_t other[] = L"「失礼ですが、性的なトラブルですね？」";
  assert(core::MapSelectedSuffix(copy, count, other, wcslen(other)) == count);
  for (size_t i = 0u; i < count; ++i) {
    assert(copy[i].source_index == core::kNoSource);
  }
  // A line longer than the page cannot match (and clears partial mappings).
  std::memcpy(copy, lines, sizeof(copy));
  const wchar_t longer[] = L"ああそんな彼女のことを人は「活動家」と呼ぶ。";
  assert(core::MapSelectedSuffix(copy, 3u + kLineCount, longer,
                                 wcslen(longer)) == count);
  for (size_t i = 0u; i < count; ++i) {
    assert(copy[i].source_index == core::kNoSource);
  }

  // Projection: design 1280x720 onto a 2560x1440 physical client.
  core::PixelRect rect;
  assert(core::ProjectCell(lines[3], 1280, 720, 2560, 1440, &rect));
  assert(rect.x == 586 && rect.y == 1242 && rect.w == 52 && rect.h == 52);
  assert(!core::ProjectCell(lines[3], 1280, 720, 0, 1440, &rect));
  core::LineGlyph outside = lines[3];
  outside.x = 1270;
  assert(!core::ProjectCell(outside, 1280, 720, 2560, 1440, &rect));
  assert(core::ClientMatchesDesign(1280, 720, 1280, 720));
  assert(core::ClientMatchesDesign(1920, 1080, 1280, 720));
  assert(core::ClientMatchesDesign(1281, 720, 1280, 720));  // one pixel
  assert(!core::ClientMatchesDesign(1280, 800, 1280, 720));  // 16:10
  assert(!core::ClientMatchesDesign(0, 720, 1280, 720));

  // Client → design: identity at 1280x720, halved at 2560x1440.
  int32_t dx = 0, dy = 0;
  assert(core::ClientToDesign(300, 630, 1280, 720, 1280, 720, &dx, &dy) &&
         dx == 300 && dy == 630);
  assert(core::ClientToDesign(600, 1260, 2560, 1440, 1280, 720, &dx, &dy) &&
         dx == 300 && dy == 630);
  assert(!core::ClientToDesign(-1, 10, 1280, 720, 1280, 720, &dx, &dy));
  assert(!core::ClientToDesign(1280, 10, 1280, 720, 1280, 720, &dx, &dy));

  // Hit test: mapped glyph cell only; unmapped previous sentence misses.
  size_t hit = 0u;
  assert(core::HitTestLine(lines, count, 293 + 5, 583 + 38 + 5, &hit) &&
         hit == 3u);
  assert(core::HitTestLine(lines, count, 293 + 19 * 26 + 25, 583 + 38 + 25,
                           &hit) &&
         hit == 22u);
  assert(!core::HitTestLine(lines, count, 293 + 5, 583 + 8 + 5, &hit));
  assert(!core::HitTestLine(lines, count, 293 + 20 * 26 + 1, 583 + 38 + 5,
                            &hit));
  assert(!core::HitTestLine(lines, count, 10, 10, &hit));
}

// ── message-level claim ─────────────────────────────────────────────────────

void TestClaim() {
  core::ClaimState claim;
  // Moves and unclaimed ups pass through untouched.
  auto d = core::DecideMessage(WM_MOUSEMOVE, false, &claim);
  assert(!d.evaluate && !d.swallow && !d.submit);
  d = core::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(!d.swallow);
  // An ineligible press reaches the game.
  d = core::DecideMessage(WM_LBUTTONDOWN, false, &claim);
  assert(d.evaluate && !d.swallow && !d.submit && !claim.owned);
  d = core::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(!d.swallow);
  // An eligible press: down and its up are both swallowed, one submit.
  d = core::DecideMessage(WM_LBUTTONDOWN, true, &claim);
  assert(d.evaluate && d.swallow && d.submit && claim.owned);
  d = core::DecideMessage(WM_MOUSEMOVE, false, &claim);
  assert(!d.swallow && claim.owned);
  d = core::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(d.swallow && !d.submit && !claim.owned);
  // Double-click messages are presses too.
  d = core::DecideMessage(WM_LBUTTONDBLCLK, true, &claim);
  assert(d.swallow && d.submit && claim.owned);
  // A lost up can never make the next press sticky: it is evaluated afresh.
  d = core::DecideMessage(WM_LBUTTONDOWN, false, &claim);
  assert(d.evaluate && !d.swallow && !claim.owned);
  d = core::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(!d.swallow);
  assert(!core::DecideMessage(WM_LBUTTONDOWN, true, nullptr).swallow);
  // Right / middle buttons are never touched.
  assert(!core::NeedsEligibility(WM_RBUTTONDOWN));
  assert(!core::NeedsEligibility(WM_MBUTTONDOWN));
}

}  // namespace

int main() {
  TestResolveSites();
  TestResolveSitesEachProofFailsClosed();
  TestGlyphCodes();
  TestPlacement();
  TestTracker();
  TestSuffixAndHit();
  TestClaim();
  std::puts("fushi_catsystem2_lookup_test: ok");
  return 0;
}
