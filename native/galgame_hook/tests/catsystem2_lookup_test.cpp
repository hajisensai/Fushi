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
    // Code, then read-only data (vtables, import slots) like a real PE.
    image.section_count = 2u;
    image.sections[0] = {base, kDataRva, 0u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {base + kDataRva, kSize - kDataRva,
                         static_cast<uint32_t>(kDataRva), IMAGE_SCN_MEM_READ};
  }
  static constexpr size_t kDataRva = 0xe000u;
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
  void Pointer(size_t at, size_t target_rva) {  // absolute data pointer
    const uint32_t absolute = static_cast<uint32_t>(kAbsoluteBase + target_rva);
    std::memcpy(base + at, &absolute, 4u);
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

// Layout of the synthetic targeted-render engine.
constexpr size_t kRenderT = 0x1000u;
constexpr size_t kCharImageT = 0x1400u;   // int3 padding before it
constexpr size_t kRasterT = 0x1600u;
constexpr size_t kClearT = 0x1a00u;
constexpr size_t kClearCallT = 0x1b00u;
constexpr size_t kUpdateT = 0x2000u;
constexpr size_t kRevealT = 0x2100u;
constexpr size_t kSyncT = 0x2300u;
constexpr size_t kLayerQueryT = 0x3000u;
constexpr size_t kScreenQueryT = 0x3100u;
constexpr size_t kSceneVisibleT = 0x3200u;
constexpr size_t kSceneFindT = 0x3300u;
constexpr size_t kSceneDrawT = 0x3400u;
constexpr size_t kInputT = 0x4000u;
constexpr size_t kVtableT = 0xe100u;      // COL pointer, slot 0, slot 1
constexpr size_t kLocatorT = 0xe200u;

void BuildEngineT(SyntheticImage* img) {
  // RenderChar(renderer, record, target): prologue, record, epilogue.
  img->Put(kRenderT, core::kRenderTBytes, sizeof(core::kRenderTBytes));
  img->Put(kRenderT + core::kRecordPenTOffset, core::kRecordPenTBytes,
           sizeof(core::kRecordPenTBytes));
  img->Put(kRenderT + core::kRecordCharTOffset, core::kRecordCharTBytes,
           sizeof(core::kRecordCharTBytes));
  img->Put(kRenderT + core::kRenderTailTOffset, core::kRenderTailTBytes,
           sizeof(core::kRenderTailTBytes));
  // GetCharImage (vtable slot 1 of the font object) -> rasteriser twice.
  img->Rel32(kCharImageT + 0x20u, kRasterT);
  img->Rel32(kCharImageT + 0x60u, kRasterT);
  img->CallSlot(kRasterT + 0x40u, kSlotGlyph);
  img->Pointer(kVtableT, kLocatorT);              // data: not code
  img->Pointer(kVtableT + 4u, 0x1800u);           // slot 0
  img->Pointer(kVtableT + 8u, kCharImageT);       // slot 1
  // ClearPage: both page images through one fill helper; a +0x2ac caller.
  img->Put(kClearT, core::kClearTBytes, sizeof(core::kClearTBytes));
  img->Rel32(kClearT + 10u, 0x1800u);
  img->Rel32(kClearT + core::kClearTNormalFillCall, 0x1810u);
  img->Rel32(kClearT + core::kClearTFadeFillCall, 0x1810u);
  img->Put(kClearCallT, core::kClearCallTBytes,
           sizeof(core::kClearCallTBytes));
  img->base[kClearCallT + 9u] = 0x05u;
  img->Rel32(kClearCallT + core::kClearCallTCall, kClearT);
  // Window::Update -> reveal (renders through RenderChar), sync (screen copy).
  img->Put(kUpdateT, core::kUpdateTBytes, sizeof(core::kUpdateTBytes));
  img->Rel32(kUpdateT + 13u, 0x1830u);
  img->Rel32(kUpdateT + core::kUpdateTRevealCall, kRevealT);
  img->Rel32(kUpdateT + core::kUpdateTSyncCall, kSyncT);
  img->Rel32(kRevealT + 0x40u, kRenderT);
  img->Put(kSyncT + 0x30u, core::kSyncScreenTBytes,
           sizeof(core::kSyncScreenTBytes));
  // Layer query chain and the scene draw loop.
  img->Put(kLayerQueryT, core::kLayerQueryTBytes,
           sizeof(core::kLayerQueryTBytes));
  img->Rel32(kLayerQueryT + core::kLayerQueryTCall, kScreenQueryT);
  img->Put(kScreenQueryT, core::kScreenQueryTBytes,
           sizeof(core::kScreenQueryTBytes));
  img->Rel32(kScreenQueryT + 18u, 0x1840u);
  img->Rel32(kScreenQueryT + core::kScreenQueryTSceneCall, kSceneVisibleT);
  img->Put(kSceneVisibleT, core::kSceneVisibleTBytes,
           sizeof(core::kSceneVisibleTBytes));
  img->Rel32(kSceneVisibleT + core::kSceneVisibleTFindCall, kSceneFindT);
  img->Put(kSceneFindT, core::kSceneFindTBytes,
           sizeof(core::kSceneFindTBytes));
  img->Put(kSceneDrawT, core::kSceneDrawTBytes,
           sizeof(core::kSceneDrawTBytes));
  // Input::Handle with its capture bookkeeping imports.
  img->Put(kInputT, core::kInputTBytes, sizeof(core::kInputTBytes));
  img->CallSlot(kInputT + 0x100u, kSlotReleaseCapture);
  img->CallSlot(kInputT + 0x300u, kSlotWindowFromPoint);
  img->CallSlot(kInputT + 0x420u, kSlotSetCapture);
  img->Put(kInputT + 0x5adu, core::kInputTRetBytes,
           sizeof(core::kInputTRetBytes));
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
  assert(sites.variant == core::SiteVariant::kAdjacentPage);
  assert(sites.render_stack_args == 1u);
  assert(sites.input_stack_args == 5u);
  assert(sites.walk.list_offset == 0u && sites.walk.head_offset == 0x14u &&
         !sites.walk.layer_by_pointer);

  // Several parts share the base-class layer query; copies that agree on the
  // screen query are one proof, not an ambiguity.
  img.Put(0x5800u, core::kLayerQueryBytes, sizeof(core::kLayerQueryBytes));
  img.Rel32(0x5800u + core::kLayerQueryCall, kScreenQuery);
  assert(core::ResolveSites(img.image, Imports(), &sites) ==
         core::SiteResult::kResolved);
}

void TestResolveTargetedRenderSites() {
  core::Sites sites;
  SyntheticImage img;
  BuildEngineT(&img);
  assert(core::ResolveSites(img.image, Imports(), &sites) ==
         core::SiteResult::kResolved);
  assert(sites.variant == core::SiteVariant::kTargetedRender);
  assert(sites.render_char == img.At(kRenderT));
  assert(sites.clear_page == img.At(kClearT));
  assert(sites.char_image == img.At(kCharImageT));
  assert(sites.rasteriser == img.At(kRasterT));
  assert(sites.window_update == img.At(kUpdateT));
  assert(sites.input_handler == img.At(kInputT));
  assert(sites.render_stack_args == 2u);
  assert(sites.input_stack_args == 6u);
  assert(sites.walk.list_offset == 4u && sites.walk.head_offset == 0u &&
         sites.walk.layer_by_pointer);

  // A derived class repeating GetCharImage in its own vtable is one
  // function, not an ambiguity; so are other +0x2ac callers that clear
  // something else, as long as one of them calls ClearPage.
  img.Pointer(kVtableT + 0x40u, kLocatorT);
  img.Pointer(kVtableT + 0x44u, 0x1820u);
  img.Pointer(kVtableT + 0x48u, kCharImageT);
  img.Put(0x5a00u, core::kClearCallTBytes, sizeof(core::kClearCallTBytes));
  img.Rel32(0x5a00u + core::kClearCallTCall, 0x1850u);
  assert(core::ResolveSites(img.image, Imports(), &sites) ==
         core::SiteResult::kResolved);
  assert(sites.char_image == img.At(kCharImageT));

  // Both layouts present: the adjacent-page proof decides.
  SyntheticImage both;
  BuildEngineT(&both);
  both.Put(0x6000u, core::kPageBytes, sizeof(core::kPageBytes));
  assert(core::ResolveSites(both.image, Imports(), &sites) ==
         core::SiteResult::kRecordInvalid);
  assert(sites.render_char == 0u);
}

// Each targeted-render proof, broken alone, installs nothing.
void TestTargetedRenderEachProofFailsClosed() {
  struct Breaker {
    void (*apply)(SyntheticImage*);
    core::SiteResult expected;
  };
  const Breaker breakers[] = {
      // A second RenderChar is ambiguous.
      {[](SyntheticImage* img) {
         img->Put(0x5000u, core::kRenderTBytes, sizeof(core::kRenderTBytes));
       },
       core::SiteResult::kPageMissing},
      // Record offsets moved / the epilogue pops another argument count.
      {[](SyntheticImage* img) {
         img->base[kRenderT + core::kRecordPenTOffset + 25u] = 0x18u;
       },
       core::SiteResult::kRecordInvalid},
      {[](SyntheticImage* img) {
         img->base[kRenderT + core::kRecordCharTOffset + 66u] = 0x08u;
       },
       core::SiteResult::kRecordInvalid},
      {[](SyntheticImage* img) {
         img->base[kRenderT + core::kRenderTailTOffset + 7u] = 0x04u;
       },
       core::SiteResult::kRecordInvalid},
      // No vtable names GetCharImage (the locator slot is code: not a vtable
      // start), or the function does not start after padding.
      {[](SyntheticImage* img) { img->Pointer(kVtableT, 0x1830u); },
       core::SiteResult::kRasteriserInvalid},
      {[](SyntheticImage* img) { img->base[kCharImageT - 1u] = 0x90u; },
       core::SiteResult::kRasteriserInvalid},
      // GetCharImage reaches the rasteriser only once.
      {[](SyntheticImage* img) {
         std::memset(img->base + kCharImageT + 0x60u, 0xcc, 5u);
       },
       core::SiteResult::kRasteriserInvalid},
      // A second, different function passing the proof is ambiguous.
      {[](SyntheticImage* img) {
         img->Rel32(0x1c00u + 0x20u, kRasterT);
         img->Rel32(0x1c00u + 0x60u, kRasterT);
         img->Pointer(kVtableT + 0x40u, kLocatorT);
         img->Pointer(kVtableT + 0x44u, 0x1820u);
         img->Pointer(kVtableT + 0x48u, 0x1c00u);
       },
       core::SiteResult::kRasteriserInvalid},
      // ClearPage missing, fills through two helpers, or nobody calls it
      // through the message window's renderer.
      {[](SyntheticImage* img) { img->base[kClearT + 63u] = 0x77u; },
       core::SiteResult::kClearInvalid},
      {[](SyntheticImage* img) {
         img->Rel32(kClearT + core::kClearTFadeFillCall, 0x1820u);
       },
       core::SiteResult::kClearInvalid},
      {[](SyntheticImage* img) {
         img->Rel32(kClearCallT + core::kClearCallTCall, 0x1850u);
       },
       core::SiteResult::kClearInvalid},
      // Update missing; reveal does not render; sync does not reach +0x68.
      {[](SyntheticImage* img) { img->base[kUpdateT + 46u] = 0xa8u; },
       core::SiteResult::kUpdateMissing},
      {[](SyntheticImage* img) {
         std::memset(img->base + kRevealT + 0x40u, 0xcc, 5u);
       },
       core::SiteResult::kRevealInvalid},
      {[](SyntheticImage* img) { img->base[kSyncT + 0x32u] = 0x6cu; },
       core::SiteResult::kSyncInvalid},
      // Layer query missing / disagreeing copies.
      {[](SyntheticImage* img) { img->base[kLayerQueryT + 12u] = 0x08u; },
       core::SiteResult::kLayerQueryMissing},
      {[](SyntheticImage* img) {
         img->Put(0x5800u, core::kLayerQueryTBytes,
                  sizeof(core::kLayerQueryTBytes));
         img->Rel32(0x5800u + core::kLayerQueryTCall, 0x1850u);
       },
       core::SiteResult::kLayerQueryMissing},
      // Scene layout differs along the chain, or the draw loop is missing.
      {[](SyntheticImage* img) { img->base[kScreenQueryT + 32u] = 0x0cu; },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img) { img->base[kSceneVisibleT + 18u] = 0x08u; },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img) { img->base[kSceneFindT + 7u] = 0x3au; },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img) { img->base[kSceneDrawT + 49u] = 0x0cu; },
       core::SiteResult::kSceneInvalid},
      // Input handler missing / without capture imports.
      {[](SyntheticImage* img) { img->base[kInputT + 55u] = 0x01u; },
       core::SiteResult::kInputMissing},
      {[](SyntheticImage* img) {
         std::memset(img->base + kInputT + 0x300u, 0xcc, 6u);
       },
       core::SiteResult::kInputImportsInvalid},
      // Handle pops another number of arguments than the detour would.
      {[](SyntheticImage* img) { img->base[kInputT + 0x5aeu] = 0x14u; },
       core::SiteResult::kInputFrameInvalid},
  };
  for (const Breaker& breaker : breakers) {
    SyntheticImage img;
    BuildEngineT(&img);
    breaker.apply(&img);
    core::Sites sites;
    sites.render_char = 1u;
    const auto result = core::ResolveSites(img.image, Imports(), &sites);
    if (result != breaker.expected) {
      std::fprintf(stderr, "targeted: expected %u got %u\n",
                   static_cast<unsigned>(breaker.expected),
                   static_cast<unsigned>(result));
    }
    assert(result == breaker.expected);
    assert(sites.render_char == 0u && sites.clear_page == 0u &&
           sites.window_update == 0u && sites.input_handler == 0u &&
           sites.variant == core::SiteVariant::kNone);
  }
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

  // A cover box over part of glyph 2 keeps the glyph in the text and its
  // whole cell clickable: a box only bounds the cover's opaque pixels (the
  // 2016 message window's menu bar box overlaps the lower text row).
  nodes = DialogueScene();
  nodes.push_back(Node(91, true, 346, 580, 12, 50));  // box {345,579,358,630}
  tracker.SetPlacement(kRenderer,
                       core::ResolvePlacement(nodes.data(), nodes.size(),
                                              kTextLayer, kPageW, kPageH));
  count = core::CollectVisibleGlyphs(*slot, lines, core::kMaxSurfaceGlyphs);
  assert(count == kLineCount);
  assert(lines[2].x == 345 && lines[2].w == 26);
  assert(lines[2].hit.x0 == 345 && lines[2].hit.x1 == 371 &&
         lines[2].hit.y0 == 591 && lines[2].hit.y1 == 617);
  assert(lines[1].hit.x1 == 345 && lines[3].hit.x0 == 371);
  // A corner overlap: still visible, still fully clickable.
  nodes = DialogueScene();
  nodes.push_back(Node(92, true, 350, 600, 40, 40));  // box {349,599,390,640}
  tracker.SetPlacement(kRenderer,
                       core::ResolvePlacement(nodes.data(), nodes.size(),
                                              kTextLayer, kPageW, kPageH));
  count = core::CollectVisibleGlyphs(*slot, lines, core::kMaxSurfaceGlyphs);
  assert(count == kLineCount && lines[2].hit.x0 == 345 &&
         lines[2].hit.y1 == 617 && lines[3].hit.x1 == 397);
  assert(!lines[1].hit.Empty() && !lines[4].hit.Empty());

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

  // Only the clickable rectangle hits: a trimmed or empty one misses.
  lines[3].hit.x0 = lines[3].x + 13;
  assert(!core::HitTestLine(lines, count, 293 + 5, 583 + 38 + 5, &hit));
  assert(core::HitTestLine(lines, count, 293 + 20, 583 + 38 + 5, &hit) &&
         hit == 3u);
  lines[3].hit = core::IntRect();
  assert(!core::HitTestLine(lines, count, 293 + 20, 583 + 38 + 5, &hit));
}

// Text fade draws into the renderer's second page and swaps the two: both
// pages are the text page (probe: every fade-mode draw went to +0x40).
void TestRendererPage() {
  assert(core::kRendererWorkImageOffset == 0x40u);
  assert(core::IsRendererPage(0x1000u, 0x1000u, 0x2000u));
  assert(core::IsRendererPage(0x2000u, 0x1000u, 0x2000u));
  assert(!core::IsRendererPage(0x3000u, 0x1000u, 0x2000u));
  assert(!core::IsRendererPage(0u, 0u, 0x2000u));
}

// A spoken line arrives as `「body」【speaker】`; the speaker is on the name
// layer, so the text page is matched against the body.
void TestSpeakerTag() {
  auto start = [](const wchar_t* text) {
    return core::SpeakerTagStart(text, wcslen(text));
  };
  const wchar_t* spoken = L"「許して」【少女】";
  assert(start(spoken) == 5u);
  assert(start(L"「あ」【太】  ") == 3u);           // one-char name, spaces
  assert(start(L"「うん」 【太一】") == 5u);        // space before the tag
  assert(start(L"考え事だろうか。") == 8u);         // narration: none
  assert(start(L"【少女】") == 4u);                 // no body
  assert(start(L"「あ」【】") == 5u);               // empty name
  assert(start(L"「あ」】") == 4u);                 // no opener
  assert(start(L"「あ」【太】】") == 7u);           // nested closer
  assert(core::SpeakerTagStart(nullptr, 0u) == 0u);

  // The page holds only the body: the body maps, the full line does not.
  core::LineGlyph glyphs[5] = {};
  const wchar_t page[] = L"「許して」";
  for (size_t index = 0u; index < 5u; ++index) {
    glyphs[index].codepoint = page[index];
  }
  assert(core::MapSelectedSuffix(glyphs, 5u, spoken, wcslen(spoken)) == 5u);
  assert(core::MapSelectedSuffix(glyphs, 5u, spoken, start(spoken)) == 0u);
  assert(glyphs[4].source_index == 4u);
}

void TestContains() {
  const core::IntRect cell = {100, 200, 126, 226};
  assert(core::Contains({90, 190, 140, 240}, cell));
  assert(!core::Contains({101, 190, 140, 240}, cell));
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
  TestResolveTargetedRenderSites();
  TestTargetedRenderEachProofFailsClosed();
  TestContains();
  TestSpeakerTag();
  TestRendererPage();
  TestGlyphCodes();
  TestPlacement();
  TestTracker();
  TestSuffixAndHit();
  TestClaim();
  std::puts("fushi_catsystem2_lookup_test: ok");
  return 0;
}
