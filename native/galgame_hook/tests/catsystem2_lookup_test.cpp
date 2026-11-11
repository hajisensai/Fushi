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
constexpr size_t kDecoyUpdateT = 0x5c00u;  // another window class
constexpr size_t kDecoyRevealT = 0x5d00u;
constexpr size_t kDecoyClearT = 0x6800u;   // another renderer class
constexpr size_t kDecoyClearCallT = 0x6900u;
constexpr size_t kVtableT = 0xe100u;      // COL pointer, slot 0, slot 1
constexpr size_t kLocatorT = 0xe200u;

// ── the two measured targeted-render codegens ──────────────────────────────
//
// Hand-assembled instruction bytes of the parts the two builds compile
// differently; rel32 targets, IAT operands and immediates the proof does not
// read are zero and filled in by BuildEngineT.  "2016" is the 2016 build the
// layout was first measured on, "2020" the cs2 2.6.1.90 build (newer MSVC,
// renderer one dword shorter in front of the page size, window fields one
// dword further, a second window / renderer class with the same bodies).

// RenderChar's GetCharImage argument block (at kRecordCharOffsetT).
constexpr size_t kRecordCharOffsetT = 0xfeu;
constexpr uint8_t kRecordChar2016[] = {
    0x8b, 0x03,                    // mov eax,[ebx]
    0xff, 0x77, 0x54,              // push [edi+0x54]
    0x8b, 0x4b, 0x08,              // mov ecx,[ebx+8]
    0xff, 0x77, 0x50,              // push [edi+0x50]
    0x8b, 0x30,                    // mov esi,[eax]
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call helper
    0x8b, 0x4c, 0x24, 0x2c, 0x50, 0x33, 0xc0,
    0xff, 0xb1, 0xac, 0x00, 0x00, 0x00,                          // push [ecx+0xac]
    0x81, 0xb9, 0xa0, 0x00, 0x00, 0x00, 0xbc, 0x02, 0x00, 0x00,  // cmp
    0x8b, 0x0b,                    // mov ecx,[ebx]
    0x0f, 0x94, 0xc0, 0x50, 0x8d, 0x47, 0x34, 0x50,
    0xff, 0x77, 0x1c,              // push [edi+0x1c]  size
    0x0f, 0xb7, 0x47, 0x04, 0x50,  // movzx eax,word [edi+4]; push eax  code
    0x8d, 0x44, 0x24, 0x58, 0x50,
    0xff, 0x56, 0x04};             // call [esi+4]
constexpr uint8_t kRecordChar2020[] = {
    0xff, 0x77, 0x5c,              // push [edi+0x5c]
    0x8b, 0x03,                    // mov eax,[ebx]
    0xff, 0x77, 0x58,              // push [edi+0x58]
    0x8b, 0x4b, 0x08,              // mov ecx,[ebx+8]
    0xff, 0x77, 0x54,              // push [edi+0x54]
    0x8b, 0x30,                    // mov esi,[eax]
    0xff, 0x77, 0x50,              // push [edi+0x50]
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call helper
    0x8b, 0x4c, 0x24, 0x34, 0x50, 0x33, 0xc0,
    0xff, 0xb1, 0xcc, 0x00, 0x00, 0x00,                          // push [ecx+0xcc]
    0x81, 0xb9, 0xc0, 0x00, 0x00, 0x00, 0xbc, 0x02, 0x00, 0x00,  // cmp
    0x8b, 0x0b,                    // mov ecx,[ebx]
    0x0f, 0x94, 0xc0, 0x50, 0x8d, 0x47, 0x34, 0x50,
    0xff, 0x77, 0x1c,              // push [edi+0x1c]  size
    0x0f, 0xb7, 0x47, 0x04, 0x50,  // movzx eax,word [edi+4]; push eax  code
    0x8d, 0x44, 0x24, 0x60, 0x50,
    0xff, 0x56, 0x04};             // call [esi+4]

// ClearPage: head, five layout resets, the two page fills, epilogue.  Fill
// calls at kClearFillNormalCall / kClearFillFadeCall.
constexpr size_t kClearFillNormalCall = 69u;
constexpr size_t kClearFillFadeCall = 93u;
constexpr uint8_t kClear2016[] = {
    0x56, 0x8b, 0xf1, 0x8b, 0x4e, 0x08, 0x85, 0xc9, 0x74, 0x05,
    0xe8, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x20, 0x00, 0x00, 0x00, 0x00,  // mov [esi+0x20],0
    0xc7, 0x46, 0x24, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x28, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x2c, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x30, 0x00, 0x00, 0x00, 0x00,
    0x8b, 0x4e, 0x04, 0x85, 0xc9, 0x74, 0x11, 0x6a, 0x00,  // page +4
    0xff, 0x76, 0x18, 0xff, 0x76, 0x14,                    // H +0x18, W +0x14
    0x6a, 0x00, 0x6a, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00,
    0x8b, 0x4e, 0x40, 0x85, 0xc9, 0x74, 0x11, 0x6a, 0x00,  // fade +0x40
    0xff, 0x76, 0x18, 0xff, 0x76, 0x14,
    0x6a, 0x00, 0x6a, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00,
    0x5e, 0xc3};
constexpr uint8_t kClear2020[] = {
    0x56, 0x8b, 0xf1, 0x8b, 0x4e, 0x08, 0x85, 0xc9, 0x74, 0x05,
    0xe8, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x1c, 0x00, 0x00, 0x00, 0x00,  // mov [esi+0x1c],0
    0xc7, 0x46, 0x20, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x24, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x28, 0x00, 0x00, 0x00, 0x00,
    0xc7, 0x46, 0x2c, 0x00, 0x00, 0x00, 0x00,
    0x8b, 0x4e, 0x04, 0x85, 0xc9, 0x74, 0x11, 0x6a, 0x00,  // page +4
    0xff, 0x76, 0x14, 0xff, 0x76, 0x10,                    // H +0x14, W +0x10
    0x6a, 0x00, 0x6a, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00,
    0x8b, 0x4e, 0x3c, 0x85, 0xc9, 0x74, 0x11, 0x6a, 0x00,  // fade +0x3c
    0xff, 0x76, 0x14, 0xff, 0x76, 0x10,
    0x6a, 0x00, 0x6a, 0x00, 0xe8, 0x00, 0x00, 0x00, 0x00,
    0x5e, 0xc3};
static_assert(sizeof(kClear2016) == sizeof(kClear2020), "same body length");
constexpr size_t kClearPageHeight = 61u;  // H byte of the normal fill

// Screen::QueryLayer with `dec eax` (2016) is core::kScreenQueryTBytes; the
// 2020 build tests the result with `sub eax,1` (core::kScreenQueryT2Bytes).

// Scene::Find: map = [ecx], head = [map].
constexpr uint8_t kSceneFind2016[] = {
    0x8b, 0x54, 0x24, 0x04, 0x56, 0x57,
    0x8b, 0x39,   // mov edi,[ecx]
    0x8b, 0x37};  // mov esi,[edi]
constexpr uint8_t kSceneFind2020[] = {
    0x8b, 0x01,   // mov eax,[ecx]
    0x56,
    0x8b, 0x30,   // mov esi,[eax]
    0x8b, 0xc6, 0x8b, 0x48, 0x04};

// Scene::Draw alignment between the loop test and the loop head.
constexpr uint8_t kDrawGap2016[12] = {0xeb, 0x0a, 0xcc, 0xcc, 0xcc, 0xcc,
                                      0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc};
constexpr uint8_t kDrawGap2020[12] = {0x0f, 0x1f, 0x40, 0x00, 0x0f, 0x1f,
                                      0x84, 0x00, 0x00, 0x00, 0x00, 0x00};
// `jmp +0x0a; lea esp,[esp]; lea ecx,[ecx]` (VS2013 alignment fill).
constexpr uint8_t kDrawGap2019[12] = {0xeb, 0x0a, 0x8d, 0xa4, 0x24, 0x00,
                                      0x00, 0x00, 0x00, 0x8d, 0x49, 0x00};
constexpr size_t kDrawGapAt = 35u;

// Input::Handle prologue up to the message dispatch.
constexpr uint8_t kInputPrologue2016[] = {
    0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0x81, 0xec, 0x00, 0x00, 0x00, 0x00,
    0xa1, 0x00, 0x00, 0x00, 0x00, 0x33, 0xc4, 0x89, 0x84, 0x24, 0x00, 0x00,
    0x00, 0x00,
    0x8b, 0x55, 0x10,              // mov edx,[ebp+0x10]  msg
    0x8b, 0x4d, 0x14,
    0x89, 0x4c, 0x24, 0x04,        // mov [esp+4],ecx
    0x53, 0x8b, 0x5d, 0x08, 0x56, 0x8b, 0x75, 0x0c, 0x57, 0x8b, 0x7d, 0x18,
    0x89, 0x7c, 0x24, 0x14};
constexpr uint8_t kInputPrologue2020[] = {
    0x55, 0x8b, 0xec, 0x83, 0xe4, 0xf8, 0x81, 0xec, 0x4c, 0x01, 0x00, 0x00,
    0xa1, 0x00, 0x00, 0x00, 0x00, 0x33, 0xc4, 0x89, 0x84, 0x24, 0x48, 0x01,
    0x00, 0x00,
    0x8b, 0x55, 0x10,              // mov edx,[ebp+0x10]  msg
    0x8b, 0x4d, 0x14,
    0x89, 0x0c, 0x24,              // mov [esp],ecx
    0x53, 0x8b, 0x5d, 0x08, 0x56, 0x8b, 0x75, 0x0c, 0x57, 0x8b, 0x7d, 0x18,
    0x89, 0x7c, 0x24, 0x10};
constexpr size_t kInputMessageDisp = 28u;  // disp8 of `mov edx,[ebp+0x10]`

struct TargetedCodegen {
  const char* name;
  const uint8_t* record_char;
  size_t record_char_bytes;
  const uint8_t* clear;
  uint32_t window_renderer;
  uint8_t window_screen;
  bool sub_eax_query;        // Screen::QueryLayer codegen
  const uint8_t* scene_find;
  size_t scene_find_bytes;
  size_t scene_find_map;     // ModR/M byte of `mov r,[ecx]`
  const uint8_t* draw_gap;
  const uint8_t* input_prologue;
  size_t input_prologue_bytes;
  bool clear_caller_reveals;  // the window's ClearPage caller drives reveal
  size_t render_tail;         // RenderChar epilogue distance from the entry
  core::ObjectLayout layout;  // expected
};

constexpr TargetedCodegen kT2016 = {
    "2016", kRecordChar2016, sizeof(kRecordChar2016), kClear2016, 0x2acu,
    0x68u, false, kSceneFind2016, sizeof(kSceneFind2016), 7u, kDrawGap2016,
    kInputPrologue2016, sizeof(kInputPrologue2016), false, 0x298u,
    {0x68u, 0x2acu, 0x14u, 0x18u, 0x40u}};
constexpr TargetedCodegen kT2020 = {
    "2020", kRecordChar2020, sizeof(kRecordChar2020), kClear2020, 0x2b0u,
    0x6cu, true, kSceneFind2020, sizeof(kSceneFind2020), 1u, kDrawGap2020,
    kInputPrologue2020, sizeof(kInputPrologue2020), true, 0x298u,
    {0x6cu, 0x2b0u, 0x10u, 0x14u, 0x3cu}};
// cs2 2.6.1.90 built with VS2013 (linker 12.0, PE timestamp 2019-03): the
// 2016 object layout (window +0x68 / +0x2ac, page +0x14 / +0x18, fade
// +0x40), `dec eax` QueryLayer, 2016 Scene::Find and Input::Handle spills,
// but the 2020 GetCharImage argument block, the second window / renderer
// class, and a RenderChar body six bytes longer (epilogue at +0x29e).  The
// fixed +0x298 epilogue check rejected it with kRecordInvalid (result=4).
constexpr TargetedCodegen kT2019 = {
    "2019-vs2013", kRecordChar2020, sizeof(kRecordChar2020), kClear2016,
    0x2acu, 0x68u, false, kSceneFind2016, sizeof(kSceneFind2016), 7u,
    kDrawGap2019, kInputPrologue2016, sizeof(kInputPrologue2016), true,
    0x29eu, {0x68u, 0x2acu, 0x14u, 0x18u, 0x40u}};
constexpr const TargetedCodegen* kTargetedCodegens[] = {&kT2016, &kT2020,
                                                        &kT2019};

size_t ScreenQuerySceneCall(const TargetedCodegen& cg) {
  return cg.sub_eax_query ? core::kScreenQueryT2SceneCall
                          : core::kScreenQueryTSceneCall;
}

// `mov ecx,[edi+renderer]; test ecx,ecx; je +5; call clear` at `at`, then
// (optionally, same function) `call reveal; ret`.
void PutClearCaller(SyntheticImage* img, size_t at, uint32_t window_renderer,
                    size_t clear, size_t reveal) {
  img->Put(at, core::kClearCallTBytes, sizeof(core::kClearCallTBytes));
  std::memcpy(img->base + at + core::kClearCallTDisp, &window_renderer, 4u);
  img->base[at + 9u] = 0x05u;
  img->Rel32(at + core::kClearCallTCall, clear);
  size_t tail = at + sizeof(core::kClearCallTBytes);
  if (reveal != 0u) {
    img->Rel32(tail, reveal);
    tail += 5u;
  }
  img->base[tail] = 0xc3u;
}

void PutClear(SyntheticImage* img, const TargetedCodegen& cg, size_t at,
              size_t fill) {
  img->Put(at, cg.clear, sizeof(kClear2016));
  img->Rel32(at + 10u, 0x1800u);
  img->Rel32(at + kClearFillNormalCall, fill);
  img->Rel32(at + kClearFillFadeCall, fill);
}

void PutUpdate(SyntheticImage* img, const TargetedCodegen& cg, size_t at,
               size_t reveal) {
  img->Put(at, core::kUpdateTBytes, sizeof(core::kUpdateTBytes));
  std::memcpy(img->base + at + core::kUpdateTRendererDisp,
              &cg.window_renderer, 4u);
  img->Rel32(at + 13u, 0x1830u);
  img->Rel32(at + core::kUpdateTRevealCall, reveal);
  img->Rel32(at + core::kUpdateTSyncCall, kSyncT);
}

void PutLayerQuery(SyntheticImage* img, const TargetedCodegen& cg, size_t at,
                   size_t target) {
  img->Put(at, core::kLayerQueryTBytes, sizeof(core::kLayerQueryTBytes));
  img->base[at + core::kLayerQueryTScreenDisp] = cg.window_screen;
  img->Rel32(at + core::kLayerQueryTCall, target);
}

void BuildEngineT(SyntheticImage* img, const TargetedCodegen& cg = kT2016) {
  // RenderChar(renderer, record, target): prologue, record, epilogue.
  img->Put(kRenderT, core::kRenderTBytes, sizeof(core::kRenderTBytes));
  img->Put(kRenderT + core::kRecordPenTOffset, core::kRecordPenTBytes,
           sizeof(core::kRecordPenTBytes));
  img->Put(kRenderT + kRecordCharOffsetT, cg.record_char,
           cg.record_char_bytes);
  img->Put(kRenderT + cg.render_tail, core::kRenderTailTBytes,
           sizeof(core::kRenderTailTBytes));
  // GetCharImage (vtable slot 1 of the font object) -> rasteriser twice.
  img->Rel32(kCharImageT + 0x20u, kRasterT);
  img->Rel32(kCharImageT + 0x60u, kRasterT);
  img->CallSlot(kRasterT + 0x40u, kSlotGlyph);
  img->Pointer(kVtableT, kLocatorT);              // data: not code
  img->Pointer(kVtableT + 4u, 0x1800u);           // slot 0
  img->Pointer(kVtableT + 8u, kCharImageT);       // slot 1
  // ClearPage: both page images through one fill helper; a window caller.
  PutClear(img, cg, kClearT, 0x1810u);
  PutClearCaller(img, kClearCallT, cg.window_renderer, kClearT,
                 cg.clear_caller_reveals ? kRevealT : 0u);
  // Window::Update -> reveal (renders through RenderChar), sync (screen copy).
  PutUpdate(img, cg, kUpdateT, kRevealT);
  img->Rel32(kRevealT + 0x40u, kRenderT);
  const uint8_t sync[] = {0x8b, 0x4b, cg.window_screen, 0x50, 0xe8};
  img->Put(kSyncT + 0x30u, sync, sizeof(sync));
  // Layer query chain and the scene draw loop.
  PutLayerQuery(img, cg, kLayerQueryT, kScreenQueryT);
  if (cg.sub_eax_query) {
    img->Put(kScreenQueryT, core::kScreenQueryT2Bytes,
             sizeof(core::kScreenQueryT2Bytes));
  } else {
    img->Put(kScreenQueryT, core::kScreenQueryTBytes,
             sizeof(core::kScreenQueryTBytes));
  }
  img->Rel32(kScreenQueryT + 18u, 0x1840u);
  img->Rel32(kScreenQueryT + ScreenQuerySceneCall(cg), kSceneVisibleT);
  img->Put(kSceneVisibleT, core::kSceneVisibleTBytes,
           sizeof(core::kSceneVisibleTBytes));
  img->Rel32(kSceneVisibleT + core::kSceneVisibleTFindCall, kSceneFindT);
  img->Put(kSceneFindT, cg.scene_find, cg.scene_find_bytes);
  img->Put(kSceneDrawT, core::kSceneDrawTBytes,
           sizeof(core::kSceneDrawTBytes));
  img->Put(kSceneDrawT + kDrawGapAt, cg.draw_gap, 12u);
  // Input::Handle with its capture bookkeeping imports.
  img->Put(kInputT, cg.input_prologue, cg.input_prologue_bytes);
  img->Put(kInputT + cg.input_prologue_bytes, core::kInputTDispatchBytes,
           sizeof(core::kInputTDispatchBytes));
  img->CallSlot(kInputT + 0x100u, kSlotReleaseCapture);
  img->CallSlot(kInputT + 0x300u, kSlotWindowFromPoint);
  img->CallSlot(kInputT + 0x420u, kSlotSetCapture);
  img->Put(kInputT + 0x5adu, core::kInputTRetBytes,
           sizeof(core::kInputTRetBytes));
}

// The 2020 build's second window class: an Update with the same body whose
// reveal renders through another renderer, and that renderer's ClearPage
// (same body) called through the same window field from a function that does
// not reveal the message page.
void AddDecoyWindowClass(SyntheticImage* img, const TargetedCodegen& cg) {
  PutUpdate(img, cg, kDecoyUpdateT, kDecoyRevealT);
  img->base[kDecoyRevealT] = 0xc3u;
  PutClear(img, cg, kDecoyClearT, 0x1820u);
  PutClearCaller(img, kDecoyClearCallT, cg.window_renderer, kDecoyClearT,
                 kDecoyRevealT);
}

bool LayoutEquals(const core::ObjectLayout& lhs,
                  const core::ObjectLayout& rhs) {
  return lhs.window_screen == rhs.window_screen &&
         lhs.window_renderer == rhs.window_renderer &&
         lhs.page_width == rhs.page_width &&
         lhs.page_height == rhs.page_height &&
         lhs.work_image == rhs.work_image;
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
  // The adjacent-page signatures fix the object layout.
  assert(LayoutEquals(sites.layout, {0x68u, 0x2acu, 0x14u, 0x18u, 0x40u}));

  // Several parts share the base-class layer query; copies that agree on the
  // screen query are one proof, not an ambiguity.
  img.Put(0x5800u, core::kLayerQueryBytes, sizeof(core::kLayerQueryBytes));
  img.Rel32(0x5800u + core::kLayerQueryCall, kScreenQuery);
  assert(core::ResolveSites(img.image, Imports(), &sites) ==
         core::SiteResult::kResolved);
}

void TestResolveTargetedRenderSites() {
  for (const TargetedCodegen* cg : kTargetedCodegens) {
    core::Sites sites;
    SyntheticImage img;
    BuildEngineT(&img, *cg);
    const auto result = core::ResolveSites(img.image, Imports(), &sites);
    if (result != core::SiteResult::kResolved) {
      std::fprintf(stderr, "targeted %s: got %u\n", cg->name,
                   static_cast<unsigned>(result));
    }
    assert(result == core::SiteResult::kResolved);
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
    // Window and renderer fields come from the proving code.
    assert(LayoutEquals(sites.layout, cg->layout));

    // A derived class repeating GetCharImage in its own vtable is one
    // function, not an ambiguity; so are other window-renderer callers that
    // clear something else, as long as one of them calls ClearPage.
    img.Pointer(kVtableT + 0x40u, kLocatorT);
    img.Pointer(kVtableT + 0x44u, 0x1820u);
    img.Pointer(kVtableT + 0x48u, kCharImageT);
    PutClearCaller(&img, 0x5a00u, cg->window_renderer, 0x1850u, 0u);
    assert(core::ResolveSites(img.image, Imports(), &sites) ==
           core::SiteResult::kResolved);
    assert(sites.char_image == img.At(kCharImageT));
  }

  // cs2 2.6.1.90: a second window class shares the Update and ClearPage
  // bodies (and the renderer field).  Its Update's reveal does not render
  // through RenderChar and its ClearPage's caller does not reveal the message
  // page, so the message window's sites are still the only ones proven.
  for (const TargetedCodegen* cg : {&kT2020, &kT2019}) {
    core::Sites sites;
    SyntheticImage img;
    BuildEngineT(&img, *cg);
    AddDecoyWindowClass(&img, *cg);
    assert(core::ResolveSites(img.image, Imports(), &sites) ==
           core::SiteResult::kResolved);
    assert(sites.window_update == img.At(kUpdateT));
    assert(sites.clear_page == img.At(kClearT));
    assert(LayoutEquals(sites.layout, cg->layout));
  }

  // Both layouts present: the adjacent-page proof decides.
  core::Sites sites;
  SyntheticImage both;
  BuildEngineT(&both);
  both.Put(0x6000u, core::kPageBytes, sizeof(core::kPageBytes));
  assert(core::ResolveSites(both.image, Imports(), &sites) ==
         core::SiteResult::kRecordInvalid);
  assert(sites.render_char == 0u);
}

// Each targeted-render proof, broken alone, installs nothing (both codegens).
void TestTargetedRenderEachProofFailsClosed() {
  using Apply = void (*)(SyntheticImage*, const TargetedCodegen&);
  struct Breaker {
    Apply apply;
    core::SiteResult expected;
  };
  const Breaker breakers[] = {
      // A second RenderChar is ambiguous.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->Put(0x5000u, core::kRenderTBytes, sizeof(core::kRenderTBytes));
       },
       core::SiteResult::kPageMissing},
      // Record offsets moved / GetCharImage through another slot / the code
      // from another record field / the epilogue pops another argument count.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kRenderT + core::kRecordPenTOffset + 25u] = 0x18u;
       },
       core::SiteResult::kRecordInvalid},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         img->base[kRenderT + kRecordCharOffsetT + cg.record_char_bytes - 1u] =
             0x08u;
       },
       core::SiteResult::kRecordInvalid},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         img->base[kRenderT + kRecordCharOffsetT + cg.record_char_bytes -
                   10u] = 0x06u;
       },
       core::SiteResult::kRecordInvalid},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         img->base[kRenderT + cg.render_tail + 7u] = 0x04u;
       },
       core::SiteResult::kRecordInvalid},
      // No epilogue within the body bound.
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         std::memset(img->base + kRenderT + cg.render_tail, 0x90,
                     sizeof(core::kRenderTailTBytes));
       },
       core::SiteResult::kRecordInvalid},
      // An earlier epilogue ends the body before the GetCharImage call.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->Put(kRenderT + kRecordCharOffsetT - 0x10u,
                  core::kRenderTailTBytes, sizeof(core::kRenderTailTBytes));
       },
       core::SiteResult::kRecordInvalid},
      // No vtable names GetCharImage (the locator slot is code: not a vtable
      // start), or the function does not start after padding.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->Pointer(kVtableT, 0x1830u);
       },
       core::SiteResult::kRasteriserInvalid},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kCharImageT - 1u] = 0x90u;
       },
       core::SiteResult::kRasteriserInvalid},
      // GetCharImage reaches the rasteriser only once.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         std::memset(img->base + kCharImageT + 0x60u, 0xcc, 5u);
       },
       core::SiteResult::kRasteriserInvalid},
      // A second, different function passing the proof is ambiguous.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->Rel32(0x1c00u + 0x20u, kRasterT);
         img->Rel32(0x1c00u + 0x60u, kRasterT);
         img->Pointer(kVtableT + 0x40u, kLocatorT);
         img->Pointer(kVtableT + 0x44u, 0x1820u);
         img->Pointer(kVtableT + 0x48u, 0x1c00u);
       },
       core::SiteResult::kRasteriserInvalid},
      // Update missing, its renderer field implausible, two Updates whose
      // reveal both render; reveal does not render; sync does not hand the
      // page to a screen.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kUpdateT + 43u] = 0x8fu;
       },
       core::SiteResult::kUpdateMissing},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         const uint32_t absurd = 0x12345u;
         std::memcpy(img->base + kUpdateT + core::kUpdateTRendererDisp,
                     &absurd, 4u);
       },
       core::SiteResult::kUpdateMissing},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         PutUpdate(img, cg, kDecoyUpdateT, kRevealT);
       },
       core::SiteResult::kUpdateMissing},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         std::memset(img->base + kRevealT + 0x40u, 0xcc, 5u);
       },
       core::SiteResult::kRevealInvalid},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kSyncT + 0x33u] = 0x51u;
       },
       core::SiteResult::kSyncInvalid},
      // ClearPage missing, fills through two helpers, a page height that is
      // not width + 4, nobody calls it through the window's renderer, or a
      // second ClearPage-shaped body whose caller also reveals (ambiguous).
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kClearT + 63u] = 0x77u;
       },
       core::SiteResult::kClearInvalid},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->Rel32(kClearT + kClearFillFadeCall, 0x1820u);
       },
       core::SiteResult::kClearInvalid},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         for (const size_t at : {kClearPageHeight, kClearPageHeight + 24u}) {
           img->base[kClearT + at] =
               static_cast<uint8_t>(img->base[kClearT + at] + 4u);
         }
       },
       core::SiteResult::kClearInvalid},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->Rel32(kClearCallT + core::kClearCallTCall, 0x1850u);
       },
       core::SiteResult::kClearInvalid},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         PutClear(img, cg, kDecoyClearT, 0x1820u);
         PutClearCaller(img, kDecoyClearCallT, cg.window_renderer,
                        kDecoyClearT, kRevealT);
         PutClearCaller(img, kClearCallT, cg.window_renderer, kClearT,
                        kRevealT);
       },
       core::SiteResult::kClearInvalid},
      // Layer query missing / naming another screen field than SyncLayer /
      // disagreeing copies.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kLayerQueryT + 12u] = 0x08u;
       },
       core::SiteResult::kLayerQueryMissing},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         img->base[kSyncT + 0x32u] =
             static_cast<uint8_t>(cg.window_screen + 4u);
       },
       core::SiteResult::kLayerQueryMissing},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         PutLayerQuery(img, cg, 0x5800u, 0x1850u);
       },
       core::SiteResult::kLayerQueryMissing},
      // Scene layout differs along the chain, or the draw loop is missing.
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         img->base[kScreenQueryT + ScreenQuerySceneCall(cg) - 5u] = 0x0cu;
       },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kSceneVisibleT + 18u] = 0x08u;
       },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         ++img->base[kSceneFindT + cg.scene_find_map];
       },
       core::SiteResult::kSceneInvalid},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kSceneDrawT + 49u] = 0x0cu;
       },
       core::SiteResult::kSceneInvalid},
      // Input handler missing (dispatch on another bound, message from
      // another argument) / without capture imports.
      {[](SyntheticImage* img, const TargetedCodegen& cg) {
         img->base[kInputT + cg.input_prologue_bytes + 3u] = 0x01u;
       },
       core::SiteResult::kInputMissing},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kInputT + kInputMessageDisp] = 0x14u;
       },
       core::SiteResult::kInputMissing},
      {[](SyntheticImage* img, const TargetedCodegen&) {
         std::memset(img->base + kInputT + 0x300u, 0xcc, 6u);
       },
       core::SiteResult::kInputImportsInvalid},
      // Handle pops another number of arguments than the detour would.
      {[](SyntheticImage* img, const TargetedCodegen&) {
         img->base[kInputT + 0x5aeu] = 0x14u;
       },
       core::SiteResult::kInputFrameInvalid},
  };
  for (const TargetedCodegen* cg : kTargetedCodegens) {
    size_t index = 0u;
    for (const Breaker& breaker : breakers) {
      SyntheticImage img;
      BuildEngineT(&img, *cg);
      breaker.apply(&img, *cg);
      core::Sites sites;
      sites.render_char = 1u;
      const auto result = core::ResolveSites(img.image, Imports(), &sites);
      if (result != breaker.expected) {
        std::fprintf(stderr, "targeted %s breaker %zu: expected %u got %u\n",
                     cg->name, index, static_cast<unsigned>(breaker.expected),
                     static_cast<unsigned>(result));
      }
      assert(result == breaker.expected);
      assert(sites.render_char == 0u && sites.clear_page == 0u &&
             sites.window_update == 0u && sites.input_handler == 0u &&
             sites.variant == core::SiteVariant::kNone);
      ++index;
    }
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
