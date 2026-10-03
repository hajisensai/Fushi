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

#include "fvp_lookup_core.h"

namespace core = fushi_voice_hook::fvp_lookup;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

// ── synthetic x86 image: code [0, 0x8000), read-only data [0x8000, 0x10000) ─

constexpr uintptr_t kAbsoluteBase = 0x00400000u;
constexpr size_t kCodeEnd = 0x8000u;

class SyntheticImage {
 public:
  static constexpr size_t kSize = 0x10000u;
  explicit SyntheticImage(WORD machine = IMAGE_FILE_MACHINE_I386,
                          uint32_t bits = 32u) {
    base = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kSize, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    assert(base != nullptr);
    std::memset(base, 0xcc, kCodeEnd);
    std::memset(base + kCodeEnd, 0x00, kSize - kCodeEnd);
    image.base = base;
    image.size = kSize;
    image.absolute_base = kAbsoluteBase;
    image.machine = machine;
    image.pointer_bits = static_cast<uint8_t>(bits);
    image.section_count = 2u;
    image.sections[0] = {base, kCodeEnd, 0u,
                         IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    image.sections[1] = {base + kCodeEnd, kSize - kCodeEnd,
                         static_cast<uint32_t>(kCodeEnd), IMAGE_SCN_MEM_READ};
  }
  ~SyntheticImage() { VirtualFree(base, 0u, MEM_RELEASE); }
  SyntheticImage(const SyntheticImage&) = delete;
  SyntheticImage& operator=(const SyntheticImage&) = delete;

  void Put(size_t rva, const uint8_t* bytes, size_t size) {
    assert(rva + size <= kSize);
    std::memcpy(base + rva, bytes, size);
  }
  void Put(size_t rva, std::initializer_list<uint8_t> bytes) {
    size_t at = rva;
    for (uint8_t byte : bytes) base[at++] = byte;
  }
  void Dword(size_t rva, uint32_t value) { std::memcpy(base + rva, &value, 4); }
  void Va(size_t rva, size_t target_rva) {
    Dword(rva, static_cast<uint32_t>(kAbsoluteBase + target_rva));
  }
  void Rel32(size_t at, size_t target) {  // `e8 rel32` at `at`
    base[at] = 0xe8u;
    const int32_t rel = static_cast<int32_t>(static_cast<intptr_t>(target) -
                                             static_cast<intptr_t>(at + 5u));
    std::memcpy(base + at + 1u, &rel, 4u);
  }
  void PutShape(size_t rva, const core::Shape& shape) {
    Put(rva, shape.bytes, shape.size);
  }

  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

// Synthetic engine layout (RVAs).
constexpr size_t kRegister = 0x0100u;
constexpr size_t kRegTextPrint = 0x0200u;
constexpr size_t kRegPrimSetText = 0x0240u;
constexpr size_t kTextPrintHandler = 0x0400u;
constexpr size_t kPrint = 0x0600u;
constexpr size_t kLayout = 0x0800u;
constexpr size_t kPutGlyph = 0x0a00u;
constexpr size_t kPrimSetTextHandler = 0x0c00u;
constexpr size_t kRenderCase = 0x0e00u;
constexpr size_t kDraw = 0x1000u;
constexpr size_t kRegAudioPlay = 0x0280u;
constexpr size_t kAudioPlayHandler = 0x1400u;
constexpr size_t kChannelPlay = 0x1500u;
constexpr size_t kSoundLoad = 0x1600u;
constexpr size_t kNameAudioPlay = 0x8141u;
constexpr size_t kNameTextPrint = 0x8101u;
constexpr size_t kNamePrimSetText = 0x8121u;
constexpr size_t kVmGlobal = 0x8200u;
constexpr uint32_t kTextArray = 0x98u;
constexpr uint8_t kPrimTextField = 0x32u;

struct BuildOptions {
  bool put_glyph_shape = true;
  bool render_array_matches = true;
  bool second_text_print_registration = false;
  bool scale_shape = true;
};

void Build(SyntheticImage* img, const BuildOptions& options = {}) {
  img->Put(kRegister, {0xc2, 0x0c, 0x00});
  std::memcpy(img->base + kNameTextPrint, "TextPrint", 10u);
  std::memcpy(img->base + kNamePrimSetText, "PrimSetText", 12u);

  // TextPrint registration: mov ecx,handler; mov [eax],ecx; push 2;
  // push name; mov ecx,esi; call Register.
  img->Put(kRegTextPrint, {0xb9});
  img->Va(kRegTextPrint + 1u, kTextPrintHandler);
  img->Put(kRegTextPrint + 5u, {0x89, 0x08, 0x6a, 0x02, 0x68});
  img->Va(kRegTextPrint + 10u, kNameTextPrint);
  img->Put(kRegTextPrint + 14u, {0x8b, 0xce});
  img->Rel32(kRegTextPrint + 16u, kRegister);
  // PrimSetText registration with interleaved stores (edx).
  img->Put(kRegPrimSetText, {0xba});
  img->Va(kRegPrimSetText + 1u, kPrimSetTextHandler);
  img->Put(kRegPrimSetText + 5u, {0x89, 0x10, 0x6a, 0x04, 0x68});
  img->Va(kRegPrimSetText + 10u, kNamePrimSetText);
  img->Put(kRegPrimSetText + 14u, {0x8b, 0xce, 0x89, 0x58, 0x0c});
  img->Rel32(kRegPrimSetText + 19u, kRegister);
  if (options.second_text_print_registration) {
    img->Put(0x0300u, {0x68});
    img->Va(0x0301u, kNameTextPrint);
    img->Put(0x0305u, {0x8b, 0xce});
    img->Rel32(0x0307u, kRegister);
  }

  // TextPrint handler.
  img->PutShape(kTextPrintHandler + 0x20u, core::kBufferLoad);
  img->Va(kTextPrintHandler + 0x20u + core::kBufferLoadGlobalByte, kVmGlobal);
  img->Dword(kTextPrintHandler + 0x20u + core::kBufferLoadArrayByte,
             kTextArray);
  img->PutShape(kTextPrintHandler + 0x40u, core::kLengthBound);
  img->PutShape(kTextPrintHandler + 0x60u, core::kPrintCall);
  img->Rel32(kTextPrintHandler + 0x63u, kPrint);

  // Print → Layout → PutGlyph (twice).
  img->PutShape(kPrint + 0x20u, core::kLayoutCall);
  img->Rel32(kPrint + 0x28u, kLayout);
  img->Put(kLayout, {0x6a, 0xff});
  img->Rel32(kLayout + 0x30u, kPutGlyph);
  img->Rel32(kLayout + 0x80u, kPutGlyph);
  img->PutShape(kPutGlyph, core::kPutGlyph);
  img->Dword(kPutGlyph + core::kPutGlyphPenYByte, 0x5eau);
  img->Dword(kPutGlyph + core::kPutGlyphAdvanceByte, 0x6600u);
  img->Dword(kPutGlyph + core::kPutGlyphPenXByte, 0x5e8u);
  if (!options.put_glyph_shape) img->base[kPutGlyph + 40u] = 0x90u;

  // PrimSetText handler.
  img->PutShape(kPrimSetTextHandler + 0x10u, core::kPrimType);
  img->PutShape(kPrimSetTextHandler + 0x30u, core::kPrimField);
  img->base[kPrimSetTextHandler + 0x30u + core::kPrimFieldByte] =
      kPrimTextField;

  // Render walk, text case.
  img->PutShape(kRenderCase, core::kRenderText);
  img->base[kRenderCase + core::kRenderTextFieldByte] = kPrimTextField;
  img->Va(kRenderCase + core::kRenderTextGlobalByte, kVmGlobal);
  img->Dword(kRenderCase + core::kRenderTextArrayByte,
             options.render_array_matches ? kTextArray : 0x9cu);
  img->base[kRenderCase + core::kRenderTextSurfaceByte] = 0x04u;
  img->Rel32(kRenderCase + core::kRenderTextCallByte, kDraw);

  // DrawSprite.
  img->PutShape(kDraw, core::kDrawPrologue);
  img->Dword(kDraw + core::kDrawReadyByte, 0x508u);
  img->PutShape(kDraw + 0x40u, core::kTranslate);
  img->Dword(kDraw + 0x40u + core::kTranslateSurfaceYByte, 0x51au);
  img->base[kDraw + 0x40u + core::kTranslatePrimYByte] = 0x16u;
  img->Dword(kDraw + 0x40u + core::kTranslateSurfaceXByte, 0x518u);
  img->base[kDraw + 0x40u + core::kTranslatePrimXByte] = 0x14u;
  if (options.scale_shape) {
    img->PutShape(kDraw + 0x80u, core::kScale);
    img->base[kDraw + 0x80u + core::kScaleXByte] = 0x26u;
    img->base[kDraw + 0x80u + core::kScaleYByte] = 0x28u;
  }
  img->Put(kDraw + 0xa0u, {0x0f, 0xb7, 0x47, 0x24});
  img->Put(kDraw + 0xb0u, {0x66, 0x85, 0xc0, 0x74});
  img->Put(kDraw + 0xc0u, core::kFlagTest1, 4u);
  img->Put(kDraw + 0xc8u, core::kFlagTest2, 4u);
  img->Put(kDraw + 0xd0u, core::kFlagTest4, 4u);
  img->Put(kDraw + 0xd8u, core::kAlphaLoad, 4u);
  img->PutShape(kDraw + 0xe0u, core::kDesign);
  img->Va(kDraw + 0xe0u + core::kDesignGlobalByte, kVmGlobal);
  img->base[kDraw + 0xe0u + core::kDesignHeightByte] = 0x64u;
  img->base[kDraw + 0xe0u + core::kDesignWidthByte] = 0x60u;
}

void BuildAudio(SyntheticImage* img, bool ogg_check = true,
                uint32_t global = static_cast<uint32_t>(kVmGlobal)) {
  std::memcpy(img->base + kNameAudioPlay, "AudioPlay", 10u);
  img->Put(kRegAudioPlay, {0xba});
  img->Va(kRegAudioPlay + 1u, kAudioPlayHandler);
  img->Put(kRegAudioPlay + 5u, {0x89, 0x10, 0x6a, 0x02, 0x68});
  img->Va(kRegAudioPlay + 10u, kNameAudioPlay);
  img->Put(kRegAudioPlay + 14u, {0x8b, 0xce});
  img->Rel32(kRegAudioPlay + 16u, kRegister);
  // Handler: bound the channel, load it from the VM array, call ChannelPlay
  // on both branches.
  img->Put(kAudioPlayHandler, {0x83, 0xf8, 0x03, 0x7f, 0x2e});
  img->PutShape(kAudioPlayHandler + 0x10u, core::kAudioChannelLoad);
  img->Va(kAudioPlayHandler + 0x10u + core::kAudioChannelLoadGlobalByte,
          global);
  img->Rel32(kAudioPlayHandler + 0x30u, kChannelPlay);
  img->Put(kAudioPlayHandler + 0x35u, {0xc2, 0x04, 0x00, 0x6a, 0x01});
  img->Rel32(kAudioPlayHandler + 0x3au, kChannelPlay);
  img->Put(kAudioPlayHandler + 0x3fu, {0xc2, 0x04, 0x00, 0xcc});
  img->PutShape(kChannelPlay + 0x10u, core::kChannelPlay);
  img->base[kChannelPlay + 0x10u + core::kChannelPlayNameByte] = 0x0cu;
  img->Va(kChannelPlay + 0x10u + core::kChannelPlayGlobalByte, global);
  img->Va(kChannelPlay + 0x10u + core::kChannelPlayGlobal2Byte, global);
  img->Dword(kChannelPlay + 0x10u + core::kChannelPlaySizeByte, 0x65cb0cu);
  img->Dword(kChannelPlay + 0x10u + core::kChannelPlayBufferByte, 0x65cb08u);
  img->base[kChannelPlay + 0x10u + core::kChannelPlaySoundByte] = 0x04u;
  img->Rel32(kChannelPlay + 0x10u + core::kChannelPlayCallByte - 1u + 1u,
             kSoundLoad);
  img->PutShape(kSoundLoad, core::kSoundLoad);
  if (ogg_check) img->Put(kSoundLoad + 0x40u, core::kSoundLoadOgg, 6u);
}

void TestAudio() {
  {
    SyntheticImage img;
    Build(&img);
    BuildAudio(&img);
    core::AudioSites sites;
    const auto result = core::ResolveAudioSites(img.image, kVmGlobal, &sites);
    if (result != core::AudioSiteResult::kResolved) {
      std::printf("audio result %u\n", static_cast<unsigned>(result));
    }
    assert(result == core::AudioSiteResult::kResolved);
    assert(sites.audio_play_handler == kAudioPlayHandler);
    assert(sites.channel_play == kChannelPlay);
    assert(sites.sound_load == kSoundLoad);
    assert(sites.channel_name == 0x0cu);
  }
  {  // The decoder input must sniff Ogg.
    SyntheticImage img;
    Build(&img);
    BuildAudio(&img, false);
    core::AudioSites sites;
    assert(core::ResolveAudioSites(img.image, kVmGlobal, &sites) ==
           core::AudioSiteResult::kSoundLoadMissing);
  }
  {  // The channel array must hang off the VM global the text sites proved.
    SyntheticImage img;
    Build(&img);
    BuildAudio(&img, true, 0x8300u);
    core::AudioSites sites;
    assert(core::ResolveAudioSites(img.image, kVmGlobal, &sites) ==
           core::AudioSiteResult::kChannelLoadMissing);
  }
  {  // No AudioPlay registration.
    SyntheticImage img;
    Build(&img);
    core::AudioSites sites;
    assert(core::ResolveAudioSites(img.image, kVmGlobal, &sites) ==
           core::AudioSiteResult::kAudioPlayMissing);
  }
  // Voice → the first dialogue line printed on the selected lane after it.
  const core::PublishedText texts[] = {
      {10u, 7u, 1000u},  // earlier line on the dialogue lane
      {11u, 9u, 2010u},  // name plate lane, right after the voice
      {12u, 7u, 2017u},  // the dialogue the voice belongs to
      {13u, 7u, 4000u},  // the next line, outside the window
  };
  assert(core::BindVoiceToFollowingText(texts, 4u, 2000u, 7u, 1500u) == 12u);
  assert(core::BindVoiceToFollowingText(texts, 4u, 2000u, 9u, 1500u) == 11u);
  assert(core::BindVoiceToFollowingText(texts, 4u, 2000u, 0u, 1500u) == 0u);
  assert(core::BindVoiceToFollowingText(texts, 4u, 2100u, 5u, 1500u) == 0u);
  assert(core::BindVoiceToFollowingText(texts, 3u, 2018u, 7u, 1500u) == 0u);

  wchar_t name[32] = {};
  assert(core::AudioStorageName("voice/02000750", 15u, name, 32u) == 18u);
  assert(std::wcscmp(name, L"voice_02000750.ogg") == 0);
  assert(core::AudioStorageName("", 1u, name, 32u) == 9u);
  assert(std::wcscmp(name, L"voice.ogg") == 0);
}

void TestResolve() {
  {
    SyntheticImage img;
    Build(&img);
    core::Sites sites;
    const core::SiteResult result = core::ResolveSites(img.image, &sites);
    if (result != core::SiteResult::kResolved) {
      std::printf("resolve result %u\n", static_cast<unsigned>(result));
    }
    assert(result == core::SiteResult::kResolved);
    assert(sites.text_print_handler == kTextPrintHandler);
    assert(sites.print == kPrint);
    assert(sites.layout == kLayout);
    assert(sites.put_glyph == kPutGlyph);
    assert(sites.draw == kDraw);
    assert(sites.vm_global == kVmGlobal);
    assert(sites.text_array == kTextArray);
    assert(sites.prim_text_field == kPrimTextField);
    assert(sites.surface_offset == 4u);
    assert(sites.surface_ready == 0x508u);
    assert(sites.surface_origin_x == 0x518u && sites.surface_origin_y == 0x51au);
    assert(sites.pen_x == 0x5e8u && sites.pen_y == 0x5eau);
    assert(sites.glyph_advance == 0x6600u);
    assert(sites.prim_x == 0x14u && sites.prim_y == 0x16u);
    assert(sites.prim_rotation == 0x24u);
    assert(sites.prim_scale_x == 0x26u && sites.prim_scale_y == 0x28u);
    assert(sites.design_w == 0x60u && sites.design_h == 0x64u);
  }
  {  // Not x86.
    SyntheticImage img(IMAGE_FILE_MACHINE_AMD64, 64u);
    Build(&img);
    core::Sites sites;
    assert(core::ResolveSites(img.image, &sites) == core::SiteResult::kNotX86);
  }
  {  // No engine at all (another engine's image).
    SyntheticImage img;
    core::Sites sites;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kTextPrintMissing);
  }
  {  // Two registrations of the name: ambiguous, nothing installs.
    SyntheticImage img;
    BuildOptions options;
    options.second_text_print_registration = true;
    Build(&img, options);
    core::Sites sites;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kTextPrintMissing);
  }
  {  // PutGlyph without its exact prologue.
    SyntheticImage img;
    BuildOptions options;
    options.put_glyph_shape = false;
    Build(&img, options);
    core::Sites sites;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kPutGlyphMissing);
  }
  {  // The render case must use the TextPrint handler's text array.
    SyntheticImage img;
    BuildOptions options;
    options.render_array_matches = false;
    Build(&img, options);
    core::Sites sites;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kRenderMissing);
  }
  {  // A draw without the scale-identity test is not admitted.
    SyntheticImage img;
    BuildOptions options;
    options.scale_shape = false;
    Build(&img, options);
    core::Sites sites;
    assert(core::ResolveSites(img.image, &sites) ==
           core::SiteResult::kDrawShape);
  }
}

core::ParsedLine Parse(const char* bytes) {
  return core::ParseLine(reinterpret_cast<const uint8_t*>(bytes),
                         std::strlen(bytes));
}

void TestParse() {
  // "あい[かな|仮]う" in CP932: あ 82a0, い 82a2, か 82a9, な 82c8, 仮 89bc, う 82a4.
  const char line[] =
      "\x82\xa0\x82\xa2[\x82\xa9\x82\xc8|\x89\xbc]\x82\xa4";
  const core::ParsedLine parsed = Parse(line);
  assert(!parsed.malformed && !parsed.truncated);
  assert(parsed.count == 6u);
  assert(parsed.text_units == 4u);
  assert(parsed.ruby_units == 2u);
  assert(!parsed.units[0].ruby && !parsed.units[1].ruby);
  assert(parsed.units[2].ruby && parsed.units[3].ruby);
  assert(!parsed.units[4].ruby && parsed.units[4].offset == 10u);
  assert(!parsed.units[5].ruby);
  // ASCII is one unit; a plain `|` outside ruby is displayed text.
  const core::ParsedLine ascii = Parse("a|b");
  assert(!ascii.malformed && ascii.count == 3u && ascii.text_units == 3u);
  // Unbalanced groups and a dangling lead byte are malformed.
  assert(Parse("[\x82\xa9|\x89\xbc").malformed);
  assert(Parse("\x82\xa0]").malformed);
  assert(Parse("[\x82\xa9]").malformed);
  assert(Parse("\x82").malformed);
  std::string long_line(600u, 'a');
  assert(Parse(long_line.c_str()).truncated);
}

core::GlyphRecord Record(uint8_t ruby, int16_t x, int16_t y, int32_t advance) {
  core::GlyphRecord record;
  record.ruby = ruby;
  record.pen_x = x;
  record.pen_y = y;
  record.advance = advance;
  record.size = 28u;
  record.ruby_size = 12u;
  record.ruby_mode = 2u;
  record.ruby_gap = 2;
  return record;
}

void TestPair() {
  const char line[] =
      "\x82\xa0\x82\xa2[\x82\xa9\x82\xc8|\x89\xbc]\x82\xa4";
  const core::ParsedLine parsed = Parse(line);
  const core::GlyphRecord records[] = {
      Record(0u, 0, 0, 28),  Record(0u, 28, 0, 28), Record(1u, 50, 0, 12),
      Record(1u, 62, 0, 12), Record(0u, 56, 0, 28), Record(0u, 84, 0, 28)};
  core::Cell cells[8];
  assert(core::PairLineGlyphs(parsed, records, 6u, cells, 8u) == 4u);
  // Base glyphs sit below the reserved ruby band: y = pen + 12 + 2.
  assert(cells[0].x == 0 && cells[0].y == 14 && cells[0].w == 28 &&
         cells[0].h == 28);
  assert(cells[2].x == 56);
  assert(cells[3].x == 84);
  // A missing glyph, a ruby flag out of place or an empty advance refuse.
  assert(core::PairLineGlyphs(parsed, records, 5u, cells, 8u) == 0u);
  core::GlyphRecord swapped[6];
  std::memcpy(swapped, records, sizeof(records));
  swapped[2].ruby = 0u;
  assert(core::PairLineGlyphs(parsed, swapped, 6u, cells, 8u) == 0u);
  std::memcpy(swapped, records, sizeof(records));
  swapped[0].advance = 0;
  assert(core::PairLineGlyphs(parsed, swapped, 6u, cells, 8u) == 0u);
  // Without ruby space the base glyph is at the pen.
  core::GlyphRecord plain = Record(0u, 4, 6, 20);
  plain.ruby_mode = 0u;
  core::Cell cell;
  assert(core::BaseGlyphCell(plain, &cell) && cell.y == 6 && cell.x == 4);
}

void TestDrawAndProject() {
  core::DrawState state;
  state.ox = 100;
  state.oy = 400;
  state.prim_x = 20;
  state.prim_y = 10;
  state.alpha = 255u;
  state.ready = 1u;
  state.scale_x = core::kScaleIdentity;
  state.scale_y = core::kScaleIdentity;
  state.flags = 0x40u;  // dirty bit only
  int32_t x = 0, y = 0;
  assert(core::DrawOrigin(state, &x, &y) && x == 120 && y == 410);
  core::DrawState hidden = state;
  hidden.alpha = 0u;
  assert(!core::DrawOrigin(hidden, &x, &y));
  core::DrawState rotated = state;
  rotated.rotation = 90u;
  assert(!core::DrawOrigin(rotated, &x, &y));
  core::DrawState scaled = state;
  scaled.scale_x = 1200;
  assert(!core::DrawOrigin(scaled, &x, &y));
  core::DrawState clipped = state;
  clipped.flags = 0x41u;
  assert(!core::DrawOrigin(clipped, &x, &y));
  core::DrawState offset = state;
  offset.surface_origin[2] = 3;
  assert(!core::DrawOrigin(offset, &x, &y));

  const core::Cell cells[] = {{0, 14, 28, 28}, {28, 14, 28, 28}};
  const uint32_t codepoints[] = {0x3042u, 0x3044u};
  const uint16_t sources[] = {0u, 1u};
  core::LineGlyph glyphs[2];
  assert(core::BuildPageGlyphs(cells, 2u, codepoints, sources, 120, 410,
                               glyphs, 2u) == 2u);
  assert(glyphs[1].x == 148 && glyphs[1].y == 424);
  const wchar_t selected[] = L"\x3042\x3044";
  assert(core::MapSelectedSuffix(glyphs, 2u, selected, 2u) == 0u);
  const wchar_t other[] = L"\x3046";
  assert(core::MapSelectedSuffix(glyphs, 2u, other, 1u) == 2u);
  assert(core::MapSelectedSuffix(glyphs, 2u, selected, 2u) == 0u);
  core::PixelRect rect;
  assert(core::ProjectCell(glyphs[0], 1024, 576, 2048, 1152, &rect));
  assert(rect.x == 240 && rect.y == 848 && rect.w == 56 && rect.h == 56);
  assert(core::ClientMatchesDesign(2048, 1152, 1024, 576));
  assert(!core::ClientMatchesDesign(1600, 1200, 1024, 576));
  int32_t dx = 0, dy = 0;
  assert(core::ClientToDesign(260, 860, 2048, 1152, 1024, 576, &dx, &dy));
  size_t hit = 9u;
  assert(core::HitTestLine(glyphs, 2u, dx, dy, &hit) && hit == 0u);
  assert(!core::HitTestLine(glyphs, 2u, 10, 10, &hit));

  core::ClaimState claim;
  auto down = core::DecideMessage(WM_LBUTTONDOWN, true, &claim);
  assert(down.swallow && down.submit);
  auto up = core::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(up.swallow && !claim.owned);
  auto miss = core::DecideMessage(WM_LBUTTONDOWN, false, &claim);
  assert(!miss.swallow && !miss.submit);
  auto miss_up = core::DecideMessage(WM_LBUTTONUP, false, &claim);
  assert(!miss_up.swallow);
}

}  // namespace

int main() {
  TestResolve();
  TestAudio();
  TestParse();
  TestPair();
  TestDrawAndProject();
  std::printf("fvp_lookup_test ok\n");
  return 0;
}
