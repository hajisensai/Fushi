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

#include "malie_engine_io_core.h"

namespace io = fushi_voice_hook::malie_io;
namespace exact = fushi_voice_hook::exact_lookup;

namespace {

// ── synthetic x86 image: code [0, 0x8000), data [0x8000, 0x10000) ──────────

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

// ── identity: scheme registration ──────────────────────────────────────────

constexpr size_t kCfiBuilder = 0x1000u;
constexpr size_t kWciBuilder = 0x1200u;
constexpr size_t kDupBuilder = 0x1400u;
constexpr size_t kRegistrar = 0x2000u;
constexpr size_t kGetc = 0x2100u;
constexpr size_t kRead = 0x2200u;
constexpr size_t kTell = 0x2300u;
constexpr size_t kSeek = 0x2400u;
constexpr size_t kOpen = 0x2500u;
constexpr size_t kClose = 0x2600u;
constexpr size_t kCfiName = kDataRva + 0x40u;
constexpr size_t kWciName = kDataRva + 0x80u;

struct BuildOptions {
  int8_t name_store = -0x4a;  // T + 0x20 - 2 with T = -0x68
  bool with_tell = true;
  size_t read_target = kRead;
};

// Mirrors the measured registration function: copy the name into the
// table, store the six slots, hand the table to the registrar.
void PutBuilder(SyntheticImage* img, size_t at, size_t name_rva,
                const BuildOptions& options = BuildOptions()) {
  at = img->Put(at, {0x55, 0x8b, 0xec, 0x83, 0xec, 0x68, 0x33, 0xc0});
  at = img->Put(at, {0x0f, 0xb7, 0x88});
  at = img->Abs(at, name_rva);
  at = img->Put(at, {0x8d, 0x40, 0x02, 0x66, 0x89, 0x4c, 0x05,
                     static_cast<uint8_t>(options.name_store), 0x66, 0x85,
                     0xc9, 0x75, 0xee});
  at = img->Put(at, {0x8d, 0x45, 0x98});
  at = img->Put(at, {0xc7, 0x45, 0xb0});
  at = img->Abs(at, kOpen);
  at = img->Put(at, {0x50});
  at = img->Put(at, {0xc7, 0x45, 0xb4});
  at = img->Abs(at, kClose);
  if (options.with_tell) {
    at = img->Put(at, {0xc7, 0x45, 0xa8});
    at = img->Abs(at, kTell);
  }
  at = img->Put(at, {0xc7, 0x45, 0xac});
  at = img->Abs(at, kSeek);
  at = img->Put(at, {0xc7, 0x45, 0xa0});
  at = img->Abs(at, options.read_target);
  at = img->Put(at, {0xc7, 0x45, 0x98});
  at = img->Abs(at, kGetc);
  at = img->Rel32(at, kRegistrar);
  img->Put(at, {0x8b, 0xe5, 0x5d, 0xc3});
}

void PutSlots(SyntheticImage* img, bool tell_shape = true,
              bool getc_calls_read = true) {
  img->Put(kRegistrar, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
  size_t at = img->Put(kGetc, {0x55, 0x8b, 0xec, 0x51, 0x6a, 0x01});
  at = img->Rel32(at, getc_calls_read ? kRead : kSeek);
  img->Put(at, {0x8b, 0xe5, 0x5d, 0xc3});
  img->Put(kRead, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
  if (tell_shape) {
    img->Put(kTell, {0x55, 0x8b, 0xec, 0x8b, 0x45, 0x08, 0x8b, 0x80, 0x48,
                     0x01, 0x00, 0x00, 0x5d, 0xc3});
  } else {
    img->Put(kTell, {0x55, 0x8b, 0xec, 0x33, 0xc0, 0x5d, 0xc3});
  }
  img->Put(kSeek, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
  img->Put(kOpen, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
  img->Put(kClose, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
}

void BuildScheme(SyntheticImage* img) {
  img->Wide(kCfiName, L"CFI");
  img->Wide(kWciName, L"WC_I");
  PutBuilder(img, kCfiBuilder, kCfiName);
  PutBuilder(img, kWciBuilder, kWciName);
  PutSlots(img);
}

io::SchemeResult Scheme(const SyntheticImage& img) {
  return io::ResolveScheme(img.image, io::kArchiveSchemeName);
}

void TestSchemeResolvesFromStructure() {
  SyntheticImage img;
  BuildScheme(&img);
  assert(Scheme(img) == io::SchemeResult::kResolved);
}

void TestSchemeFailsClosed() {
  {
    SyntheticImage img(IMAGE_FILE_MACHINE_AMD64, 64u);
    BuildScheme(&img);
    assert(Scheme(img) == io::SchemeResult::kNotX86);
  }
  {  // no "CFI" literal (only another scheme)
    SyntheticImage img;
    BuildScheme(&img);
    img.Wide(kCfiName, L"CFX");
    assert(Scheme(img) == io::SchemeResult::kNoName);
  }
  {  // "XCFI": not a string start
    SyntheticImage img;
    BuildScheme(&img);
    img.Wide(kCfiName - 2u, L"XCFI");
    assert(Scheme(img) == io::SchemeResult::kNoName);
  }
  {  // literal present, nothing copies it
    SyntheticImage img;
    BuildScheme(&img);
    std::memset(img.base + kCfiBuilder, 0xcc, 0x100u);
    assert(Scheme(img) == io::SchemeResult::kNoNameCopy);
  }
  {  // two builders copy the same name
    SyntheticImage img;
    BuildScheme(&img);
    PutBuilder(&img, kDupBuilder, kCfiName);
    assert(Scheme(img) == io::SchemeResult::kAmbiguousNameCopy);
  }
  {  // the copy does not store into the table's name field
    SyntheticImage img;
    BuildScheme(&img);
    BuildOptions options;
    options.name_store = -0x30;
    PutBuilder(&img, kCfiBuilder, kCfiName, options);
    assert(Scheme(img) == io::SchemeResult::kNameOffsetMismatch);
  }
  {  // no tell slot store
    SyntheticImage img;
    BuildScheme(&img);
    BuildOptions options;
    options.with_tell = false;
    PutBuilder(&img, kCfiBuilder, kCfiName, options);
    assert(Scheme(img) == io::SchemeResult::kMissingSlot);
  }
  {  // a slot that is not a frame function
    SyntheticImage img;
    BuildScheme(&img);
    img.Put(kOpen, {0x90, 0x90, 0x90});
    assert(Scheme(img) == io::SchemeResult::kSlotNotFunction);
  }
  {  // read and seek share one target
    SyntheticImage img;
    BuildScheme(&img);
    BuildOptions options;
    options.read_target = kSeek;
    PutBuilder(&img, kCfiBuilder, kCfiName, options);
    assert(Scheme(img) == io::SchemeResult::kSlotNotFunction);
  }
  {  // tell does not read a stream field
    SyntheticImage img;
    BuildScheme(&img);
    PutSlots(&img, /*tell_shape=*/false);
    assert(Scheme(img) == io::SchemeResult::kTellShape);
  }
  {  // getc does not read through the read slot
    SyntheticImage img;
    BuildScheme(&img);
    PutSlots(&img, true, /*getc_calls_read=*/false);
    assert(Scheme(img) == io::SchemeResult::kGetcNotRead);
  }
  {  // a registrar no other scheme uses
    SyntheticImage img;
    BuildScheme(&img);
    std::memset(img.base + kWciBuilder, 0xcc, 0x100u);
    assert(Scheme(img) == io::SchemeResult::kRegistrarNotShared);
  }
}

// ── voice: Ogg decoder input ───────────────────────────────────────────────

constexpr size_t kSyncWrote = 0x3000u;
constexpr size_t kSyncBuffer = 0x3100u;
constexpr size_t kStreamRead = 0x3200u;
constexpr size_t kFeedA = 0x3400u;  // header refill (push reg)
constexpr size_t kFeedB = 0x3500u;  // decode refill (mov eax,[ebp+8])
constexpr size_t kDecoderOpen = 0x3600u;
constexpr size_t kOtherWrote = 0x3700u;  // a wrote call that is no refill
constexpr uint32_t kStreamField = 0x4f8u;
constexpr uint32_t kPathField = 0x2c8u;

// push 0x1000; push edi; call buffer; push 0x1000; push eax;
// push [edi+S]; call read; push eax; push edi; call wrote
size_t PutFeedA(SyntheticImage* img, size_t at, uint32_t field) {
  at = img->Put(at, {0x68, 0x00, 0x10, 0x00, 0x00, 0x57});
  at = img->Rel32(at, kSyncBuffer);
  at = img->Put(at, {0x68, 0x00, 0x10, 0x00, 0x00, 0x50, 0xff, 0xb7});
  at = img->Imm32(at, field);
  at = img->Rel32(at, kStreamRead);
  at = img->Put(at, {0x50, 0x57});
  return img->Rel32(at, kSyncWrote);
}

// push 0x1000; push [ebp+8]; call buffer; push 0x1000; push eax;
// mov eax,[ebp+8]; push [eax+S]; call read; add esp,0x14; push eax;
// push [ebp+8]; call wrote
size_t PutFeedB(SyntheticImage* img, size_t at, uint32_t field) {
  at = img->Put(at, {0x68, 0x00, 0x10, 0x00, 0x00, 0xff, 0x75, 0x08});
  at = img->Rel32(at, kSyncBuffer);
  at = img->Put(at, {0x68, 0x00, 0x10, 0x00, 0x00, 0x50, 0x8b, 0x45, 0x08,
                     0xff, 0xb0});
  at = img->Imm32(at, field);
  at = img->Rel32(at, kStreamRead);
  at = img->Put(at, {0x83, 0xc4, 0x14, 0x50, 0xff, 0x75, 0x08});
  return img->Rel32(at, kSyncWrote);
}

// mov [edi+S],eax; test eax,eax; jne +0f; ...; lea ecx,[edi+P];
// sub ecx,esi; nop; movzx eax,word [esi]
void PutDecoderOpen(SyntheticImage* img, uint32_t path_field) {
  size_t at = img->Put(kDecoderOpen, {0x89, 0x87});
  at = img->Imm32(at, kStreamField);
  at = img->Put(at, {0x85, 0xc0, 0x75, 0x0f, 0x57, 0x90, 0x90, 0x90, 0x90,
                     0x90, 0x83, 0xc4, 0x04, 0x33, 0xc0, 0x5e, 0x5f, 0x5d,
                     0xc3, 0x8d, 0x8f});
  at = img->Imm32(at, path_field);
  img->Put(at, {0x2b, 0xce, 0x90, 0x0f, 0xb7, 0x06, 0x8d, 0x76, 0x02});
}

size_t g_feed_a_return = 0u;
size_t g_feed_b_return = 0u;

void BuildDecoder(SyntheticImage* img) {
  img->PutBytes(kSyncWrote, io::kSyncWroteBytes, sizeof(io::kSyncWroteBytes));
  img->PutBytes(kSyncBuffer, io::kSyncBufferBytes,
                sizeof(io::kSyncBufferBytes));
  img->Put(kStreamRead, {0x55, 0x8b, 0xec, 0x5d, 0xc3});
  g_feed_a_return = PutFeedA(img, kFeedA, kStreamField);
  g_feed_b_return = PutFeedB(img, kFeedB, kStreamField);
  PutDecoderOpen(img, kPathField);
  // A non-refill call of the same libogg function (no buffer call before it)
  // is not a feed site and must not be hooked as one.
  size_t at = img->Put(kOtherWrote, {0x6a, 0x00, 0x56});
  img->Rel32(at, kSyncWrote);
}

void TestFeedResolvesFromStructure() {
  SyntheticImage img;
  BuildDecoder(&img);
  io::OggFeedSites sites;
  assert(io::ResolveOggFeed(img.image, &sites) ==
         io::FeedResult::kResolved);
  assert(sites.sync_wrote == img.At(kSyncWrote));
  assert(sites.sync_buffer == img.At(kSyncBuffer));
  assert(sites.feed_count == 2u);
  assert(sites.feed_returns[0] == img.At(g_feed_a_return));
  assert(sites.feed_returns[1] == img.At(g_feed_b_return));
  assert(sites.stream_field == kStreamField);
  assert(sites.path_field == kPathField);
}

void TestFeedFailsClosed() {
  io::OggFeedSites sites;
  {
    SyntheticImage img(IMAGE_FILE_MACHINE_AMD64, 64u);
    BuildDecoder(&img);
    assert(io::ResolveOggFeed(img.image, &sites) == io::FeedResult::kNotX86);
  }
  {  // no libogg ogg_sync_wrote
    SyntheticImage img;
    BuildDecoder(&img);
    img.Put(kSyncWrote + 9u, {0x01});
    assert(io::ResolveOggFeed(img.image, &sites) ==
           io::FeedResult::kNoSyncWrote);
  }
  {  // two copies of ogg_sync_wrote
    SyntheticImage img;
    BuildDecoder(&img);
    img.PutBytes(0x4000u, io::kSyncWroteBytes, sizeof(io::kSyncWroteBytes));
    assert(io::ResolveOggFeed(img.image, &sites) ==
           io::FeedResult::kNoSyncWrote);
  }
  {  // no ogg_sync_buffer
    SyntheticImage img;
    BuildDecoder(&img);
    img.Put(kSyncBuffer + 3u, {0x90});
    assert(io::ResolveOggFeed(img.image, &sites) ==
           io::FeedResult::kNoSyncBuffer);
  }
  {  // no refill site: wrote is only ever called without a buffer call
    SyntheticImage img;
    BuildDecoder(&img);
    std::memset(img.base + kFeedA, 0xcc, 0x60u);
    std::memset(img.base + kFeedB, 0xcc, 0x60u);
    assert(io::ResolveOggFeed(img.image, &sites) ==
           io::FeedResult::kNoFeedSite);
  }
  {  // two refill sites read through different decoder fields
    SyntheticImage img;
    BuildDecoder(&img);
    PutFeedB(&img, kFeedB, kStreamField + 4u);
    assert(io::ResolveOggFeed(img.image, &sites) ==
           io::FeedResult::kFeedFieldMismatch);
  }
  {  // the decoder never copies a path next to its stream field
    SyntheticImage img;
    BuildDecoder(&img);
    img.Put(kDecoderOpen + 31u, {0x90, 0x90});  // break `sub ecx,esi`
    assert(io::ResolveOggFeed(img.image, &sites) ==
           io::FeedResult::kNoPathCopy);
  }
  {  // two decoder opens copy the path to different fields
    SyntheticImage img;
    BuildDecoder(&img);
    size_t at = img.Put(0x3800u, {0x89, 0x87});
    at = img.Imm32(at, kStreamField);
    at = img.Put(at, {0x8d, 0x8f});
    at = img.Imm32(at, kPathField + 8u);
    img.Put(at, {0x2b, 0xce, 0x0f, 0xb7, 0x06});
    assert(io::ResolveOggFeed(img.image, &sites) ==
           io::FeedResult::kAmbiguousPathCopy);
  }
}

void TestVoiceClassification() {
  assert(io::IsVoicePath(L"data\\voice\\vir\\v_vir0001.ogg"));
  assert(io::IsVoicePath(L"voice/kru/V_KRU0001.OGG"));
  assert(!io::IsVoicePath(L"data\\bgm\\01.ogg"));
  assert(!io::IsVoicePath(L"data\\se\\se001.ogg"));
  assert(!io::IsVoicePath(L"data\\myvoice\\x.ogg"));  // not a component
  assert(!io::IsVoicePath(L"data\\voice\\vir\\v_vir0001.wav"));
  assert(!io::IsVoicePath(L"voice"));
  assert(!io::IsVoicePath(nullptr));
  assert(io::VoiceStorageName(L"data\\voice\\vir\\v_vir0001.ogg") ==
         L"vir_v_vir0001.ogg");
  assert(io::VoiceStorageName(L"voice/kru/v_kru0002.ogg") ==
         L"kru_v_kru0002.ogg");
}

std::vector<uint8_t> OggPage(uint32_t serial, uint8_t flags,
                             uint8_t payload_bytes) {
  std::vector<uint8_t> page(27u + 1u + payload_bytes, 0u);
  std::memcpy(page.data(), "OggS", 4u);
  page[5] = flags;
  std::memcpy(page.data() + 14u, &serial, 4u);
  page[26] = 1u;
  page[27] = payload_bytes;
  return page;
}

void TestPagePrefix() {
  std::vector<uint8_t> stream;
  for (int i = 0; i < 5; ++i) {
    const auto page = OggPage(7u, i == 0 ? 0x02u : 0x00u, 10u);
    stream.insert(stream.end(), page.begin(), page.end());
  }
  const uint32_t page_bytes = 27u + 1u + 10u;
  // Whole pages only; a torn tail is cut.
  assert(io::OggPagePrefixBytes(stream.data(),
                                static_cast<uint32_t>(stream.size())) ==
         5u * page_bytes);
  assert(io::OggPagePrefixBytes(stream.data(),
                                static_cast<uint32_t>(stream.size()) - 3u) ==
         4u * page_bytes);
  // Fewer than four whole pages: nothing worth publishing.
  assert(io::OggPagePrefixBytes(stream.data(), 3u * page_bytes + 5u) == 0u);
  // Another logical stream ends the prefix.
  std::vector<uint8_t> mixed(stream.begin(), stream.begin() + 4u * page_bytes);
  const auto foreign = OggPage(9u, 0u, 10u);
  mixed.insert(mixed.end(), foreign.begin(), foreign.end());
  assert(io::OggPagePrefixBytes(mixed.data(),
                                static_cast<uint32_t>(mixed.size())) ==
         4u * page_bytes);
  assert(io::OggPagePrefixBytes(nullptr, 100u) == 0u);
  assert(io::VoiceStorageName(L"data\\voice\\vir\\v_vir0002.ogg", true) ==
         L"vir_v_vir0002.partial.ogg");
}

}  // namespace

int main() {
  TestPagePrefix();
  TestSchemeResolvesFromStructure();
  TestSchemeFailsClosed();
  TestFeedResolvesFromStructure();
  TestFeedFailsClosed();
  TestVoiceClassification();
  std::printf("malie_engine_io_test: ok\n");
  return 0;
}
