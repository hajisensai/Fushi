// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable focused test code.
#undef NDEBUG

#include <windows.h>

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "catsystem2_voice_core.h"

namespace voice = fushi_voice_hook::catsystem2_voice;
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
  void Slot(size_t operand_at, size_t slot_rva) {  // `[abs]` operand
    const uint32_t absolute = static_cast<uint32_t>(kAbsoluteBase + slot_rva);
    std::memcpy(base + operand_at, &absolute, 4u);
  }
  uintptr_t At(size_t rva) const {
    return reinterpret_cast<uintptr_t>(base + rva);
  }

  uint8_t* base = nullptr;
  exact::LoadedPeImage image;
};

constexpr size_t kBigRead = 0x1000u;
constexpr size_t kReadEntry = 0x2000u;
constexpr size_t kPlainAt = 0x74u;  // measured distance on the real build
constexpr size_t kSlotSetFilePointer = 0xf000u;
constexpr size_t kSlotReadFile = 0xf004u;

voice::VoiceImportSlots Imports() {
  voice::VoiceImportSlots imports;
  imports.set_file_pointer = kSlotSetFilePointer;
  imports.read_file = kSlotReadFile;
  return imports;
}

void PutPlainBlock(SyntheticImage* img, size_t at) {
  img->Put(at, voice::kPlainBlockBytes, sizeof(voice::kPlainBlockBytes));
  img->base[at + 26u] = 0x14u;  // mov [esp+0x14],ebp
  img->base[at + 28u] = 0x58u;  // jne +0x58
  img->Slot(at + voice::kPlainBlockSetFilePointer, kSlotSetFilePointer);
  img->base[at + 55u] = 0x1cu;  // lea edx,[esp+0x1c]
  img->Slot(at + voice::kPlainBlockReadFile, kSlotReadFile);
  img->base[at + 69u] = 0x1cu;  // jne +0x1c
}

void BuildEngine(SyntheticImage* img) {
  img->Put(kBigRead, voice::kBigReadBytes, sizeof(voice::kBigReadBytes));
  img->base[kBigRead + 8u] = 0x13u;
  img->base[kBigRead + 34u] = 0x13u;
  img->Rel32(kBigRead + 14u, 0x3000u);  // error log
  img->Rel32(kBigRead + 40u, 0x3000u);
  img->Rel32(kBigRead + voice::kBigReadCall, kReadEntry);
  img->Put(kReadEntry, voice::kReadEntryPrologueBytes,
           sizeof(voice::kReadEntryPrologueBytes));
  PutPlainBlock(img, kReadEntry + kPlainAt);
}

void TestResolvesFromStructure() {
  SyntheticImage img;
  BuildEngine(&img);
  voice::VoiceSites sites;
  assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
         voice::VoiceSiteResult::kResolved);
  assert(sites.big_read == img.At(kBigRead));
  assert(sites.read_entry == img.At(kReadEntry));
  assert(sites.plain_block == img.At(kReadEntry + kPlainAt));
}

void TestFailsClosed() {
  voice::VoiceSites sites;
  {  // x64 image
    SyntheticImage img(IMAGE_FILE_MACHINE_AMD64, 64u);
    BuildEngine(&img);
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kNotX86);
    assert(sites.read_entry == 0u);
  }
  {  // no ReadFile import
    SyntheticImage img;
    BuildEngine(&img);
    voice::VoiceImportSlots imports = Imports();
    imports.read_file = 0u;
    assert(voice::ResolveVoiceSites(img.image, imports, &sites) ==
           voice::VoiceSiteResult::kImportsMissing);
  }
  {  // no forwarder (another engine's image)
    SyntheticImage img;
    BuildEngine(&img);
    img.base[kBigRead + 3u] = 0x49u;  // mov ecx,[ecx+4]: not [eax+4]
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kBigReadMissing);
    assert(sites.read_entry == 0u);
  }
  {  // two forwarders: ambiguous
    SyntheticImage img;
    BuildEngine(&img);
    img.Put(0x5000u, voice::kBigReadBytes, sizeof(voice::kBigReadBytes));
    img.Rel32(0x5000u + voice::kBigReadCall, kReadEntry);
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kBigReadMissing);
  }
  {  // the forwarder calls something without the ReadEntry prologue
    SyntheticImage img;
    BuildEngine(&img);
    img.base[kReadEntry + 26u] = 0x8bu;  // mov edi,ecx -> mov edi,ebx
    img.base[kReadEntry + 27u] = 0xfbu;
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kReadEntryInvalid);
  }
  {  // argument roles differ (buffer taken from another stack slot)
    SyntheticImage img;
    BuildEngine(&img);
    img.base[kReadEntry + 18u] = 0x30u;
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kReadEntryInvalid);
  }
  {  // plain block missing
    SyntheticImage img;
    BuildEngine(&img);
    img.base[kReadEntry + kPlainAt + 18u] = 0x20u;  // cmp [edi+0x120]
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kPlainBlockMissing);
  }
  {  // entry field layout differs (name not at +0x14)
    SyntheticImage img;
    BuildEngine(&img);
    img.base[kReadEntry + kPlainAt + 76u] = 0x18u;
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kPlainBlockMissing);
  }
  {  // plain block outside the scanned head of ReadEntry
    SyntheticImage img;
    BuildEngine(&img);
    std::memset(img.base + kReadEntry + kPlainAt, 0xcc,
                sizeof(voice::kPlainBlockBytes));
    PutPlainBlock(&img, kReadEntry + 0x200u);
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kPlainBlockMissing);
  }
  {  // two plain blocks in the head: ambiguous
    SyntheticImage img;
    BuildEngine(&img);
    PutPlainBlock(&img, kReadEntry + kPlainAt + 0x60u);
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kPlainBlockMissing);
  }
  {  // the block calls other imports than SetFilePointer / ReadFile
    SyntheticImage img;
    BuildEngine(&img);
    img.Slot(kReadEntry + kPlainAt + voice::kPlainBlockReadFile, 0xf008u);
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kPlainBlockImportsInvalid);
    assert(sites.read_entry == 0u);
  }
}

void TestEntryPlausibility() {
  assert(voice::PlausibleEntry(1000u, 0u, 500u));
  assert(voice::PlausibleEntry(1500u, 500u, 500u));  // at the end
  assert(!voice::PlausibleEntry(1000u, 0u, 0u));      // empty member
  assert(!voice::PlausibleEntry(1000u, 600u, 500u));  // offset past size
  assert(!voice::PlausibleEntry(100u, 200u, 500u));   // position < offset
  assert(!voice::PlausibleEntry(0u, 0u, voice::kMaxMemberBytes + 1u));
  assert(voice::PlausibleRead(0u, 500u, 500));
  assert(voice::PlausibleRead(100u, 500u, 400));
  assert(!voice::PlausibleRead(100u, 500u, 401));
  assert(!voice::PlausibleRead(0u, 500u, 0));
  assert(!voice::PlausibleRead(0u, 500u, -1));
}

void TestRangeSet() {
  voice::RangeSet set;
  assert(set.Prefix() == 0u);
  assert(!set.Add(10u, 10u));
  assert(set.Add(8500u, 17000u));  // tail-first order (ov_open)
  assert(set.Prefix() == 0u);
  assert(set.Add(0u, 8500u));  // touching ranges merge
  assert(set.count == 1u && set.Prefix() == 17000u);
  assert(set.Add(30000u, 31000u));
  assert(set.Add(20000u, 21000u));
  assert(set.count == 3u);
  assert(set.Add(16000u, 30500u));  // swallows two ranges
  assert(set.count == 1u && set.Prefix() == 31000u);
  assert(set.Add(0u, 100u));  // duplicate read changes nothing
  assert(set.count == 1u && set.Prefix() == 31000u);

  voice::RangeSet full;
  for (uint32_t i = 0u; i < voice::kMaxRanges; ++i) {
    assert(full.Add(i * 10u + 1u, i * 10u + 5u));
  }
  assert(!full.Add(1000u, 1001u));        // a new disjoint range: no room
  assert(full.count == voice::kMaxRanges);
  assert(full.Add(3u, 12u));              // merging still works
  assert(full.count == voice::kMaxRanges - 1u);
}

// ── Ogg ─────────────────────────────────────────────────────────────────────

void TestCrcKnownAnswer() {
  // CRC-32, polynomial 0x04c11db7, init 0, no reflection, no final xor.
  uint32_t crc = 0u;
  for (const char* p = "123456789"; *p != 0; ++p) {
    crc = voice::OggCrcUpdate(crc, static_cast<uint8_t>(*p));
  }
  assert(crc == 0x89a1897fu);
}

void AppendPage(std::vector<uint8_t>* out, uint8_t flags, uint64_t granule,
                uint32_t serial, uint32_t sequence,
                const std::vector<uint8_t>& payload) {
  assert(payload.size() < 255u * 255u);
  std::vector<uint8_t> page = {'O', 'g', 'g', 'S', 0u, flags};
  for (int i = 0; i < 8; ++i) {
    page.push_back(static_cast<uint8_t>(granule >> (8 * i)));
  }
  for (int i = 0; i < 4; ++i) {
    page.push_back(static_cast<uint8_t>(serial >> (8 * i)));
  }
  for (int i = 0; i < 4; ++i) {
    page.push_back(static_cast<uint8_t>(sequence >> (8 * i)));
  }
  page.insert(page.end(), 4u, 0u);  // checksum
  std::vector<uint8_t> lacing;
  size_t left = payload.size();
  do {
    const uint8_t piece = static_cast<uint8_t>(left >= 255u ? 255u : left);
    lacing.push_back(piece);
    left -= piece;
  } while (left > 0u || lacing.back() == 255u);
  page.push_back(static_cast<uint8_t>(lacing.size()));
  page.insert(page.end(), lacing.begin(), lacing.end());
  page.insert(page.end(), payload.begin(), payload.end());
  const uint32_t crc =
      voice::OggPageCrc(page.data(), static_cast<uint32_t>(page.size()));
  for (int i = 0; i < 4; ++i) page[22u + i] = static_cast<uint8_t>(crc >> (8 * i));
  out->insert(out->end(), page.begin(), page.end());
}

std::vector<uint8_t> Payload(const char* head, size_t size, uint8_t fill) {
  std::vector<uint8_t> payload(size, fill);
  std::memcpy(payload.data(), head, std::strlen(head));
  return payload;
}

// Identification, comment + setup, then `audio_pages` audio pages (EOS last).
std::vector<uint8_t> VorbisStream(uint32_t audio_pages,
                                  std::vector<uint32_t>* page_ends = nullptr) {
  std::vector<uint8_t> ogg;
  constexpr uint32_t kSerial = 0x1234u;
  AppendPage(&ogg, 0x02u, 0u, kSerial, 0u, Payload("\x01vorbis", 30u, 0x11u));
  if (page_ends) page_ends->push_back(static_cast<uint32_t>(ogg.size()));
  AppendPage(&ogg, 0x00u, 0u, kSerial, 1u, Payload("\x03vorbis", 400u, 0x22u));
  if (page_ends) page_ends->push_back(static_cast<uint32_t>(ogg.size()));
  for (uint32_t i = 0u; i < audio_pages; ++i) {
    const uint8_t flags = i + 1u == audio_pages ? 0x04u : 0x00u;
    AppendPage(&ogg, flags, 4096u * (i + 1u), kSerial, 2u + i,
               Payload("", 700u + i, static_cast<uint8_t>(0x30u + i)));
    if (page_ends) page_ends->push_back(static_cast<uint32_t>(ogg.size()));
  }
  return ogg;
}

void TestScanOggPages() {
  std::vector<uint32_t> ends;
  const std::vector<uint8_t> ogg = VorbisStream(4u, &ends);
  const uint32_t size = static_cast<uint32_t>(ogg.size());
  voice::OggScan scan = voice::ScanOggPages(ogg.data(), size);
  assert(scan.vorbis && scan.eos && scan.pages == 6u);
  assert(scan.valid_bytes == size && scan.last_granule == 4096u * 4u);

  // Truncated mid-page: stops at the last complete page.
  scan = voice::ScanOggPages(ogg.data(), ends[3] + 100u);
  assert(scan.valid_bytes == ends[3] && scan.pages == 4u && !scan.eos);
  assert(scan.last_granule == 4096u * 2u);

  // A flipped payload byte fails that page's CRC.
  std::vector<uint8_t> corrupt = ogg;
  corrupt[ends[3] + 60u] ^= 0x01u;
  scan = voice::ScanOggPages(corrupt.data(), size);
  assert(scan.valid_bytes == ends[3] && !scan.eos);

  // Another logical stream in the middle ends the scan.
  std::vector<uint8_t> chained;
  AppendPage(&chained, 0x02u, 0u, 1u, 0u, Payload("\x01vorbis", 30u, 1u));
  const uint32_t first = static_cast<uint32_t>(chained.size());
  AppendPage(&chained, 0x00u, 4096u, 2u, 1u, Payload("", 100u, 2u));
  scan = voice::ScanOggPages(chained.data(),
                             static_cast<uint32_t>(chained.size()));
  assert(scan.valid_bytes == first && scan.pages == 1u);

  // Not Vorbis (Opus head) and not Ogg at all.
  std::vector<uint8_t> opus;
  AppendPage(&opus, 0x02u, 0u, 7u, 0u, Payload("OpusHead", 19u, 0u));
  assert(!voice::ScanOggPages(opus.data(),
                              static_cast<uint32_t>(opus.size())).vorbis);
  const uint8_t riff[32] = {'R', 'I', 'F', 'F'};
  scan = voice::ScanOggPages(riff, sizeof(riff));
  assert(scan.pages == 0u && scan.valid_bytes == 0u && !scan.vorbis);
}

void TestDecideMember() {
  std::vector<uint32_t> ends;
  std::vector<uint8_t> ogg = VorbisStream(5u, &ends);
  const uint32_t size = static_cast<uint32_t>(ogg.size());

  voice::RangeSet all;
  assert(all.Add(0u, size));
  voice::MemberDecision d = voice::DecideMember(ogg.data(), size, all, false);
  assert(d.verdict == voice::MemberVerdict::kPublishComplete && d.bytes == size);

  // Head and tail read, middle still streaming: wait, whatever the bytes say.
  voice::RangeSet head_tail;
  assert(head_tail.Add(0u, ends[2]));
  assert(head_tail.Add(ends[5], size));
  d = voice::DecideMember(ogg.data(), size, head_tail, false);
  assert(d.verdict == voice::MemberVerdict::kWait);

  // The next line stopped it: publish the verified page prefix it decoded.
  voice::RangeSet cut;
  assert(cut.Add(0u, ends[4] + 50u));
  assert(cut.Add(ends[5], size));
  d = voice::DecideMember(ogg.data(), size, cut, true);
  assert(d.verdict == voice::MemberVerdict::kPublishPartial);
  assert(d.bytes == ends[4]);

  // Stopped before any audio page: nothing to publish.
  voice::RangeSet headers;
  assert(headers.Add(0u, ends[1] + 10u));
  d = voice::DecideMember(ogg.data(), size, headers, true);
  assert(d.verdict == voice::MemberVerdict::kReject);

  // Every byte read but a page fails its CRC (not the engine's plaintext).
  std::vector<uint8_t> corrupt = ogg;
  corrupt[ends[3] + 40u] ^= 0x80u;
  d = voice::DecideMember(corrupt.data(), size, all, false);
  assert(d.verdict == voice::MemberVerdict::kReject);

  // Undecrypted / foreign bytes are never published, complete or not.
  std::vector<uint8_t> noise(size, 0x5au);
  d = voice::DecideMember(noise.data(), size, all, false);
  assert(d.verdict == voice::MemberVerdict::kReject);
  d = voice::DecideMember(noise.data(), size, cut, true);
  assert(d.verdict == voice::MemberVerdict::kReject);

  // Trailing bytes after the EOS page are not part of the stream.
  std::vector<uint8_t> padded = ogg;
  padded.insert(padded.end(), 5u, 0u);
  voice::RangeSet padded_all;
  assert(padded_all.Add(0u, static_cast<uint32_t>(padded.size())));
  d = voice::DecideMember(padded.data(), static_cast<uint32_t>(padded.size()),
                          padded_all, false);
  assert(d.verdict == voice::MemberVerdict::kPublishComplete && d.bytes == size);

  assert(voice::DecideMember(nullptr, size, all, true).verdict ==
         voice::MemberVerdict::kReject);
}

void TestSelectedLineOrder() {
  // The script-command hook publishes before the page (and its voice) starts;
  // every render-time hook publishes after.  Luna identity only, exact match.
  assert(voice::SelectedLineOrder("EmbedCS2") ==
         voice::LineOrder::kPrecedesVoice);
  assert(voice::SelectedLineOrder("CatSystem2") ==
         voice::LineOrder::kFollowsVoice);
  assert(voice::SelectedLineOrder("GetGlyphOutlineA") ==
         voice::LineOrder::kFollowsVoice);
  assert(voice::SelectedLineOrder("embedcs2") ==
         voice::LineOrder::kFollowsVoice);
  assert(voice::SelectedLineOrder("") == voice::LineOrder::kFollowsVoice);
  assert(voice::SelectedLineOrder(nullptr) == voice::LineOrder::kFollowsVoice);
  assert(voice::kTextBindingWindowMs == 1500u);
}

void TestStorageName() {
  assert(voice::BuildVoiceStorageName(L"pcm_e.int", L"SAC_griani_003_001.ogg",
                                      false) ==
         L"pcm_e.int_SAC_griani_003_001.ogg");
  assert(voice::BuildVoiceStorageName(L"pcm_e.int", L"SAC_003.ogg", true) ==
         L"pcm_e.int_SAC_003.partial.ogg");
  assert(voice::BuildVoiceStorageName(L"pcm_a.int", L"v001", false) ==
         L"pcm_a.int_v001.ogg");
  assert(voice::BuildVoiceStorageName(L"pcm_a.int", L"v001", true) ==
         L"pcm_a.int_v001.partial.ogg");
  // Separators never survive: the writer would cut the name at them.
  assert(voice::BuildVoiceStorageName(L"pcm_a.int", L"sub/dir\\v>1.ogg",
                                      false) == L"pcm_a.int_sub_dir_v_1.ogg");
  assert(voice::BuildVoiceStorageName(nullptr, nullptr, false) ==
         L"pcm_voice.ogg");
  assert(voice::BuildVoiceStorageName(L"", L".ogg", false) ==
         L"pcm_.ogg.ogg");
}

}  // namespace

int main() {
  TestResolvesFromStructure();
  TestFailsClosed();
  TestEntryPlausibility();
  TestRangeSet();
  TestCrcKnownAnswer();
  TestScanOggPages();
  TestDecideMember();
  TestSelectedLineOrder();
  TestStorageName();
  std::puts("catsystem2_voice_test: all passed");
  return 0;
}
