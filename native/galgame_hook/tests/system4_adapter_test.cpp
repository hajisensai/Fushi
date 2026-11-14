// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstring>
#include <string>
#include <vector>

#include "../hook/adapters/system4_profile.h"

namespace s4 = fushi_voice_hook::system4;

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

std::vector<std::string> Sact2Names() {
  std::vector<std::string> names;
  for (const char* name : s4::kRequiredExports) names.emplace_back(name);
  names.emplace_back("SP_SetZ");
  return names;
}

void TestIdentity() {
  std::vector<uint8_t> image = BuildImage(Sact2Names());
  assert(fushi_voice_hook::IsSystem4Sact2Image(image.data(), image.size()));
  // Each required export is load-bearing.
  for (size_t drop = 0; drop < s4::kRequiredExportCount; ++drop) {
    std::vector<std::string> names = Sact2Names();
    names.erase(names.begin() + static_cast<std::ptrdiff_t>(drop));
    std::vector<uint8_t> partial = BuildImage(names);
    assert(!fushi_voice_hook::IsSystem4Sact2Image(partial.data(),
                                                  partial.size()));
  }
  // Another engine's HLL-like surface is not SACT2.
  std::vector<uint8_t> other =
      BuildImage({"PalSpriteLock", "PalFontDrawText", "SP_TextDraw"});
  assert(!fushi_voice_hook::IsSystem4Sact2Image(other.data(), other.size()));
  // x64 images are not this generation.
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS32*>(image.data() + 0x80);
  nt->FileHeader.Machine = IMAGE_FILE_MACHINE_AMD64;
  assert(!fushi_voice_hook::IsSystem4Sact2Image(image.data(), image.size()));
}

// ── the VM's MSG handler ───────────────────────────────────────────────────

constexpr uint32_t kBase = 0x10000000u;
constexpr uint32_t kHandler = 0x2000u;
constexpr uint32_t kGetter = 0x2800u;
constexpr uint32_t kString = 0x3800u;

void Put(std::vector<uint8_t>* image, uint32_t at,
         const std::vector<uint8_t>& bytes) {
  std::memcpy(image->data() + at, bytes.data(), bytes.size());
}

void PutU32(std::vector<uint8_t>* image, uint32_t at, uint32_t value) {
  std::memcpy(image->data() + at, &value, 4);
}

// The handler shape with chosen VM offsets (not the sample's), its getter
// and the diagnostic it pushes.
std::vector<uint8_t> BuildVm(uint32_t code, uint32_t end, uint32_t msgf,
                             uint8_t holder, uint8_t vec) {
  std::vector<uint8_t> image(0x4000, 0xccu);
  // Prologue (the template), with the frame and argument slots consistent.
  Put(&image, kHandler,
      {0x64, 0xa1, 0x00, 0x00, 0x00, 0x00, 0x6a, 0xff, 0x68, 0x11, 0x22, 0x33,
       0x44, 0x50, 0x64, 0x89, 0x25, 0x00, 0x00, 0x00, 0x00, 0x83, 0xec, 0x18,
       0x55, 0x8b, 0x6c, 0x24, 0x2c, 0x8b, 0x85});
  PutU32(&image, kHandler + 0x1f, code);
  Put(&image, kHandler + 0x23, {0x85, 0xc0, 0x74, 0x37, 0x8d, 0x48, 0x04, 0x3b,
                                0x8d});
  PutU32(&image, kHandler + 0x2c, end);
  Put(&image, kHandler + 0x30, {0x77, 0x2c, 0x53, 0x8b, 0x18, 0x8b, 0x85});
  PutU32(&image, kHandler + 0x37, msgf);
  // push edi; lea edi,[ebp+holder] ... mov esi,edi; call getter
  Put(&image, kHandler + 0x60, {0x57, 0x8d, 0x7d, holder});
  const uint32_t call = kHandler + 0x80;
  Put(&image, call, {0x8b, 0xf7, 0xe8});
  PutU32(&image, call + 3, kGetter - (call + 7));
  // push imm32 <diagnostic>
  image[kHandler + 0xa0] = 0x68;
  PutU32(&image, kHandler + 0xa1, kBase + kString);
  Put(&image, kGetter,
      {0x85, 0xc0, 0x7c, 0x2a, 0x8b, 0x56, vec, 0x85, 0xd2, 0x75, 0x04, 0x33,
       0xc9, 0xeb, 0x08, 0x8b, 0x4e, static_cast<uint8_t>(vec + 4), 0x2b,
       0xca, 0xc1, 0xf9, 0x04});
  image[kString - 1] = 0;
  Put(&image, kString,
      std::vector<uint8_t>(std::begin(s4::kMsgDiagPrefix),
                           std::end(s4::kMsgDiagPrefix)));
  const uint32_t d = kString + sizeof(s4::kMsgDiagPrefix);
  Put(&image, d, {'%', 'd'});
  Put(&image, d + 2,
      std::vector<uint8_t>(std::begin(s4::kMsgDiagSuffix),
                           std::end(s4::kMsgDiagSuffix)));
  image[d + 2 + sizeof(s4::kMsgDiagSuffix)] = 0;
  return image;
}

bool Decode(const std::vector<uint8_t>& image, s4::MsgLayout* layout) {
  s4::ImageView view;
  view.bytes = image.data();
  view.size = image.size();
  view.image_base = kBase;
  return s4::DecodeMsgHandler(view, layout);
}

void TestMsgHandler() {
  s4::MsgLayout layout;
  const std::vector<uint8_t> vm = BuildVm(0x31c, 0x324, 0x210, 0x50, 0x18);
  assert(Decode(vm, &layout));
  assert(layout.handler_rva == kHandler);
  assert(layout.code_ptr == 0x31c);
  assert(layout.code_end == 0x324);
  assert(layout.msg_func == 0x210);
  assert(layout.table_begin == 0x50 + 0x18);
  assert(layout.table_end == 0x50 + 0x18 + 4);

  // No diagnostic string: not the VM.
  {
    std::vector<uint8_t> image = vm;
    image[kString + 2] ^= 0xff;
    assert(!Decode(image, &layout));
  }
  // The string must stand alone (not the tail of a longer one).
  {
    std::vector<uint8_t> image = vm;
    image[kString - 1] = 'x';
    assert(!Decode(image, &layout));
  }
  // Two pushes of it: ambiguous, nothing installed.
  {
    std::vector<uint8_t> image = vm;
    image[kHandler + 0xb0] = 0x68;
    PutU32(&image, kHandler + 0xb1, kBase + kString);
    assert(!Decode(image, &layout));
  }
  // Any template byte that differs installs nothing.
  for (uint32_t at : {0x00u, 0x0du, 0x19u, 0x1du, 0x23u, 0x2au, 0x32u, 0x35u}) {
    std::vector<uint8_t> image = vm;
    image[kHandler + at] ^= 0x01;
    assert(!Decode(image, &layout));
  }
  // The VM argument slot must be the first stack argument of that frame.
  {
    std::vector<uint8_t> image = vm;
    image[kHandler + 0x17] = 0x1c;  // sub esp,1Ch: the argument moves to +30h
    assert(!Decode(image, &layout));
    image[kHandler + 0x1c] = 0x30;
    assert(Decode(image, &layout));
  }
  // A getter of another shape (end not right after begin): no table.
  {
    std::vector<uint8_t> image = vm;
    image[kGetter + 0x11] = 0x30;
    assert(!Decode(image, &layout));
  }
  // The lea needs its push edi.
  {
    std::vector<uint8_t> image = vm;
    image[kHandler + 0x60] = 0x56;
    assert(!Decode(image, &layout));
  }
  // An implausible VM offset is refused.
  assert(!Decode(BuildVm(0x123456, 0x324, 0x210, 0x50, 0x18), &layout));
}

// ── page groups ────────────────────────────────────────────────────────────

// CP932: 「あい」 = 82 a0 82 a2, 「う」 = 82 a4, 「。」 = 81 42.
const char kLine1[] = "\x82\xa0\x82\xa2";
const char kLine2[] = "\x82\xa4\x81\x42";

s4::GroupGlyph Cell(int32_t x, int32_t y) {
  return s4::GlyphFromDraw(x, y, x + 24, 24);
}

void TestGroups() {
  s4::Group g;
  s4::ResetGroup(&g);
  // Two MSG lines of one page, back to back.
  assert(s4::OnMessage(&g, kLine1, 4) == s4::MessageResult::kAppended);
  assert(s4::OnMessage(&g, kLine2, 4) == s4::MessageResult::kAppended);
  assert(g.char_count == 4u && g.line_count == 2u);
  // A name plate drawn on another sprite before the body is not ours.
  assert(s4::OnDraw(&g, 1248, "\x90\x44", 2, Cell(0, 0)) ==
         s4::DrawResult::kIgnored);
  assert(g.sprite == 0);
  assert(s4::OnDraw(&g, 1241, "\x82\xa0", 2, Cell(0, 0)) ==
         s4::DrawResult::kMatched);
  assert(g.sprite == 1241);
  // Once the body sprite is known, other sprites stay ignored.
  assert(s4::OnDraw(&g, 1248, "\x82\xa2", 2, Cell(24, 0)) ==
         s4::DrawResult::kIgnored);
  assert(s4::OnDraw(&g, 1241, "\x82\xa2", 2, Cell(24, 0)) ==
         s4::DrawResult::kMatched);
  assert(s4::OnDraw(&g, 1241, "\x82\xa4", 2, Cell(0, 26)) ==
         s4::DrawResult::kMatched);
  assert(!s4::GroupComplete(g));
  assert(s4::OnDraw(&g, 1241, "\x81\x42", 2, Cell(24, 26)) ==
         s4::DrawResult::kComplete);
  assert(s4::GroupComplete(g));
  assert(g.glyphs[2].x == 0 && g.glyphs[2].y == 26 && g.glyphs[2].w == 24);
  // Draws after completion are not the group's.
  assert(s4::OnDraw(&g, 1241, "\x82\xa0", 2, Cell(48, 26)) ==
         s4::DrawResult::kIgnored);

  // The next MSG after the draws began commits the current group first.
  s4::ResetGroup(&g);
  assert(s4::OnMessage(&g, kLine1, 4) == s4::MessageResult::kAppended);
  assert(s4::OnDraw(&g, 7, "\x82\xa0", 2, Cell(0, 0)) ==
         s4::DrawResult::kMatched);
  assert(s4::OnMessage(&g, kLine2, 4) == s4::MessageResult::kCommitFirst);
  assert(g.char_count == 2u);  // untouched until the caller commits

  // A draw on the group's sprite that is not its next character breaks the
  // geometry, the text stays.
  s4::ResetGroup(&g);
  assert(s4::OnMessage(&g, kLine1, 4) == s4::MessageResult::kAppended);
  assert(s4::OnDraw(&g, 7, "\x82\xa0", 2, Cell(0, 0)) ==
         s4::DrawResult::kMatched);
  assert(s4::OnDraw(&g, 7, "\x82\xa4", 2, Cell(24, 0)) ==
         s4::DrawResult::kBroken);
  assert(!s4::GroupComplete(g) && g.char_count == 2u);
  assert(s4::OnDraw(&g, 7, "\x82\xa2", 2, Cell(24, 0)) ==
         s4::DrawResult::kIgnored);
  assert(s4::OnMessage(&g, kLine2, 4) == s4::MessageResult::kCommitFirst);

  // Clearing the group's sprite commits it; another sprite's clear does not,
  // nor does any clear before the first match.
  s4::ResetGroup(&g);
  assert(s4::OnMessage(&g, kLine1, 4) == s4::MessageResult::kAppended);
  assert(!s4::OnSpriteCleared(g, 7));
  assert(s4::OnDraw(&g, 7, "\x82\xa0", 2, Cell(0, 0)) ==
         s4::DrawResult::kMatched);
  assert(!s4::OnSpriteCleared(g, 8));
  assert(s4::OnSpriteCleared(g, 7));

  // Not clean CP932 (a control byte, a cut lead byte): rejected.
  s4::ResetGroup(&g);
  assert(s4::OnMessage(&g, "\x01\x82\xa0", 3) == s4::MessageResult::kRejected);
  assert(s4::OnMessage(&g, "\x82\xa0\x82", 3) == s4::MessageResult::kRejected);
  assert(s4::OnMessage(&g, "", 0) == s4::MessageResult::kRejected);
  assert(g.char_count == 0u);
  // Half-width text is one byte per character.
  assert(s4::OnMessage(&g, "AB", 2) == s4::MessageResult::kAppended);
  assert(g.char_count == 2u && g.char_len[0] == 1u);

  // A page fuller than the group commits first; a single line too long for
  // a page is rejected.
  s4::ResetGroup(&g);
  std::string full;
  for (uint32_t i = 0; i <= s4::kMaxGroupChars; ++i) full += "\x82\xa0";
  assert(s4::OnMessage(&g, full.data(), static_cast<uint32_t>(full.size())) ==
         s4::MessageResult::kRejected);
  // Half a page: kMaxGroupChars / 2 two-byte characters.
  const std::string half = full.substr(0, s4::kMaxGroupChars);
  assert(s4::OnMessage(&g, half.data(), static_cast<uint32_t>(half.size())) ==
         s4::MessageResult::kAppended);
  assert(s4::OnMessage(&g, half.data(), static_cast<uint32_t>(half.size())) ==
         s4::MessageResult::kAppended);
  assert(s4::OnMessage(&g, kLine1, 4) == s4::MessageResult::kCommitFirst);
}

void TestGlyphFromDraw() {
  // The measured advance (24 for a 24px full-width glyph).
  s4::GroupGlyph g = s4::GlyphFromDraw(328, 260, 352, 24);
  assert(g.x == 328 && g.y == 260 && g.w == 24 && g.h == 24);
  // A half-width glyph advances less.
  g = s4::GlyphFromDraw(0, 0, 12, 24);
  assert(g.w == 12);
  // No advance (or a wrap, or an implausible jump): the font size.
  assert(s4::GlyphFromDraw(100, 0, 100, 24).w == 24);
  assert(s4::GlyphFromDraw(100, 0, 0, 24).w == 24);
  assert(s4::GlyphFromDraw(0, 0, 100, 24).w == 24);
  assert(s4::FontSizePlausible(18) && s4::FontSizePlausible(24));
  assert(!s4::FontSizePlausible(0) && !s4::FontSizePlausible(0x6a4));
}

// ── placement ──────────────────────────────────────────────────────────────

void TestPlacement() {
  s4::Viewport v;
  // Windowed: client = design.
  assert(s4::ComputeViewport(800, 600, 800, 600, &v));
  assert(v.scale_x == 1.0 && v.scale_y == 1.0);
  // DPI-scaled physical client of the same window.
  assert(s4::ComputeViewport(800, 600, 1000, 750, &v));
  assert(v.scale_x == 1.25 && v.scale_y == 1.25);
  // Another aspect ratio (letterboxed full screen): refused, never guessed.
  assert(!s4::ComputeViewport(800, 600, 2560, 1440, &v));
  // Within 1%: a rounding of the window size.
  assert(s4::ComputeViewport(800, 600, 1001, 750, &v));
  assert(!s4::ComputeViewport(100, 100, 800, 600, &v));
  assert(!s4::ComputeViewport(800, 600, 0, 600, &v));

  // The body sprite at (226,503), its first glyph at sprite (0,0), 24px.
  s4::PixelRect r;
  assert(s4::ComputeViewport(800, 600, 1000, 750, &v));
  assert(s4::DesignRectToClient(v, 226 + 0, 503 + 0, 24, 24, &r));
  assert(r.x == 283 && r.y == 629 && r.w == 30 && r.h == 30);
  double dx = 0, dy = 0;
  assert(s4::ClientPointToDesign(v, 290, 640, &dx, &dy));
  assert(dx > 232.0 && dx < 233.0 && dy > 512.0 && dy < 513.0);

  s4::PageGlyph glyphs[3];
  glyphs[0] = {0, 0, 24, 24, 0, 1};
  glyphs[1] = {24, 0, 24, 24, 1, 1};
  glyphs[2] = {0, 26, 24, 24, 2, 1};
  size_t hit = 99;
  assert(s4::HitTestPage(glyphs, 3, 226, 503, 232.4, 512.4, &hit) && hit == 0);
  assert(s4::HitTestPage(glyphs, 3, 226, 503, 251.0, 503.0, &hit) && hit == 1);
  assert(s4::HitTestPage(glyphs, 3, 226, 503, 226.0, 530.0, &hit) && hit == 2);
  // The line gap between rows is not a glyph.
  assert(!s4::HitTestPage(glyphs, 3, 226, 503, 226.0, 527.5, &hit));
  assert(!s4::HitTestPage(glyphs, 3, 226, 503, 274.0, 503.0, &hit));

  int32_t x = 0, y = 0, w = 0, h = 0;
  assert(s4::TermRect(glyphs, 3, 0, 2, &x, &y, &w, &h));
  assert(x == 0 && y == 0 && w == 48 && h == 24);
  // A term running onto the next row keeps the row of its first character.
  assert(s4::TermRect(glyphs, 3, 1, 2, &x, &y, &w, &h));
  assert(x == 24 && y == 0 && w == 24 && h == 24);
  assert(!s4::TermRect(glyphs, 3, 3, 1, &x, &y, &w, &h));
  assert(!s4::TermRect(glyphs, 3, 0, 0, &x, &y, &w, &h));
}

// ── event ring and the press claim ─────────────────────────────────────────

void TestRing() {
  s4::RingCursor c = s4::RingStart(0, 3, 16);
  assert(c.next == 1 && !c.lost);
  c = s4::RingStart(2, 40, 16);
  assert(c.next == 25 && c.lost);
  assert(s4::RingSlotReady(7, 7) && !s4::RingSlotReady(0, 7));
}

void TestClaim() {
  s4::PressState s;
  // A claimed press: its up is swallowed too.
  s4::MessageDecision d = s4::DecideMessage(&s, s4::ButtonMessage::kDown);
  assert(d.evaluate && !d.swallow);
  assert(s4::ResolvePress(&s, true));
  d = s4::DecideMessage(&s, s4::ButtonMessage::kUp);
  assert(!d.evaluate && d.swallow);
  // The next up (none pending) passes.
  d = s4::DecideMessage(&s, s4::ButtonMessage::kUp);
  assert(!d.swallow);
  // A passed press: down and up reach the engine.
  d = s4::DecideMessage(&s, s4::ButtonMessage::kDown);
  assert(d.evaluate);
  assert(!s4::ResolvePress(&s, false));
  d = s4::DecideMessage(&s, s4::ButtonMessage::kUp);
  assert(!d.swallow);
  // A claimed press whose up never came does not swallow the next press's up.
  d = s4::DecideMessage(&s, s4::ButtonMessage::kDown);
  s4::ResolvePress(&s, true);
  d = s4::DecideMessage(&s, s4::ButtonMessage::kDown);
  assert(d.evaluate);
  s4::ResolvePress(&s, false);
  d = s4::DecideMessage(&s, s4::ButtonMessage::kUp);
  assert(!d.swallow);
  // Other messages are never touched.
  d = s4::DecideMessage(&s, s4::ButtonMessage::kOther);
  assert(!d.evaluate && !d.swallow);
}

}  // namespace

int main() {
  TestIdentity();
  TestMsgHandler();
  TestGroups();
  TestGlyphFromDraw();
  TestPlacement();
  TestRing();
  TestClaim();
  return 0;
}
