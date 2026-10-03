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

// ── voice assembly ─────────────────────────────────────────────────────────

constexpr uint32_t kPageBytes = 27u + 1u + 10u;

// A logical stream of `pages` pages (BOS first, EOS last when `eos`).
std::vector<uint8_t> OggStream(uint32_t serial, int pages, bool eos) {
  std::vector<uint8_t> stream;
  for (int i = 0; i < pages; ++i) {
    uint8_t flags = i == 0 ? 0x02u : 0x00u;
    if (eos && i == pages - 1) flags = static_cast<uint8_t>(flags | 0x04u);
    const auto page = OggPage(serial, flags, 10u);
    stream.insert(stream.end(), page.begin(), page.end());
  }
  return stream;
}

struct Written {
  std::wstring storage;
  uint32_t bytes = 0u;
  uint64_t text_event = 0u;
};

class FakeSink final : public io::VoiceSink {
 public:
  uint64_t TextEvent(const std::wstring& path, uint64_t) override {
    return path == bound_path ? bound_event : 0u;
  }
  bool Write(const uint8_t* data, uint32_t bytes, const std::wstring& storage,
             uint64_t, uint64_t text_event) override {
    assert(data != nullptr && bytes != 0u);
    written.push_back({storage, bytes, text_event});
    return true;
  }
  void Note(const wchar_t*, const std::wstring&, uint32_t, uint32_t) override {
    ++notes;
  }
  std::wstring bound_path;
  uint64_t bound_event = 0u;
  std::vector<Written> written;
  int notes = 0;
};

constexpr wchar_t kVoiceA[] = L"data\\voice\\vir\\v_vir0001.ogg";
constexpr wchar_t kVoiceB[] = L"data\\voice\\kru\\v_kru0001.ogg";

// Feeds `bytes` as chunks of `chunk` bytes; returns the next feed number.
uint64_t FeedStream(io::VoiceAssembler* assembler, FakeSink* sink,
                    uintptr_t decoder, const wchar_t* path,
                    const std::vector<uint8_t>& bytes, size_t begin,
                    size_t end, uint64_t feed, uint64_t tick,
                    size_t chunk = 50u) {
  for (size_t at = begin; at < end; at += chunk) {
    io::FeedChunk c;
    c.feed = feed++;
    c.decoder = decoder;
    c.tick = tick;
    c.path = path;
    c.data = bytes.data() + at;
    c.length = static_cast<uint32_t>((std::min)(chunk, end - at));
    assembler->Feed(c, *sink);
  }
  return feed;
}

void TestAssemblerCompleteStream() {
  io::VoiceAssembler assembler;
  FakeSink sink;
  const auto stream = OggStream(7u, 6, true);
  uint64_t feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, stream, 0u,
                             stream.size(), 1u, 1000u);
  // Complete, no message unit yet, inside the bind wait: kept.
  assembler.Settle(feed, 1500u, sink);
  assert(sink.written.empty());
  sink.bound_path = kVoiceA;
  sink.bound_event = 42u;
  assembler.Settle(feed, 1600u, sink);
  assert(sink.written.size() == 1u);
  assert(sink.written[0].storage == L"vir_v_vir0001.ogg");
  assert(sink.written[0].bytes == stream.size());
  assert(sink.written[0].text_event == 42u);
  // Published once.
  assembler.Settle(feed, 5000u, sink);
  assert(sink.written.size() == 1u);
  // A non-voice path never takes a member.
  const auto bgm = OggStream(8u, 6, true);
  feed = FeedStream(&assembler, &sink, 0x200u, L"data\\bgm\\01.ogg", bgm, 0u,
                    bgm.size(), feed, 6000u);
  assembler.Settle(feed, 9000u, sink);
  assert(sink.written.size() == 1u);
}

void TestAssemblerBosStopsOnlyItsDecoder() {
  io::VoiceAssembler assembler;
  FakeSink sink;
  const auto a = OggStream(7u, 6, true);
  const auto b = OggStream(9u, 6, true);
  // A receives five whole pages, then B starts on another decoder.
  uint64_t feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, a, 0u,
                             5u * kPageBytes, 1u, 1000u);
  feed = FeedStream(&assembler, &sink, 0x200u, kVoiceB, b, 0u, b.size(), feed,
                    1100u);
  assert(assembler.member(0).used && assembler.member(0).complete == 0u);
  // A's decoder keeps going to its EOS: still one whole stream.
  feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, a, 5u * kPageBytes,
                    a.size(), feed, 1200u);
  assembler.Settle(feed, 4000u, sink);  // bind wait over, unbound
  assert(sink.written.size() == 2u);
  for (const auto& w : sink.written) {
    assert(w.storage.find(L".partial") == std::wstring::npos);
    assert(w.bytes == a.size());
  }

  // Now a new BOS on the *same* decoder: the unfinished stream is stopped
  // (its whole-page prefix kept), the new one starts.
  io::VoiceAssembler second;
  FakeSink sink2;
  feed = FeedStream(&second, &sink2, 0x100u, kVoiceA, a, 0u, 5u * kPageBytes,
                    1u, 1000u);
  feed = FeedStream(&second, &sink2, 0x100u, kVoiceB, b, 0u, b.size(), feed,
                    1100u);
  second.Settle(feed, 4000u, sink2);
  assert(sink2.written.size() == 2u);
  bool partial_a = false, whole_b = false;
  for (const auto& w : sink2.written) {
    partial_a = partial_a || (w.storage == L"vir_v_vir0001.partial.ogg" &&
                              w.bytes == 5u * kPageBytes);
    whole_b = whole_b || (w.storage == L"kru_v_kru0001.ogg" &&
                          w.bytes == b.size());
  }
  assert(partial_a && whole_b);
  assert(second.damaged() == 0u);
}

void TestAssemblerCompleteMemberWaitsForBinding() {
  io::VoiceAssembler assembler;
  FakeSink sink;
  const auto a = OggStream(7u, 6, true);
  const auto b = OggStream(9u, 6, true);
  uint64_t feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, a, 0u,
                             a.size(), 1u, 1000u);
  // The decoder is reused for the next voice before A's unit is parsed.
  feed = FeedStream(&assembler, &sink, 0x100u, kVoiceB, b, 0u, 3u * kPageBytes,
                    feed, 1100u);
  assembler.Settle(feed, 1200u, sink);
  assert(sink.written.empty());  // A is complete and still waits
  sink.bound_path = kVoiceA;
  sink.bound_event = 77u;
  assembler.Settle(feed, 1300u, sink);
  assert(sink.written.size() == 1u);
  assert(sink.written[0].storage == L"vir_v_vir0001.ogg");
  assert(sink.written[0].bytes == a.size());
  assert(sink.written[0].text_event == 77u);
}

void TestAssemblerLostRefillMarksDamaged() {
  io::VoiceAssembler assembler;
  FakeSink sink;
  const auto a = OggStream(7u, 8, true);
  // Five whole pages, then a refill is lost (exactly on a page boundary:
  // the bytes after it would still parse as whole pages).
  uint64_t feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, a, 0u,
                             5u * kPageBytes, 1u, 1000u, kPageBytes);
  assembler.Drop(0x100u, feed++, 1100u, sink);
  feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, a, 6u * kPageBytes,
                    a.size(), feed, 1200u, kPageBytes);
  assert(assembler.dropped() == 1u && assembler.damaged() == 1u);
  assembler.Settle(feed, 4000u, sink);
  assert(sink.written.size() == 1u);
  assert(sink.written[0].storage == L"vir_v_vir0001.partial.ogg");
  assert(sink.written[0].bytes == 5u * kPageBytes);
  // A loss on another decoder does not touch this one.
  io::VoiceAssembler other;
  FakeSink sink2;
  feed = FeedStream(&other, &sink2, 0x100u, kVoiceA, a, 0u, 5u * kPageBytes,
                    1u, 1000u);
  other.Drop(0x900u, feed++, 1100u, sink2);
  assert(other.dropped() == 1u && other.damaged() == 0u);
  assert(other.member(0).used && other.member(0).complete == 0u);
  // Lost records whose decoder is unknown cut every receiving stream.
  other.DropAll(1200u, sink2);
  assert(other.damaged() == 1u && other.member(0).complete != 0u);
}

void TestAssemblerStallCountsFeedsNotTime() {
  io::VoiceAssembler assembler;
  FakeSink sink;
  const auto a = OggStream(7u, 8, true);
  const uint64_t feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, a, 0u,
                                   5u * kPageBytes, 1u, 1000u);
  const uint64_t last = feed - 1u;
  // Paused / unfocused game: no refills at all, however long — kept.
  assembler.Settle(feed, 1000u + 3600u * 1000u, sink);
  assert(sink.written.empty());
  assert(assembler.member(0).complete == 0u);
  // Other decoders refilled kStallFeeds times: still within the margin.
  assembler.Settle(last + io::kStallFeeds, 2000u, sink);
  assert(assembler.member(0).complete == 0u);
  // One more: stopped without a successor, whole-page prefix kept.
  assembler.Settle(last + io::kStallFeeds + 1u, 2000u, sink);
  assert(assembler.member(0).used && assembler.member(0).partial);
  assembler.Settle(last + io::kStallFeeds + 1u, 2000u + io::kBindWaitMs, sink);
  assert(sink.written.size() == 1u &&
         sink.written[0].storage == L"vir_v_vir0001.partial.ogg");
}

void TestAssemblerDuplicateDecode() {
  io::VoiceAssembler assembler;
  FakeSink sink;
  sink.bound_path = kVoiceA;
  sink.bound_event = 5u;
  const auto a = OggStream(7u, 6, true);
  uint64_t feed = FeedStream(&assembler, &sink, 0x100u, kVoiceA, a, 0u,
                             a.size(), 1u, 1000u);
  assembler.Settle(feed, 1000u, sink);
  feed = FeedStream(&assembler, &sink, 0x300u, kVoiceA, a, 0u, a.size(), feed,
                    1500u);
  assembler.Settle(feed, 1500u, sink);
  assert(sink.written.size() == 1u);  // second decode of the same file
  feed = FeedStream(&assembler, &sink, 0x300u, kVoiceA, a, 0u, a.size(), feed,
                    1000u + io::kRepeatWindowMs + 1u);
  assembler.Settle(feed, 9000u, sink);
  assert(sink.written.size() == 2u);  // played again later
}

// ── identity verdict ───────────────────────────────────────────────────────

void TestProfileState() {
  using io::ProfileState;
  using io::SchemeResult;
  assert(io::ClassifyScheme(SchemeResult::kResolved) == ProfileState::kMatched);
  assert(io::ClassifyScheme(SchemeResult::kNoName) ==
         ProfileState::kImageNotReady);
  assert(io::ClassifyScheme(SchemeResult::kNoNameCopy) ==
         ProfileState::kImageNotReady);
  assert(io::ClassifyScheme(SchemeResult::kNotX86) == ProfileState::kRejected);
  assert(io::ClassifyScheme(SchemeResult::kTellShape) ==
         ProfileState::kRejected);
  assert(io::ClassifyScheme(SchemeResult::kRegistrarNotShared) ==
         ProfileState::kRejected);
  assert(io::ShouldMeasureProfile(ProfileState::kUnmeasured, 0u, 0u));
  assert(!io::ShouldMeasureProfile(ProfileState::kImageNotReady, 5u, 5u));
  assert(io::ShouldMeasureProfile(ProfileState::kImageNotReady, 5u, 6u));
  assert(!io::ShouldMeasureProfile(ProfileState::kMatched, 5u, 6u));
  assert(!io::ShouldMeasureProfile(ProfileState::kRejected, 5u, 6u));

  std::vector<uint8_t> code(0x3000u, 0x90u), rdata(0x1000u, 0x11u),
      data(0x1000u, 0x22u);
  exact::LoadedPeImage image;
  image.base = code.data();
  image.section_count = 3u;
  image.sections[0] = {code.data(), code.size(), 0x1000u,
                       IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ |
                           IMAGE_SCN_MEM_WRITE};  // a packer's RWX section
  image.sections[1] = {rdata.data(), rdata.size(), 0x4000u, IMAGE_SCN_MEM_READ};
  image.sections[2] = {data.data(), data.size(), 0x5000u,
                       IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_WRITE};
  const uint64_t before = io::ImageFingerprint(image);
  data[0] = 0x23u;  // the game writing its data: not an unpack
  assert(io::ImageFingerprint(image) == before);
  code[0x2000u] = 0xc3u;  // unpacked code
  const uint64_t unpacked = io::ImageFingerprint(image);
  assert(unpacked != before);
  rdata[0x0005u] = 0x12u;  // unpacked constants
  assert(io::ImageFingerprint(image) != unpacked);
}

}  // namespace

int main() {
  TestAssemblerCompleteStream();
  TestAssemblerBosStopsOnlyItsDecoder();
  TestAssemblerCompleteMemberWaitsForBinding();
  TestAssemblerLostRefillMarksDamaged();
  TestAssemblerStallCountsFeedsNotTime();
  TestAssemblerDuplicateDecode();
  TestProfileState();
  TestPagePrefix();
  TestSchemeResolvesFromStructure();
  TestSchemeFailsClosed();
  TestFeedResolvesFromStructure();
  TestFeedFailsClosed();
  TestVoiceClassification();
  std::printf("malie_engine_io_test: ok\n");
  return 0;
}
