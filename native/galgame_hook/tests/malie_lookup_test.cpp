// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <string>
#include <vector>

#include "malie_lookup_core.h"

namespace ml = fushi_voice_hook::malie_lookup;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

constexpr uintptr_t kAbsoluteBase = 0x00400000u;
constexpr size_t kCodeBytes = 0x8000u;
constexpr size_t kDataRva = 0x8000u;

class SyntheticImage {
 public:
  static constexpr size_t kSize = 0x10000u;
  explicit SyntheticImage(WORD machine = IMAGE_FILE_MACHINE_I386,
                          uint32_t bits = 32u) {
    base = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE));
    assert(base != nullptr);
    std::memset(base, 0xcc, kCodeBytes);
    std::memset(base + kDataRva, 0, kSize - kDataRva);
    image.base = base;
    image.size = kSize;
    image.absolute_base = kAbsoluteBase;
    image.machine = machine;
    image.pointer_bits = bits;
    image.section_count = 2u;
    image.sections[0] = {base, kCodeBytes, 0u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {base + kDataRva, kSize - kDataRva,
                         static_cast<uint32_t>(kDataRva), IMAGE_SCN_MEM_READ};
  }
  ~SyntheticImage() { VirtualFree(base, 0u, MEM_RELEASE); }
  SyntheticImage(const SyntheticImage&) = delete;
  SyntheticImage& operator=(const SyntheticImage&) = delete;

  size_t Put(size_t rva, std::initializer_list<uint8_t> bytes) {
    for (uint8_t b : bytes) base[rva++] = b;
    return rva;
  }
  size_t PutBytes(size_t rva, const uint8_t* bytes, size_t size) {
    std::memcpy(base + rva, bytes, size);
    return rva + size;
  }
  size_t Abs(size_t rva, size_t target_rva) {
    const uint32_t absolute =
        static_cast<uint32_t>(kAbsoluteBase + target_rva);
    std::memcpy(base + rva, &absolute, 4u);
    return rva + 4u;
  }
  size_t Imm32(size_t rva, uint32_t value) {
    std::memcpy(base + rva, &value, 4u);
    return rva + 4u;
  }
  size_t Rel32(size_t at, size_t target) {
    base[at] = 0xe8u;
    const int32_t rel = static_cast<int32_t>(static_cast<intptr_t>(target) -
                                             static_cast<intptr_t>(at + 5u));
    std::memcpy(base + at + 1u, &rel, 4u);
    return at + 5u;
  }
  void Wide(size_t rva, const wchar_t* text) {
    std::memcpy(base + rva, text, (wcslen(text) + 1u) * sizeof(wchar_t));
  }
  uintptr_t At(size_t rva) const {
    return reinterpret_cast<uintptr_t>(base + rva);
  }

  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

constexpr size_t kClassFn = 0x1000u;
constexpr size_t kMethodA = 0x1200u;
constexpr size_t kDraw = 0x1400u;
constexpr size_t kReveal = 0x2000u;
constexpr size_t kParser = 0x2100u;
constexpr size_t kTokenizer = 0x2200u;
constexpr size_t kProgress = 0x2300u;
constexpr size_t kName = kDataRva + 0x40u;

struct DrawOptions {
  uint32_t stride = 0x34u;
  bool dash = true;
  uint32_t reveal_end = 0xa8u;
  bool translate = true;
};

// The measured draw method, reduced to the decoded instructions.
void PutDraw(SyntheticImage* img, const DrawOptions& o = DrawOptions()) {
  size_t at = img->Put(kDraw, {0x55, 0x8b, 0xec, 0x83, 0xec, 0x64});
  if (o.translate) {
    at = img->Put(at, {0xf3, 0x0f, 0x10, 0x80});
    at = img->Imm32(at, 0x98u);
    at = img->Put(at, {0xf3, 0x0f, 0x10, 0x80});
    at = img->Imm32(at, 0x94u);
    at = img->Put(at, {0xf3, 0x0f, 0x10, 0x80});
    at = img->Imm32(at, 0x90u);
  }
  // mov ecx,[ebx+0x1c]; xor esi,esi; mov eax,[ecx+0x88]; mov [ebp-0x5c],eax;
  // test eax,eax; jle
  at = img->Put(at, {0x8b, 0x4b, 0x1c, 0x33, 0xf6, 0x8b, 0x81});
  at = img->Imm32(at, 0x88u);
  at = img->Put(at, {0x89, 0x45, 0xa4, 0x85, 0xc0, 0x0f, 0x8e, 0x20, 0x02,
                     0x00, 0x00});
  if (o.dash) at = img->Put(at, {0xbb, 0x15, 0x20, 0x00, 0x00});
  at = img->Put(at, {0x8b, 0x81});
  at = img->Imm32(at, 0x8cu);
  at = img->Put(at, {0x83, 0x3c, 0xb0, 0x00, 0x0f, 0x84, 0xd0, 0x01, 0x00,
                     0x00, 0x8b, 0x91});
  at = img->Imm32(at, 0x84u);
  at = img->Put(at, {0x66, 0x39, 0x1c, 0x3a, 0x75, 0x43, 0x66, 0x81, 0x7c,
                     0x3a, static_cast<uint8_t>(o.stride), 0x15, 0x20});
  at = img->Put(at, {0x3b, 0xb1});
  at = img->Imm32(at, 0xa4u);
  at = img->Put(at, {0x7d, 0x02, 0x3b, 0xb1});
  at = img->Imm32(at, o.reveal_end);
  img->Put(at, {0x8b, 0xe5, 0x5d, 0xc3});
}

void PutClass(SyntheticImage* img) {
  img->Wide(kName, L"RICHTEXT3D");
  size_t at = img->Put(kClassFn, {0x55, 0x8b, 0xec, 0x33, 0xc9, 0x0f, 0xb7,
                                  0x81});
  at = img->Abs(at, kName);
  at = img->Put(at, {0x8d, 0x49, 0x02, 0xc7, 0x45, 0xc0});
  at = img->Abs(at, kMethodA);
  at = img->Put(at, {0xc7, 0x45, 0xd4});
  at = img->Abs(at, kDraw);
  img->Put(at, {0x5d, 0xc3});
  img->Put(kMethodA, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
}

void PutSegment(SyntheticImage* img, uint32_t reveal_field = 0xa4u) {
  size_t at = img->Put(kReveal, {0x55, 0x8b, 0xec, 0x8b, 0x55, 0x08, 0x85,
                                 0xd2, 0x74, 0x18, 0x8b, 0x4a, 0x1c, 0x8b,
                                 0x45, 0x0c, 0x89, 0x81});
  at = img->Imm32(at, reveal_field);
  at = img->Put(at, {0x8b, 0x4a, 0x1c, 0x8b, 0x45, 0x10, 0x89, 0x81});
  at = img->Imm32(at, reveal_field + 4u);
  img->Put(at, {0x5d, 0xc3});
  img->PutBytes(kParser, ml::kParserBytes, sizeof(ml::kParserBytes));
  img->Rel32(kParser + 33u, kTokenizer);
  img->Put(kTokenizer, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
  // progress: call parser; ...; call reveal
  at = img->Put(kProgress, {0x55, 0x8b, 0xec, 0x53});
  at = img->Rel32(at, kParser);
  at = img->Put(at, {0x83, 0xc4, 0x0c, 0x90, 0x90});
  at = img->Rel32(at, kReveal);
  img->Put(at, {0x5b, 0x5d, 0xc3});
}

void TestDrawResolves() {
  SyntheticImage img;
  PutClass(&img);
  PutDraw(&img);
  ml::DrawSites sites;
  assert(ml::ResolveDraw(img.image, &sites) == ml::DrawResult::kResolved);
  assert(sites.draw == img.At(kDraw));
  assert(sites.data_field == 0x1cu && sites.glyphs == 0x84u &&
         sites.count == 0x88u && sites.textures == 0x8cu &&
         sites.stride == 0x34u && sites.reveal_start == 0xa4u &&
         sites.reveal_end == 0xa8u && sites.translate == 0x90u);

  PutSegment(&img);
  ml::SegmentSites segment;
  assert(ml::ResolveSegment(img.image, sites, &segment) ==
         ml::SegmentResult::kResolved);
  assert(segment.parser == img.At(kParser));
  assert(segment.reveal == img.At(kReveal));
}

void TestDrawFailsClosed() {
  ml::DrawSites sites;
  {
    SyntheticImage img(IMAGE_FILE_MACHINE_AMD64, 64u);
    PutClass(&img);
    PutDraw(&img);
    assert(ml::ResolveDraw(img.image, &sites) == ml::DrawResult::kNotX86);
  }
  {  // no class name
    SyntheticImage img;
    PutClass(&img);
    PutDraw(&img);
    img.Wide(kName, L"RICHTEXT2D");
    assert(ml::ResolveDraw(img.image, &sites) == ml::DrawResult::kNoClassName);
  }
  {  // the draw method is not a method of the class
    SyntheticImage img;
    PutClass(&img);
    PutDraw(&img);
    img.Abs(kClassFn + 8u + 4u + 6u + 4u + 3u, kMethodA);
    assert(ml::ResolveDraw(img.image, &sites) == ml::DrawResult::kNoDrawMethod);
  }
  {  // no U+2015 run handling: not the glyph pass
    SyntheticImage img;
    PutClass(&img);
    DrawOptions o;
    o.dash = false;
    PutDraw(&img, o);
    assert(ml::ResolveDraw(img.image, &sites) != ml::DrawResult::kResolved);
  }
  {  // reveal end is not start + 4
    SyntheticImage img;
    PutClass(&img);
    DrawOptions o;
    o.reveal_end = 0xb0u;
    PutDraw(&img, o);
    assert(ml::ResolveDraw(img.image, &sites) == ml::DrawResult::kRevealShape);
  }
  {  // no translation loads
    SyntheticImage img;
    PutClass(&img);
    DrawOptions o;
    o.translate = false;
    PutDraw(&img, o);
    assert(ml::ResolveDraw(img.image, &sites) ==
           ml::DrawResult::kTranslateShape);
  }
}

void TestSegmentFailsClosed() {
  SyntheticImage img;
  PutClass(&img);
  PutDraw(&img);
  ml::DrawSites sites;
  assert(ml::ResolveDraw(img.image, &sites) == ml::DrawResult::kResolved);
  ml::SegmentSites segment;
  {  // reveal setter writes other fields than the draw reads
    SyntheticImage other;
    PutClass(&other);
    PutDraw(&other);
    PutSegment(&other, 0xb0u);
    assert(ml::ResolveSegment(other.image, sites, &segment) ==
           ml::SegmentResult::kRevealFieldMismatch);
  }
  {  // parser with two callers
    SyntheticImage other;
    PutSegment(&other);
    other.Rel32(0x3000u, kParser);
    assert(ml::ResolveSegment(other.image, sites, &segment) ==
           ml::SegmentResult::kParserCallers);
  }
  {  // the parser's caller never reveals
    SyntheticImage other;
    PutSegment(&other);
    std::memset(other.base + kProgress + 4u + 5u + 5u, 0x90, 5u);
    assert(ml::ResolveSegment(other.image, sites, &segment) ==
           ml::SegmentResult::kNoRevealAfterParse);
  }
  {  // no parser
    SyntheticImage other;
    PutSegment(&other);
    other.Put(kParser + 3u, {0x90});
    assert(ml::ResolveSegment(other.image, sites, &segment) ==
           ml::SegmentResult::kNoParser);
  }
}

void TestCleanSegment() {
  const std::wstring raw =
      std::wstring(L"\x07\x08v_vir0004", 11) + std::wstring(1, L'\0') +
      std::wstring(L"\x07\x01", 2) + L"\x95c7\x306e\x8cdc\x7269" + L"\n" +
      L"\x30ad\x30c3\x30b9" + std::wstring(1, L'\0') +
      L"\x2026\x2026\x4eca\x591c\x3002\x07\x09\x300d\x07\x06";
  ml::Segment segment;
  assert(ml::CleanSegment(raw.data(), raw.size(), &segment));
  assert(segment.voice == L"v_vir0004");
  assert(segment.line ==
         L"\x95c7\x306e\x8cdc\x7269\x2026\x2026\x4eca\x591c\x3002\x300d");
  assert(!segment.markup);
  // Line breaks are not glyphs; an unknown code marks the unit.
  const std::wstring narration = std::wstring(L"\x3000\x5099\n\x3048\x07\x7f", 6);
  assert(ml::CleanSegment(narration.data(), narration.size(), &segment));
  assert(segment.line == L"\x3000\x5099\x3048");
  assert(segment.voice.empty());
  assert(segment.markup);
  assert(!ml::CleanSegment(L"\x07\x06", 2u, &segment));

  assert(ml::VoiceKeyFromPath(L".\\data\\voice\\vir\\V_VIR0004.ogg") ==
         L"v_vir0004");
  assert(ml::VoiceKey(L"V_vir0004") == L"v_vir0004");
}

void TestMapLine() {
  // glyphs: [0..2) earlier unit, then 闇 の (ruby キ ス) 賜 。
  const uint16_t codes[] = {0x3042, 0x3044, 0x95c7, 0x306e, 0x30ad,
                            0x30b9, 0x8cdc, 0x3002};
  uint16_t map[8] = {};
  assert(ml::MapLine(codes, 2u, 6u, L"\x95c7\x306e\x8cdc\x3002", map));
  assert(map[0] == 2u && map[1] == 3u && map[2] == 6u && map[3] == 7u);
  // A unit character missing from the range fails.
  assert(!ml::MapLine(codes, 2u, 6u, L"\x95c7\x3042", map));
  // The range is the unit's own glyphs only.
  assert(!ml::MapLine(codes, 3u, 5u, L"\x95c7", map));
  // A leading full-width space takes its glyph when present, else none.
  const uint16_t spaced[] = {0x3000, 0x5099};
  assert(ml::MapLine(spaced, 0u, 2u, L"\x3000\x5099", map));
  assert(map[0] == 0u && map[1] == 1u);
  const uint16_t unspaced[] = {0x5099};
  assert(ml::MapLine(unspaced, 0u, 1u, L"\x3000\x5099", map));
  assert(map[0] == ml::kNoGlyph && map[1] == 0u);
}

void TestProjection() {
  float parent[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 100, 400, 0, 1};
  const float t[3] = {20.0f, 10.0f, 0.0f};
  ml::Affine world;
  assert(ml::ComposeWorld(t, parent, &world));
  const int32_t box[4] = {0, 0, 24, 28};
  ml::DesignRect design;
  assert(ml::GlyphDesignRect(world, box, &design));
  assert(design.x0 == 120.0 && design.y0 == 410.0 && design.x1 == 144.0 &&
         design.y1 == 438.0);
  ml::PixelRect pixels;
  assert(ml::ProjectDesign(design, 1024, 600, 2048, 1200, &pixels));
  assert(pixels.x == 240 && pixels.y == 820 && pixels.w == 48 &&
         pixels.h == 56);
  // Outside the design screen, rotated or skewed transforms fail.
  ml::DesignRect outside = {1000.0, 590.0, 1030.0, 610.0};
  assert(!ml::ProjectDesign(outside, 1024, 600, 2048, 1200, &pixels));
  parent[1] = 0.5f;
  assert(!ml::ComposeWorld(t, parent, &world));
  parent[1] = 0.0f;
  parent[0] = -1.0f;
  assert(!ml::ComposeWorld(t, parent, &world));
  assert(ml::ClientMatchesDesign(2048, 1200, 1024, 600));
  assert(!ml::ClientMatchesDesign(2048, 1536, 1024, 600));
  // Windowed: the design is stretched over the client (measured 1.25 x 1.2).
  assert(ml::ClientScaleAdmitted(1280, 720, 1024, 600, false));
  assert(ml::ProjectDesign(design, 1024, 600, 1280, 720, &pixels));
  assert(pixels.x == 150 && pixels.y == 492 && pixels.w == 30 &&
         pixels.h == 34);
  // Covering the monitor: only the design aspect (a presenter may letterbox).
  assert(!ml::ClientScaleAdmitted(1280, 720, 1024, 600, true));
  assert(ml::ClientScaleAdmitted(2048, 1200, 1024, 600, true));
  assert(!ml::ClientScaleAdmitted(100, 100, 1024, 600, false));

  const ml::PixelRect boxes[] = {{0, 0, 10, 10}, {10, 0, 10, 10},
                                 {5, 5, 10, 10}};
  assert(ml::HitTest(boxes, 2u, 3, 3) == 0);
  assert(ml::HitTest(boxes, 2u, 12, 3) == 1);
  assert(ml::HitTest(boxes, 2u, 30, 3) == -1);
  assert(ml::HitTest(boxes, 3u, 7, 7) == -1);  // two boxes: ambiguous
}

void TestClaim() {
  ml::ClaimState claim;
  auto d = ml::DecideMessage(WM_LBUTTONDOWN, true, &claim);
  assert(d.swallow && d.submit && claim.owned);
  d = ml::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(d.swallow && !d.submit && !claim.owned);
  d = ml::DecideMessage(WM_LBUTTONDOWN, false, &claim);
  assert(!d.swallow && !d.submit);
  d = ml::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(!d.swallow);
  d = ml::DecideMessage(WM_LBUTTONDBLCLK, true, &claim);
  assert(d.swallow && d.submit);
}

}  // namespace

namespace {

// Click-window binding: a rejection holds only for that window + procedure.
void TestWindowStep() {
  ml::WindowBindingState state;
  assert(ml::DecideWindowStep(ml::WindowCandidate(), state) ==
         ml::WindowStep::kWait);

  // A movie / splash child whose procedure is not the game's.
  ml::WindowCandidate splash;
  splash.window = 0x1000u;
  splash.procedure = 0x7ff00000u;
  splash.in_image = false;
  assert(ml::DecideWindowStep(splash, state) == ml::WindowStep::kReject);
  state.rejected_window = splash.window;
  state.rejected_procedure = splash.procedure;
  assert(ml::DecideWindowStep(splash, state) == ml::WindowStep::kWait);

  // The game's client child appears later: evaluated, hooked, bound.
  ml::WindowCandidate game;
  game.window = 0x2000u;
  game.procedure = 0x401000u;
  game.in_image = true;
  assert(ml::DecideWindowStep(game, state) == ml::WindowStep::kHook);
  state.hooked[state.hooked_count++] = game.procedure;
  state.bound = game.window;
  state.bound_alive = true;
  assert(ml::DecideWindowStep(splash, state) == ml::WindowStep::kKeep);

  // Destroyed and recreated with the same procedure: re-bound, not re-hooked.
  state.bound_alive = false;
  ml::WindowCandidate again = game;
  again.window = 0x3000u;
  assert(ml::DecideWindowStep(again, state) == ml::WindowStep::kBind);
  // Same window, but its procedure was replaced: evaluated again.
  state.rejected_window = again.window;
  state.rejected_procedure = 0x405000u;
  assert(ml::DecideWindowStep(again, state) == ml::WindowStep::kBind);

  // Detour slots exhausted: a new procedure is rejected.
  state.hooked[state.hooked_count++] = 0x402000u;
  state.hooked[state.hooked_count++] = 0x403000u;
  state.hooked[state.hooked_count++] = 0x404000u;
  ml::WindowCandidate fifth = game;
  fifth.window = 0x4000u;
  fifth.procedure = 0x406000u;
  assert(ml::DecideWindowStep(fifth, state) == ml::WindowStep::kReject);
  assert(ml::WindowProcedureHooked(state, 0x404000u));
  assert(!ml::WindowProcedureHooked(state, 0x406000u));
}

}  // namespace

int main() {
  TestWindowStep();
  TestDrawResolves();
  TestDrawFailsClosed();
  TestSegmentFailsClosed();
  TestCleanSegment();
  TestMapLine();
  TestProjection();
  TestClaim();
  std::printf("malie_lookup_test: ok\n");
  return 0;
}
