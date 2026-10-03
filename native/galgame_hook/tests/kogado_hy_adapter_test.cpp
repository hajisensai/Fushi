// CI builds with --config Release, where MSVC defines NDEBUG and compiles
// bare assert() out entirely. Undefine it before any include or this test is
// green no matter what it checks. Guard: tests/assert_liveness_guard_test.py
#undef NDEBUG

// Kogado "Hy" engine: identity, structural site resolution and page rules,
// on synthetic images only (no game bytes).
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../hook/adapters/kogado_hy_profile.h"

namespace kh = fushi_voice_hook::kogado_hy;

namespace {

constexpr uint32_t kImageSize = 0x4000u;
constexpr uint32_t kVaBase = 0x400000u;
constexpr uint32_t kCodeBegin = 0x1000u;
constexpr uint32_t kCodeEnd = 0x3000u;
constexpr uint32_t kExportDir = 0x3000u;

constexpr uint32_t kSetText = 0x1000u;
constexpr uint32_t kBoxFill = 0x1010u;
constexpr uint32_t kDraw = 0x1020u;
constexpr uint32_t kRender = 0x1100u;
constexpr uint32_t kSongRender = 0x1200u;
constexpr uint32_t kSecondRender = 0x1300u;
constexpr uint32_t kMessageCaller = 0x1400u;
constexpr uint32_t kSongCaller = 0x1600u;
constexpr uint32_t kSecondCaller = 0x1800u;
constexpr uint32_t kShowMessage = 0x1a00u;
constexpr uint32_t kWait = 0x1b00u;
constexpr uint32_t kWaitCaller = 0x1b80u;
constexpr uint32_t kRestore = 0x1c00u;
constexpr uint32_t kSecondWait = 0x1e00u;
constexpr uint32_t kSecondWaitCaller = 0x1e80u;
constexpr uint32_t kModeGlobal = 0x403300u;
constexpr uint32_t kCursorFullScreen = 0x1040u;
constexpr uint32_t kCursorAdventure = 0x1050u;

struct Image {
  std::vector<uint8_t> bytes = std::vector<uint8_t>(kImageSize, 0xccu);
  uint32_t at = 0u;

  void Seek(uint32_t rva) { at = rva; }
  void Put(std::initializer_list<uint8_t> b) {
    for (uint8_t v : b) bytes[at++] = v;
  }
  void Put32(uint32_t v) {
    std::memcpy(bytes.data() + at, &v, 4u);
    at += 4u;
  }
  void Call(uint32_t target) {
    Put({0xe8u});
    Put32(target - (at + 4u));
  }
  void Nops(uint32_t n) {
    for (uint32_t i = 0u; i < n; ++i) Put({0x90u});
  }
};

// RENDER shape: prologue, BoxFill, `mov eax,[eax+0x84]; call SetText`, Draw.
void EmitRenderer(Image* image, uint32_t rva) {
  image->Seek(rva);
  image->Put({0x55u, 0x8bu, 0xecu, 0x83u, 0xc4u, 0xd0u});  // frame prologue
  image->Nops(8u);
  image->Call(kBoxFill);
  image->Nops(8u);
  image->Put({0x8bu, 0x45u, 0xd4u});                  // mov eax,[ebp-0x2c]
  image->Put({0x8bu, 0x80u, 0x84u, 0x00u, 0x00u, 0x00u});  // mov eax,[eax+0x84]
  image->Call(kSetText);
  image->Nops(12u);
  image->Call(kDraw);
  image->Put({0xc3u});
}

// A message window filling row [obj+counter]: row-address arithmetic with
// stride 53 from the counter, then RENDER handed the row array and the
// counter.
void EmitMessageCaller(Image* image, uint32_t rva, uint32_t render,
                       uint32_t counter, uint32_t base) {
  image->Seek(rva);
  image->Put({0x55u, 0x8bu, 0xecu, 0x83u, 0xc4u, 0xd8u});
  image->Put({0x8bu, 0x93u});  // mov edx,[ebx+counter]
  image->Put32(counter);
  image->Put({0x8bu, 0x8bu});  // mov ecx,[ebx+pos]
  image->Put32(counter + 8u);
  image->Put({0x8bu, 0xc2u});         // mov eax,edx
  image->Put({0x8du, 0x14u, 0x50u});  // lea edx,[eax+edx*2]   3r
  image->Put({0x8du, 0x14u, 0x90u});  // lea edx,[eax+edx*4]  13r
  image->Put({0x8du, 0x14u, 0x90u});  // lea edx,[eax+edx*4]  53r
  image->Put({0x8bu, 0xc3u});         // mov eax,ebx
  image->Put({0x03u, 0xd3u});         // add edx,ebx
  image->Put({0x81u, 0xc2u});         // add edx,base
  image->Put32(base);
  image->Nops(16u);
  image->Put({0x8bu, 0x8bu});  // mov ecx,[ebx+counter]
  image->Put32(counter);
  image->Put({0x8du, 0x93u});  // lea edx,[ebx+base]
  image->Put32(base);
  image->Put({0x8bu, 0xc3u});  // mov eax,ebx
  image->Call(render);
  image->Put({0xc3u});
}

// The song lyric box: same row arithmetic, but RENDER gets the row from an
// argument (mov ecx,ebx), not from the counter.
void EmitSongCaller(Image* image, uint32_t rva) {
  image->Seek(rva);
  image->Put({0x55u, 0x8bu, 0xecu, 0x83u, 0xc4u, 0xd0u});
  image->Put({0x8bu, 0x93u});  // mov edx,[ebx+0x700]
  image->Put32(0x700u);
  image->Put({0x8bu, 0xc2u});
  image->Put({0x8du, 0x14u, 0x50u});
  image->Put({0x8du, 0x14u, 0x90u});
  image->Put({0x8du, 0x14u, 0x90u});  // stride 53, as the message window
  image->Put({0x81u, 0xc2u});
  image->Put32(0x5f9u);
  image->Nops(16u);
  image->Put({0x8du, 0x96u});  // lea edx,[esi+0x5f9]
  image->Put32(0x5f9u);
  image->Put({0x8bu, 0xcbu});  // mov ecx,ebx
  image->Call(kSongRender);
  image->Put({0xc3u});
}

void EmitExports(Image* image, bool with_draw) {
  struct Name {
    const char* text;
    uint32_t function;
  };
  std::vector<Name> names = {{kh::kExportBoxFill, kBoxFill},
                             {kh::kExportSetText, kSetText},
                             {"@THyRGBPanel@ClientToScreen$qqrrit1", 0x1030u}};
  if (with_draw) names.push_back({kh::kExportDraw, kDraw});
  const uint32_t functions = kExportDir + 0x40u;
  const uint32_t name_table = functions + 0x40u;
  const uint32_t ordinals = name_table + 0x40u;
  uint32_t strings = ordinals + 0x40u;
  IMAGE_EXPORT_DIRECTORY dir = {};
  dir.NumberOfFunctions = static_cast<DWORD>(names.size());
  dir.NumberOfNames = static_cast<DWORD>(names.size());
  dir.AddressOfFunctions = functions;
  dir.AddressOfNames = name_table;
  dir.AddressOfNameOrdinals = ordinals;
  std::memcpy(image->bytes.data() + kExportDir, &dir, sizeof(dir));
  for (uint32_t i = 0u; i < names.size(); ++i) {
    std::memcpy(image->bytes.data() + functions + i * 4u, &names[i].function, 4u);
    std::memcpy(image->bytes.data() + name_table + i * 4u, &strings, 4u);
    const uint16_t ordinal = static_cast<uint16_t>(i);
    std::memcpy(image->bytes.data() + ordinals + i * 2u, &ordinal, 2u);
    const size_t length = std::strlen(names[i].text) + 1u;
    std::memcpy(image->bytes.data() + strings, names[i].text, length);
    strings += static_cast<uint32_t>(length);
  }
}

void EmitHeaders(Image* image) {
  IMAGE_DOS_HEADER dos = {};
  dos.e_magic = IMAGE_DOS_SIGNATURE;
  dos.e_lfanew = 0x80;
  std::memcpy(image->bytes.data(), &dos, sizeof(dos));
  IMAGE_NT_HEADERS32 nt = {};
  nt.Signature = IMAGE_NT_SIGNATURE;
  nt.FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
  nt.FileHeader.NumberOfSections = 1;
  nt.FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER32);
  nt.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
  nt.OptionalHeader.ImageBase = kVaBase;
  nt.OptionalHeader.SizeOfImage = kImageSize;
  nt.OptionalHeader.SizeOfHeaders = 0x400u;
  nt.OptionalHeader.NumberOfRvaAndSizes = IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
  nt.OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT] = {kExportDir,
                                                                  0x400u};
  std::memcpy(image->bytes.data() + 0x80, &nt, sizeof(nt));
  IMAGE_SECTION_HEADER text = {};
  std::memcpy(text.Name, ".text", 5u);
  text.VirtualAddress = kCodeBegin;
  text.Misc.VirtualSize = kCodeEnd - kCodeBegin;
  text.SizeOfRawData = kCodeEnd - kCodeBegin;
  text.Characteristics = IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_CNT_CODE;
  std::memcpy(image->bytes.data() + 0x80 + sizeof(nt), &text, sizeof(text));
}

// SHOWMSG: picks the window's row filler by the mode byte, through the game
// object's message window field [ebx+0x7c].
void EmitShowMessage(Image* image) {
  image->Seek(kShowMessage);
  image->Put({0x55u, 0x8bu, 0xecu, 0x83u, 0xc4u, 0xd8u});
  image->Put({0xa0u});  // mov al,[MODE]
  image->Put32(kModeGlobal);
  image->Put({0x84u, 0xc0u});  // test al,al
  image->Put({0x74u, 0x08u});  // je +8
  image->Put({0x8bu, 0x43u, 0x7cu});  // mov eax,[ebx+0x7c]
  image->Call(kMessageCaller);
  image->Put({0xc3u});
  image->Put({0x8bu, 0x43u, 0x7cu});  // mov eax,[ebx+0x7c]
  image->Call(kMessageCaller);
  image->Put({0xc3u});
}

// The cursor shape: mov cl,[MODE]; test; je B; mov dl,1; mov eax,[ebx+0x7c];
// call full-screen; jmp E; B: mov dl,1; mov eax,[ebx+0x7c]; call adventure.
void EmitCursorShape(Image* image) {
  image->Put({0x8au, 0x0du});  // mov cl,[MODE]
  image->Put32(kModeGlobal);
  image->Put({0x84u, 0xc9u});         // test cl,cl
  image->Put({0x74u, 0x0cu});         // je B (+12)
  image->Put({0xb2u, 0x01u});         // mov dl,1
  image->Put({0x8bu, 0x43u, 0x7cu});  // mov eax,[ebx+0x7c]
  image->Call(kCursorFullScreen);
  image->Put({0xebu, 0x0au});         // jmp E (+10)
  image->Put({0xb2u, 0x01u});         // B: mov dl,1
  image->Put({0x8bu, 0x43u, 0x7cu});
  image->Call(kCursorAdventure);
}

// WAIT: a short method (no frame), the shape right after its entry; one
// caller derefs the game object first.
void EmitWait(Image* image, uint32_t rva, uint32_t caller) {
  image->Seek(rva);
  image->Put({0x53u, 0x8bu, 0xd8u});  // push ebx; mov ebx,eax
  image->Put({0xc6u, 0x83u, 0x90u, 0x00u, 0x00u, 0x00u, 0x00u});
  EmitCursorShape(image);
  image->Put({0x5bu, 0xc3u});  // pop ebx; ret
  image->Seek(caller);
  image->Put({0x8bu, 0x00u});  // mov eax,[eax]
  image->Call(rva);
  image->Put({0xc3u});
}

// The window's restore path: the same shape deep inside a long function.
void EmitRestore(Image* image) {
  image->Seek(kRestore);
  image->Put({0x55u, 0x8bu, 0xecu, 0x83u, 0xc4u, 0xd8u});
  image->Nops(0x100u);
  EmitCursorShape(image);
  image->Put({0xc3u});
  image->Seek(kRestore + 0x180u);
  image->Call(kRestore);
}

struct Options {
  bool draw_export = true;
  bool message_caller = true;
  bool song = true;
  bool second_message_renderer = false;
  bool show_message = true;
  bool wait = true;
  bool restore = true;
  bool second_wait = false;
};

Image Build(const Options& options) {
  Image image;
  EmitHeaders(&image);
  EmitExports(&image, options.draw_export);
  for (uint32_t f : {kSetText, kBoxFill, kDraw, 0x1030u}) {
    image.Seek(f);
    image.Put({0xc3u});
  }
  EmitRenderer(&image, kRender);
  if (options.message_caller) {
    EmitMessageCaller(&image, kMessageCaller, kRender, 0x1ecu, 0x118u);
  }
  if (options.song) {
    EmitRenderer(&image, kSongRender);
    EmitSongCaller(&image, kSongCaller);
  }
  if (options.second_message_renderer) {
    EmitRenderer(&image, kSecondRender);
    EmitMessageCaller(&image, kSecondCaller, kSecondRender, 0x598u, 0x248u);
  }
  for (uint32_t f : {kCursorFullScreen, kCursorAdventure}) {
    image.Seek(f);
    image.Put({0xc3u});
  }
  if (options.show_message) EmitShowMessage(&image);
  if (options.wait) EmitWait(&image, kWait, kWaitCaller);
  if (options.restore) EmitRestore(&image);
  if (options.second_wait) EmitWait(&image, kSecondWait, kSecondWaitCaller);
  return image;
}

kh::ImageView View(const Image& image) {
  kh::ImageView view;
  view.bytes = image.bytes.data();
  view.size = image.bytes.size();
  view.va_base = kVaBase;
  view.export_rva = kExportDir;
  view.export_size = 0x400u;
  view.code[0] = {kCodeBegin, kCodeEnd};
  view.code_count = 1u;
  return view;
}

void TestResolvesMessageRenderer() {
  const Image image = Build(Options());
  kh::Sites sites;
  assert(kh::ResolveSites(View(image), &sites) == kh::SiteResult::kResolved);
  assert(sites.render == kRender);
  assert(sites.text_object == 0x84u);
  assert(sites.stride == 53u);
  assert(sites.callers == 1u);
  assert(sites.base_count == 1u && sites.bases[0] == 0x118u);
}

void TestIdentityNeedsEveryHyExport() {
  const Image good = Build(Options());
  assert(fushi_voice_hook::IsKogadoHyImage(good.bytes.data(), good.bytes.size()));
  Options options;
  options.draw_export = false;
  const Image missing = Build(options);
  assert(!fushi_voice_hook::IsKogadoHyImage(missing.bytes.data(),
                                            missing.bytes.size()));
  kh::Sites sites;
  assert(kh::ResolveSites(View(missing), &sites) == kh::SiteResult::kNoExports);
  assert(sites.render == 0u);
}

void TestArgumentRowWindowIsNoMessage() {
  Options options;
  options.message_caller = false;
  const Image image = Build(options);
  kh::Sites sites;
  // The song box and the unreferenced message renderer: neither is fed by a
  // counter-indexed page buffer.
  assert(kh::ResolveSites(View(image), &sites) ==
         kh::SiteResult::kNoMessageRenderer);
}

void TestTwoMessageRenderersAreAmbiguous() {
  Options options;
  options.second_message_renderer = true;
  const Image image = Build(options);
  kh::Sites sites;
  assert(kh::ResolveSites(View(image), &sites) == kh::SiteResult::kAmbiguous);
  assert(sites.render == 0u);
}

void TestResolvesClickWait() {
  const Image image = Build(Options());
  kh::Sites sites;
  assert(kh::ResolveSites(View(image), &sites) == kh::SiteResult::kResolved);
  assert(sites.callers == 1u && sites.render_calls[0] != 0u);
  kh::WaitSite wait;
  assert(kh::ResolveWait(View(image), sites, &wait) ==
         kh::WaitResult::kResolved);
  assert(wait.wait == kWait);
  assert(wait.window_offset == 0x7cu);
  assert(wait.mode_global == kModeGlobal);
}

void TestClickWaitNeedsShowMessage() {
  Options options;
  options.show_message = false;
  const Image image = Build(options);
  kh::Sites sites;
  assert(kh::ResolveSites(View(image), &sites) == kh::SiteResult::kResolved);
  kh::WaitSite wait;
  assert(kh::ResolveWait(View(image), sites, &wait) ==
         kh::WaitResult::kNoShowMessage);
  assert(wait.wait == 0u);
}

void TestRestorePathIsNoClickWait() {
  // Only the restore path shows the cursor: its shape has no entry nearby.
  Options options;
  options.wait = false;
  const Image image = Build(options);
  kh::Sites sites;
  assert(kh::ResolveSites(View(image), &sites) == kh::SiteResult::kResolved);
  kh::WaitSite wait;
  assert(kh::ResolveWait(View(image), sites, &wait) ==
         kh::WaitResult::kNoEntry);
  options.restore = false;
  const Image bare = Build(options);
  assert(kh::ResolveSites(View(bare), &sites) == kh::SiteResult::kResolved);
  assert(kh::ResolveWait(View(bare), sites, &wait) == kh::WaitResult::kNoWait);
}

void TestTwoClickWaitsAreAmbiguous() {
  Options options;
  options.second_wait = true;
  const Image image = Build(options);
  kh::Sites sites;
  assert(kh::ResolveSites(View(image), &sites) == kh::SiteResult::kResolved);
  kh::WaitSite wait;
  assert(kh::ResolveWait(View(image), sites, &wait) ==
         kh::WaitResult::kAmbiguous);
  assert(wait.wait == 0u);
}

void TestNonHyImageHasNoExports() {
  Image image;
  EmitHeaders(&image);
  kh::Sites sites;
  assert(!fushi_voice_hook::IsKogadoHyImage(image.bytes.data(),
                                            image.bytes.size()));
  assert(kh::ResolveSites(View(image), &sites) == kh::SiteResult::kNoExports);
}

// ── page rules ─────────────────────────────────────────────────────────────

constexpr uint32_t kStride = 53u;

std::vector<uint8_t> Rows(std::initializer_list<std::string> rows) {
  std::vector<uint8_t> out(kStride * rows.size(), 0u);
  size_t r = 0u;
  for (const std::string& row : rows) {
    assert(row.size() < kStride);
    std::memcpy(out.data() + r * kStride, row.data(), row.size());
    ++r;
  }
  return out;
}

// CP932 spellings (synthetic text): 【A】, 「あい, 　うえ」, あい, うえ.
const std::string kName = "\x81\x79\x82\x60\x81\x7a";
const std::string kQuoteOpen = "\x81\x75\x82\xa0\x82\xa2";
const std::string kIndentClose = "\x81\x40\x82\xa4\x82\xa6\x81\x76";
const std::string kAi = "\x82\xa0\x82\xa2";
const std::string kUe = "\x82\xa4\x82\xa6";

void TestPageJoinsRowsAndDropsSpeaker() {
  const std::vector<uint8_t> rows = Rows({kName, kQuoteOpen, kIndentClose});
  std::string text;
  bool speaker = false;
  assert(kh::ComposePage(rows.data(), kStride, 0u, 2u, &text, &speaker) ==
         kh::PageResult::kText);
  assert(speaker);
  assert(text == kQuoteOpen + "\x82\xa4\x82\xa6\x81\x76");
  // The page so far grows by whole rows: each later page extends the former.
  std::string first;
  assert(kh::ComposePage(rows.data(), kStride, 0u, 1u, &first, &speaker) ==
         kh::PageResult::kText);
  assert(text.compare(0u, first.size(), first) == 0);
}

void TestNameOnlyPagePublishesNothing() {
  const std::vector<uint8_t> rows = Rows({kName});
  std::string text;
  bool speaker = false;
  assert(kh::ComposePage(rows.data(), kStride, 0u, 0u, &text, &speaker) ==
         kh::PageResult::kNameOnly);
  assert(text.empty() && speaker);
}

void TestNarrationKeepsFirstRowIndent() {
  // Only a continuation row's indent is layout; the page's first row keeps
  // its own leading space, and a bracket inside a row is no speaker row.
  const std::vector<uint8_t> rows =
      Rows({"\x81\x40" + kAi, kUe, kName + kAi});
  std::string text;
  bool speaker = false;
  assert(kh::ComposePage(rows.data(), kStride, 0u, 2u, &text, &speaker) ==
         kh::PageResult::kText);
  assert(!speaker);
  assert(text == "\x81\x40" + kAi + kUe + kName + kAi);
}

void TestFullScreenUnitStartsAfterTheWait() {
  // A full-screen page keeps earlier units: rows 0..1 are the previous click
  // unit, row 2 is a blank line, rows 3..4 the current one (speaker first).
  const std::vector<uint8_t> rows = Rows({kAi, kUe, "", kName, kAi});
  std::string text;
  bool speaker = false;
  assert(kh::ComposePage(rows.data(), kStride, 3u, 4u, &text, &speaker) ==
         kh::PageResult::kText);
  assert(speaker && text == kAi);
  // A unit that runs over a blank line joins the rows around it.
  assert(kh::ComposePage(rows.data(), kStride, 0u, 2u, &text, &speaker) ==
         kh::PageResult::kText);
  assert(!speaker && text == kAi + kUe);
}

void TestBrokenRowsAreRejected() {
  std::string text;
  bool speaker = false;
  // Lead byte without its trail byte.
  std::vector<uint8_t> broken = Rows({kAi + "\x82"});
  assert(kh::ComposePage(broken.data(), kStride, 0u, 0u, &text, &speaker) ==
         kh::PageResult::kRejected);
  // Control byte.
  std::vector<uint8_t> control = Rows({kAi + "\x01"});
  assert(kh::ComposePage(control.data(), kStride, 0u, 0u, &text, &speaker) ==
         kh::PageResult::kRejected);
  // No terminator inside the stride.
  std::vector<uint8_t> full(kStride, 'a');
  assert(kh::ComposePage(full.data(), kStride, 0u, 0u, &text, &speaker) ==
         kh::PageResult::kRejected);
  // Out-of-range row / stride.
  std::vector<uint8_t> rows = Rows({kAi});
  assert(kh::ComposePage(rows.data(), kStride, 0u, kh::kMaxRows, &text,
                         &speaker) == kh::PageResult::kRejected);
  assert(kh::ComposePage(rows.data(), 8u, 0u, 0u, &text, &speaker) ==
         kh::PageResult::kRejected);
  // A unit cannot start after its last row.
  assert(kh::ComposePage(rows.data(), kStride, 1u, 0u, &text, &speaker) ==
         kh::PageResult::kRejected);
}

}  // namespace

int main() {
  TestResolvesMessageRenderer();
  TestIdentityNeedsEveryHyExport();
  TestArgumentRowWindowIsNoMessage();
  TestTwoMessageRenderersAreAmbiguous();
  TestResolvesClickWait();
  TestClickWaitNeedsShowMessage();
  TestRestorePathIsNoClickWait();
  TestTwoClickWaitsAreAmbiguous();
  TestNonHyImageHasNoExports();
  TestPageJoinsRowsAndDropsSpeaker();
  TestNameOnlyPagePublishesNothing();
  TestNarrationKeepsFirstRowIndent();
  TestFullScreenUnitStartsAfterTheWait();
  TestBrokenRowsAreRejected();
  std::printf("kogado_hy adapter tests passed\n");
  return 0;
}
