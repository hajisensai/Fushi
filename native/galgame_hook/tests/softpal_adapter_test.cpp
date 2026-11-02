// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstring>
#include <string>
#include <vector>

#include "../hook/adapters/softpal_profile.h"

namespace sp = fushi_voice_hook::softpal;

namespace {

// ── a synthetic PE32 image with an export directory ───────────────────────

std::vector<uint8_t> BuildImage(const std::vector<std::string>& names) {
  std::vector<uint8_t> image(0x4000, 0u);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(image.data());
  dos->e_magic = IMAGE_DOS_SIGNATURE;
  dos->e_lfanew = 0x80;
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(image.data() + 0x80);
  nt->Signature = IMAGE_NT_SIGNATURE;
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
  nt->OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
  nt->OptionalHeader.SizeOfImage = static_cast<DWORD>(image.size());
  nt->OptionalHeader.NumberOfRvaAndSizes = 16;
  const uint32_t dir_rva = 0x1000;
  const uint32_t functions = 0x1100;
  const uint32_t name_table = 0x1200;
  const uint32_t ordinals = 0x1300;
  uint32_t strings = 0x1400;
  auto* dir = reinterpret_cast<IMAGE_EXPORT_DIRECTORY*>(image.data() + dir_rva);
  dir->NumberOfFunctions = static_cast<DWORD>(names.size());
  dir->NumberOfNames = static_cast<DWORD>(names.size());
  dir->AddressOfFunctions = functions;
  dir->AddressOfNames = name_table;
  dir->AddressOfNameOrdinals = ordinals;
  for (size_t i = 0; i < names.size(); ++i) {
    const uint32_t code = 0x3000 + static_cast<uint32_t>(i) * 0x10;
    std::memcpy(image.data() + functions + i * 4, &code, 4);
    std::memcpy(image.data() + name_table + i * 4, &strings, 4);
    const uint16_t ordinal = static_cast<uint16_t>(i);
    std::memcpy(image.data() + ordinals + i * 2, &ordinal, 2);
    std::memcpy(image.data() + strings, names[i].c_str(), names[i].size() + 1);
    strings += static_cast<uint32_t>(names[i].size() + 1);
  }
  nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT]
      .VirtualAddress = dir_rva;
  nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].Size = 0x100;
  return image;
}

void TestIdentity() {
  std::vector<std::string> names;
  for (const char* name : sp::kRequiredExports) names.push_back(name);
  names.push_back("PalSoundPlay");
  std::vector<uint8_t> full = BuildImage(names);
  assert(fushi_voice_hook::IsSoftpalImage(full.data(), full.size()));
  // Every bound export is required: one missing is another engine.
  for (size_t skip = 0; skip < sp::kRequiredExportCount; ++skip) {
    std::vector<std::string> partial;
    for (size_t i = 0; i < names.size(); ++i) {
      if (i != skip) partial.push_back(names[i]);
    }
    std::vector<uint8_t> image = BuildImage(partial);
    assert(!fushi_voice_hook::IsSoftpalImage(image.data(), image.size()));
  }
  // A name that only starts like one does not count.
  std::vector<std::string> prefixed = names;
  prefixed[0] = "PalSpriteLockEx";
  std::vector<uint8_t> image = BuildImage(prefixed);
  assert(!fushi_voice_hook::IsSoftpalImage(image.data(), image.size()));
  // Not an image at all.
  std::vector<uint8_t> junk(0x400, 0xccu);
  assert(!fushi_voice_hook::IsSoftpalImage(junk.data(), junk.size()));
  // The process running this test is no SoftPal game.
  assert(!fushi_voice_hook::MatchesSoftpalProfile(nullptr));
}

// ── archives ───────────────────────────────────────────────────────────────

void PutEntry(std::vector<uint8_t>* index, size_t i, const char* name,
              uint32_t size, uint32_t offset) {
  uint8_t* entry = index->data() + i * sp::kPacEntryBytes;
  std::memset(entry, 0, sp::kPacEntryBytes);
  std::memcpy(entry, name, std::strlen(name));
  std::memcpy(entry + 0x20, &size, 4);
  std::memcpy(entry + 0x24, &offset, 4);
}

void TestArchives() {
  uint8_t header[12] = {'P', 'A', 'C', ' ', 0, 0, 0, 0, 2, 0, 0, 0};
  uint32_t count = 0;
  assert(sp::ParsePacHeader(header, sizeof(header), &count) && count == 2);
  uint8_t empty[12] = {'P', 'A', 'C', ' ', 0, 0, 0, 0, 0, 0, 0, 0};
  assert(!sp::ParsePacHeader(empty, sizeof(empty), &count));
  uint8_t other[12] = {'P', 'A', 'K', ' ', 0, 0, 0, 0, 2, 0, 0, 0};
  assert(!sp::ParsePacHeader(other, sizeof(other), &count));

  const uint32_t data = sp::kPacIndexOffset + 2 * sp::kPacEntryBytes;
  std::vector<uint8_t> index(2 * sp::kPacEntryBytes);
  PutEntry(&index, 0, "VO01_1001.OGG", 100, data);
  PutEntry(&index, 1, "VO01_1002.OGG", 50, data + 100);
  std::vector<sp::PacEntry> entries;
  assert(sp::ParsePacIndex(index.data(), index.size(), 2, data + 150,
                           &entries));
  assert(entries.size() == 2 && entries[1].offset == data + 100 &&
         entries[1].size == 50);
  // The script asks in lower case, sometimes with a directory.
  const std::string key = sp::NormalizeResourceName("voice\\vo01_1002.ogg", 64);
  assert(key == "VO01_1002.OGG");
  const sp::PacEntry* found = sp::FindPacEntry(entries, key);
  assert(found != nullptr && found->size == 50);
  assert(sp::FindPacEntry(entries, "VO01_1003.OGG") == nullptr);
  // A payload past the end of the archive rejects the index.
  assert(!sp::ParsePacIndex(index.data(), index.size(), 2, data + 149,
                            &entries));
  // A payload inside the index rejects it.
  PutEntry(&index, 1, "VO01_1002.OGG", 50, sp::kPacIndexOffset);
  assert(!sp::ParsePacIndex(index.data(), index.size(), 2, data + 150,
                            &entries));
  // A name that is not printable ASCII rejects it.
  PutEntry(&index, 1, "VO01\x01.OGG", 50, data + 100);
  assert(!sp::ParsePacIndex(index.data(), index.size(), 2, data + 150,
                            &entries));
  // Truncated index.
  assert(!sp::ParsePacIndex(index.data(), index.size() - 1, 2, data + 150,
                            &entries));
  const uint8_t ogg[] = {'O', 'g', 'g', 'S', 0};
  const uint8_t riff[] = {'R', 'I', 'F', 'F', 0};
  assert(sp::IsOggPayload(ogg, sizeof(ogg)));
  assert(!sp::IsOggPayload(riff, sizeof(riff)));
}

// ── pages ──────────────────────────────────────────────────────────────────

sp::GlyphDraw Draw(const char* cp932, int32_t x, int32_t y, int32_t size) {
  sp::GlyphDraw draw;
  draw.x = x;
  draw.y = y;
  draw.font_size = size;
  draw.length = static_cast<uint8_t>(std::strlen(cp932));
  std::memcpy(draw.bytes, cp932, draw.length);
  return draw;
}

void TestComposePage() {
  // 「この」 as the 2015 generation draws it: one call per glyph, 0x1a steps.
  const sp::GlyphDraw page[] = {
      Draw("\x81\x75", 0x00, 0x0b, 24),  // 「
      Draw("\x82\xb1", 0x1a, 0x0b, 24),  // こ
      Draw("\x82\xcc", 0x34, 0x0b, 24),  // の
      Draw("\x81\x76", 0x00, 0x31, 24),  // 」 on the next row
  };
  std::wstring text;
  std::vector<sp::PageGlyph> glyphs;
  assert(sp::ComposePage(page, 4, &text, &glyphs) ==
         sp::PageResult::kComposed);
  assert(text == L"\x300c\x3053\x306e\x300d");
  assert(glyphs.size() == 4);
  assert(glyphs[0].w == 0x1a && glyphs[1].x == 0x1a && glyphs[1].w == 0x1a);
  // The last glyph of a row: its own size.
  assert(glyphs[2].w == 24 && glyphs[3].y == 0x31 && glyphs[3].w == 24);
  assert(glyphs[3].source_index == 3 && glyphs[3].source_length == 1);

  // Ruby the source carries over a word stays out of the text.
  const sp::GlyphDraw ruby[] = {
      Draw("\x8a\xbf", 0, 20, 24),   // 漢
      Draw("\x82\xa9", 2, 0, 12),    // か (ruby)
      Draw("\x8e\x9a", 26, 20, 24),  // 字
  };
  assert(sp::ComposePage(ruby, 3, &text, &glyphs) ==
         sp::PageResult::kComposed);
  assert(text == L"\x6f22\x5b57" && glyphs.size() == 2);
  assert(glyphs[0].w == 26 && glyphs[1].source_index == 1);

  // A string of several characters is laid out evenly over its cell.
  const sp::GlyphDraw run[] = {Draw("AB", 10, 0, 20)};
  assert(sp::ComposePage(run, 1, &text, &glyphs) ==
         sp::PageResult::kComposed);
  assert(text == L"AB" && glyphs.size() == 2 && glyphs[0].w == 10 &&
         glyphs[1].x == 20);

  // Not CP932 text: nothing is published.
  const sp::GlyphDraw broken[] = {Draw("\x82", 0, 0, 24)};
  assert(sp::ComposePage(broken, 1, &text, &glyphs) ==
         sp::PageResult::kRejected);
  const sp::GlyphDraw control[] = {Draw("\x07", 0, 0, 24)};
  assert(sp::ComposePage(control, 1, &text, &glyphs) ==
         sp::PageResult::kRejected);
  assert(sp::ComposePage(nullptr, 0, &text, &glyphs) == sp::PageResult::kEmpty);
}

void TestStepRules() {
  // The plate, then the body in the same step, on another sprite.
  assert(sp::IsSpeakerLabel(0x1000, 0x2000, 0));
  // A frame went by: two pages.
  assert(!sp::IsSpeakerLabel(0x1000, 0x2000, 1));
  // The same sprite redrawn is never a plate.
  assert(!sp::IsSpeakerLabel(0x1000, 0x1000, 0));
  assert(!sp::IsSpeakerLabel(0, 0x2000, 0));

  assert(sp::VoicePairsWithPage(1, true, 0));
  assert(!sp::VoicePairsWithPage(1, true, 3));    // a later step
  assert(!sp::VoicePairsWithPage(1, false, 0));   // no page: a system voice
  assert(!sp::VoicePairsWithPage(3, true, 0));    // music
  assert(!sp::VoicePairsWithPage(5, true, 0));    // effect
}

// ── placement ──────────────────────────────────────────────────────────────

void TestPlacement() {
  assert(!sp::DesignPlausible(0, 0));
  assert(sp::DesignPlausible(1280, 720) && sp::DesignPlausible(800, 600));
  sp::Viewport v;
  // Stretched over a 1173x660 client (175% scale, DPI-unaware game).
  assert(sp::ComputeViewport(1280, 720, 1173, 660, false, &v));
  sp::PixelRect r;
  assert(sp::DesignRectToClient(v, 290 + 26, 577 + 11, 26, 24, &r));
  assert(r.x == 290 && r.y == 539 && r.w == 23 && r.h == 22);
  double dx = 0, dy = 0;
  assert(sp::ClientPointToDesign(v, r.x + 2, r.y + 2, &dx, &dy));
  assert(dx >= 316 && dx < 342 && dy >= 588 && dy < 612);
  // Keep-aspect on a wider client: centred with side bars.
  assert(sp::ComputeViewport(1280, 720, 1600, 720, true, &v));
  assert(v.x == 160.0 && v.y == 0.0 && v.scale_x == 1.0 && v.scale_y == 1.0);
  assert(sp::DesignRectToClient(v, 0, 0, 10, 10, &r) && r.x == 160);
  assert(!sp::ComputeViewport(1280, 720, 0, 720, false, &v));

  std::vector<sp::PageGlyph> glyphs(4);
  for (int i = 0; i < 3; ++i) {
    glyphs[i] = {i * 26, 11, 26, 24, static_cast<uint16_t>(i), 1};
  }
  glyphs[3] = {0, 49, 26, 24, 3, 1};
  size_t hit = 99;
  assert(sp::HitTestPage(glyphs.data(), 4, 290, 577, 290 + 30, 577 + 12, &hit));
  assert(hit == 1);
  assert(sp::HitTestPage(glyphs.data(), 4, 290, 577, 290 + 1, 577 + 50, &hit));
  assert(hit == 3);
  // Between the rows, or left of the page: nothing.
  assert(!sp::HitTestPage(glyphs.data(), 4, 290, 577, 290 + 30, 577 + 40,
                          &hit));
  assert(!sp::HitTestPage(glyphs.data(), 4, 290, 577, 280, 577 + 12, &hit));

  int32_t x = 0, y = 0, w = 0, h = 0;
  // A term on one row: the union of its glyphs.
  assert(sp::TermRect(glyphs.data(), 4, 1, 2, &x, &y, &w, &h));
  assert(x == 26 && y == 11 && w == 52 && h == 24);
  // A term wrapping to the next row: its first row.
  assert(sp::TermRect(glyphs.data(), 4, 2, 2, &x, &y, &w, &h));
  assert(x == 52 && w == 26 && y == 11);
  assert(!sp::TermRect(glyphs.data(), 4, 9, 1, &x, &y, &w, &h));
  assert(!sp::TermRect(glyphs.data(), 4, 0, 0, &x, &y, &w, &h));
}

// ── input claim ────────────────────────────────────────────────────────────

void TestClaim() {
  using sp::ButtonMessage;
  using sp::SampleAction;
  // The engine's sample sees a press on a glyph first.
  {
    sp::PressState s;
    assert(sp::DecideSample(&s, true) == SampleAction::kEvaluate);
    sp::ResolvePress(&s, true);
    assert(sp::DecideSample(&s, true) == SampleAction::kMask);
    sp::MessageDecision d = sp::DecideMessage(&s, ButtonMessage::kDown);
    assert(!d.evaluate && d.swallow);
    // Released before the WM_LBUTTONUP is dispatched: still swallowed.
    assert(sp::DecideSample(&s, false) == SampleAction::kPass);
    d = sp::DecideMessage(&s, ButtonMessage::kUp);
    assert(d.swallow);
    // The next press is a new decision.
    assert(sp::DecideSample(&s, true) == SampleAction::kEvaluate);
  }
  // The sample sees a press off the glyphs: everything reaches the engine.
  {
    sp::PressState s;
    assert(sp::DecideSample(&s, true) == SampleAction::kEvaluate);
    sp::ResolvePress(&s, false);
    assert(sp::DecideSample(&s, true) == SampleAction::kPass);
    sp::MessageDecision d = sp::DecideMessage(&s, ButtonMessage::kDown);
    assert(!d.evaluate && !d.swallow);
    d = sp::DecideMessage(&s, ButtonMessage::kUp);
    assert(!d.swallow);
  }
  // A sub-frame touch tap: the sample never sees it down, the messages
  // decide.
  {
    sp::PressState s;
    sp::MessageDecision d = sp::DecideMessage(&s, ButtonMessage::kDown);
    assert(d.evaluate && !d.swallow);
    assert(sp::ResolveMessagePress(&s, true));
    d = sp::DecideMessage(&s, ButtonMessage::kUp);
    assert(d.swallow);
    assert(sp::DecideSample(&s, false) == SampleAction::kPass);
    // A second tap before any sample: decided afresh.
    d = sp::DecideMessage(&s, ButtonMessage::kDown);
    assert(d.evaluate);
    assert(!sp::ResolveMessagePress(&s, false));
    d = sp::DecideMessage(&s, ButtonMessage::kUp);
    assert(!d.swallow);
  }
  // The messages claim a long press; the sample then sees it down: masked.
  {
    sp::PressState s;
    sp::MessageDecision d = sp::DecideMessage(&s, ButtonMessage::kDown);
    assert(d.evaluate);
    sp::ResolveMessagePress(&s, true);
    assert(sp::DecideSample(&s, true) == SampleAction::kMask);
    assert(sp::DecideSample(&s, true) == SampleAction::kMask);
    assert(sp::DecideMessage(&s, ButtonMessage::kUp).swallow);
    assert(sp::DecideSample(&s, false) == SampleAction::kPass);
  }
  // Other messages are never touched.
  {
    sp::PressState s;
    s.up_pending = true;
    const sp::MessageDecision d = sp::DecideMessage(&s, ButtonMessage::kOther);
    assert(!d.evaluate && !d.swallow && s.up_pending);
  }
}

}  // namespace

// ── touch claim (touch-registered windows) ───────────────────────────────

void TestTouchClaim() {
  using sp::ButtonMessage;
  using sp::SampleAction;
  using sp::TouchEvent;
  // A tap on a glyph: its WM_TOUCH messages and promoted press are hidden,
  // one lookup.
  {
    sp::TouchState t;
    sp::PressState s;
    sp::TouchDecision d = sp::DecideTouch(&t, 7u, TouchEvent::kDown);
    assert(d.evaluate && !d.swallow);
    assert(sp::ResolveTouch(&t, &s, true));
    // The engine samples the promoted press down: masked.
    assert(sp::DecideSample(&s, true) == SampleAction::kMask);
    d = sp::DecideTouch(&t, 7u, TouchEvent::kMove);
    assert(!d.evaluate && d.swallow);
    // A second finger while it is down stays hidden too.
    d = sp::DecideTouch(&t, 8u, TouchEvent::kDown);
    assert(!d.evaluate && d.swallow);
    d = sp::DecideTouch(&t, 7u, TouchEvent::kUp);
    assert(d.swallow && !t.active);
    bool swallow = false;
    assert(sp::TakeTouchPromotion(&t, &s, &swallow));
    assert(swallow);
    assert(sp::DecideMessage(&s, ButtonMessage::kUp).swallow);
    // Consumed: the next promoted press is not followed again.
    assert(!sp::TakeTouchPromotion(&t, &s, &swallow));
  }
  // The sample sees the promoted press released before the message arrives:
  // the message still follows the touch decision without a second lookup.
  {
    sp::TouchState t;
    sp::PressState s;
    sp::DecideTouch(&t, 3u, TouchEvent::kDown);
    sp::ResolveTouch(&t, &s, true);
    assert(sp::DecideSample(&s, false) == SampleAction::kPass);
    bool swallow = false;
    assert(sp::TakeTouchPromotion(&t, &s, &swallow) && swallow);
    assert(sp::DecideMessage(&s, ButtonMessage::kUp).swallow);
  }
  // A tap off the glyphs reaches the engine both ways.
  {
    sp::TouchState t;
    sp::PressState s;
    sp::DecideTouch(&t, 5u, TouchEvent::kDown);
    assert(!sp::ResolveTouch(&t, &s, false));
    assert(!sp::DecideTouch(&t, 5u, TouchEvent::kMove).swallow);
    assert(!sp::DecideTouch(&t, 5u, TouchEvent::kUp).swallow);
    assert(sp::DecideSample(&s, true) == SampleAction::kPass);
    bool swallow = true;
    assert(sp::TakeTouchPromotion(&t, &s, &swallow) && !swallow);
    assert(!sp::DecideMessage(&s, ButtonMessage::kUp).swallow);
  }
  // Inputs of no tracked contact pass.
  {
    sp::TouchState t;
    assert(!sp::DecideTouch(&t, 1u, TouchEvent::kMove).swallow);
    assert(!sp::DecideTouch(&t, 1u, TouchEvent::kUp).swallow);
  }
  assert(sp::IsPromotedPointerMessage(0xFF515780u));
  assert(sp::IsPromotedPointerMessage(0xFF515700u));
  assert(!sp::IsPromotedPointerMessage(0u));
}

int main() {
  TestIdentity();
  TestArchives();
  TestComposePage();
  TestStepRules();
  TestPlacement();
  TestClaim();
  TestTouchClaim();
  return 0;
}
