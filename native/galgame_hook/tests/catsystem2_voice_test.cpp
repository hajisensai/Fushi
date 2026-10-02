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
constexpr size_t kSlotSetFilePointer = 0xf000u;
constexpr size_t kSlotReadFile = 0xf004u;

voice::VoiceImportSlots Imports() {
  voice::VoiceImportSlots imports;
  imports.set_file_pointer = kSlotSetFilePointer;
  imports.read_file = kSlotReadFile;
  return imports;
}

// ── the two measured codegens ───────────────────────────────────────────────
//
// Instruction bytes of kcBigFile::Read and of ReadEntry's plain path as each
// build compiles them; rel32 targets, IAT operands and log-string pointers are
// zero here and filled in by BuildEngine.  Offsets of the parts the proof
// reads are listed next to each array.

// cs2 2.6.x (グリザイアの有閑).
constexpr uint8_t kGrisaiaForwarder[] = {
    0x8b, 0xc1,                    // mov eax,ecx
    0x8b, 0x48, 0x04,              // mov ecx,[eax+4]   archive
    0x85, 0xc9, 0x75, 0x13,        // test ecx,ecx; jne
    0x68, 0x00, 0x00, 0x00, 0x00,  // push <log>
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call log
    0x83, 0xc4, 0x04, 0x83, 0xc8, 0xff, 0xc2, 0x08, 0x00,  // error exit
    0x8b, 0x40, 0x08,              // mov eax,[eax+8]   entry
    0x85, 0xc0, 0x75, 0x13,        // test eax,eax; jne
    0x68, 0x00, 0x00, 0x00, 0x00,  // push <log>
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call log
    0x83, 0xc4, 0x04, 0x83, 0xc8, 0xff, 0xc2, 0x08, 0x00,  // error exit
    0x8b, 0x54, 0x24, 0x08, 0x52,  // mov edx,[esp+8]; push edx  (len)
    0x8b, 0x54, 0x24, 0x08, 0x52,  // mov edx,[esp+8]; push edx  (buf)
    0x50,                          // push eax  (entry)
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call ReadEntry
    0xc2, 0x08, 0x00};             // ret 8
constexpr uint8_t kGrisaiaPlainBlock[] = {
    0x8b, 0x4e, 0x10,                          // mov ecx,[esi+0x10]  size
    0x8b, 0x46, 0x0c,                          // mov eax,[esi+0xc]   offset
    0x8b, 0xd1, 0x2b, 0xd0, 0x3b, 0xea, 0x76, 0x02, 0x8b, 0xea,  // clamp
    0x83, 0xbf, 0x1c, 0x01, 0x00, 0x00, 0x00,  // cmp [edi+0x11c],0
    0x89, 0x6c, 0x24, 0x14, 0x75, 0x58,
    0x8b, 0x46, 0x08, 0x8b, 0x4f, 0x10, 0x6a, 0x00, 0x6a, 0x00, 0x50, 0x51,
    0xff, 0x15, 0x00, 0x00, 0x00, 0x00,        // call [SetFilePointer]
    0x8b, 0x47, 0x10, 0x6a, 0x00, 0x8d, 0x54, 0x24, 0x1c, 0x52, 0x55, 0x53,
    0x50,
    0xff, 0x15, 0x00, 0x00, 0x00, 0x00,        // call [ReadFile]
    0x85, 0xc0, 0x75, 0x1c, 0x8b, 0x4e, 0x10, 0x51,
    0x8d, 0x56, 0x14,                          // lea edx,[esi+0x14]  name
    0x52, 0x68};

// 2016-10 MSVC 12 build (初恋サンカイメ).
constexpr uint8_t kSankaimeForwarder[] = {
    0x8b, 0x51, 0x04,              // mov edx,[ecx+4]   archive
    0x85, 0xd2, 0x75, 0x13,        // test edx,edx; jne
    0x68, 0x00, 0x00, 0x00, 0x00,  // push <log>
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call log
    0x83, 0xc4, 0x04, 0x83, 0xc8, 0xff, 0xc2, 0x08, 0x00,  // error exit
    0x8b, 0x41, 0x08,              // mov eax,[ecx+8]   entry
    0x85, 0xc0, 0x75, 0x13,        // test eax,eax; jne
    0x68, 0x00, 0x00, 0x00, 0x00,  // push <log>
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call log
    0x83, 0xc4, 0x04, 0x83, 0xc8, 0xff, 0xc2, 0x08, 0x00,  // error exit
    0xff, 0x74, 0x24, 0x08,        // push [esp+8]  (len)
    0x8b, 0xca,                    // mov ecx,edx
    0xff, 0x74, 0x24, 0x08,        // push [esp+8]  (buf)
    0x50,                          // push eax  (entry)
    0xe8, 0x00, 0x00, 0x00, 0x00,  // call ReadEntry
    0xc2, 0x08, 0x00};             // ret 8
constexpr uint8_t kSankaimePlainBlock[] = {
    0x8b, 0x56, 0x10,                          // mov edx,[esi+0x10]  size
    0x8b, 0xc2,
    0x8b, 0x4e, 0x0c,                          // mov ecx,[esi+0xc]   offset
    0x2b, 0xc1, 0x3b, 0xd8, 0x0f, 0x47, 0xd8,  // clamp (cmova)
    0x83, 0xbd, 0x1c, 0x01, 0x00, 0x00, 0x00,  // cmp [ebp+0x11c],0
    0x89, 0x5c, 0x24, 0x3c, 0x75, 0x50,
    0x6a, 0x00, 0x6a, 0x00, 0xff, 0x76, 0x08, 0xff, 0x75, 0x10,
    0xff, 0x15, 0x00, 0x00, 0x00, 0x00,        // call [SetFilePointer]
    0x6a, 0x00, 0x8d, 0x44, 0x24, 0x1c, 0x50, 0x53, 0x57, 0xff, 0x75, 0x10,
    0xff, 0x15, 0x00, 0x00, 0x00, 0x00,        // call [ReadFile]
    0x85, 0xc0, 0x75, 0x1b, 0xff, 0x76, 0x10,
    0x8d, 0x46, 0x14,                          // lea eax,[esi+0x14]  name
    0x50, 0x68};

struct Codegen {
  const char* name;
  const uint8_t* forwarder;
  size_t forwarder_bytes;
  size_t log_calls[2];      // `e8` of the two error logs
  size_t read_entry_call;   // `e8` of ReadEntry
  const uint8_t* block;
  size_t block_bytes;
  size_t block_at;          // block start inside ReadEntry
  size_t archive_disp;      // disp8 of the archive load
  size_t clamp_size_disp;   // disp8 of the size load
  size_t cmp;               // flag compare inside the block
  size_t set_file_pointer;  // `ff 15` inside the block
  size_t read_file;
  size_t name_disp;         // disp8 of the name lea
  size_t name_modrm;
};

constexpr Codegen kGrisaia = {
    "grisaia", kGrisaiaForwarder, sizeof(kGrisaiaForwarder), {14u, 40u}, 65u,
    kGrisaiaPlainBlock, sizeof(kGrisaiaPlainBlock), 0x74u, 4u, 2u, 16u, 41u,
    60u, 76u, 75u};
constexpr Codegen kSankaime = {
    "sankaime", kSankaimeForwarder, sizeof(kSankaimeForwarder), {12u, 38u},
    63u, kSankaimePlainBlock, sizeof(kSankaimePlainBlock), 0x75u, 2u, 2u, 15u,
    38u, 56u, 71u, 70u};
constexpr const Codegen* kCodegens[] = {&kGrisaia, &kSankaime};

void PutForwarder(SyntheticImage* img, const Codegen& cg, size_t at,
                  size_t target) {
  img->Put(at, cg.forwarder, cg.forwarder_bytes);
  img->Rel32(at + cg.log_calls[0], 0x3000u);
  img->Rel32(at + cg.log_calls[1], 0x3000u);
  img->Rel32(at + cg.read_entry_call, target);
}

void PutPlainBlock(SyntheticImage* img, const Codegen& cg, size_t at) {
  img->Put(at, cg.block, cg.block_bytes);
  img->Slot(at + cg.set_file_pointer + 2u, kSlotSetFilePointer);
  img->Slot(at + cg.read_file + 2u, kSlotReadFile);
}

void BuildEngine(SyntheticImage* img, const Codegen& cg) {
  PutForwarder(img, cg, kBigRead, kReadEntry);
  PutPlainBlock(img, cg, kReadEntry + cg.block_at);
}

size_t BlockByte(const Codegen& cg, size_t offset) {
  return kReadEntry + cg.block_at + offset;
}

void TestResolvesBothCodegens() {
  for (const Codegen* cg : kCodegens) {
    SyntheticImage img;
    BuildEngine(&img, *cg);
    voice::VoiceSites sites;
    assert(voice::ResolveVoiceSites(img.image, Imports(), &sites) ==
           voice::VoiceSiteResult::kResolved);
    assert(sites.big_read == img.At(kBigRead + cg->read_entry_call));
    assert(sites.read_entry == img.At(kReadEntry));
    assert(sites.plain_block == img.At(BlockByte(*cg, cg->cmp)));
  }
}

voice::VoiceSiteResult Resolve(const SyntheticImage& img,
                               voice::VoiceSites* sites) {
  const auto result = voice::ResolveVoiceSites(img.image, Imports(), sites);
  if (result != voice::VoiceSiteResult::kResolved) assert(sites->read_entry == 0u);
  return result;
}

void TestFailsClosed(const Codegen& cg) {
  using R = voice::VoiceSiteResult;
  voice::VoiceSites sites;
  {  // x64 image
    SyntheticImage img(IMAGE_FILE_MACHINE_AMD64, 64u);
    BuildEngine(&img, cg);
    assert(Resolve(img, &sites) == R::kNotX86);
  }
  {  // no ReadFile import
    SyntheticImage img;
    BuildEngine(&img, cg);
    voice::VoiceImportSlots imports = Imports();
    imports.read_file = 0u;
    assert(voice::ResolveVoiceSites(img.image, imports, &sites) ==
           R::kImportsMissing);
  }
  {  // the first null check does not load a field at +4
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.base[kBigRead + cg.archive_disp] = 0x05u;
    assert(Resolve(img, &sites) == R::kBigReadMissing);
  }
  {  // the entry is not what ReadEntry gets first (no `push eax`)
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.base[kBigRead + cg.read_entry_call - 1u] = 0x51u;
    assert(Resolve(img, &sites) == R::kBigReadMissing);
  }
  {  // not a tail call returning to Read's caller (`ret 0xc`)
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.base[kBigRead + cg.read_entry_call + 6u] = 0x0cu;
    assert(Resolve(img, &sites) == R::kBigReadMissing);
  }
  {  // the null checks are too far apart to be one function
    SyntheticImage img;
    BuildEngine(&img, cg);
    const size_t second = cg.log_calls[1] + 5u;
    std::memset(img.base + kBigRead + second, 0xcc, sizeof(voice::kErrorExitBytes));
    img.Put(kBigRead + cg.read_entry_call + 8u + 0x20u, voice::kErrorExitBytes,
            sizeof(voice::kErrorExitBytes));
    assert(Resolve(img, &sites) == R::kBigReadMissing);
  }
  {  // two forwarders: ambiguous
    SyntheticImage img;
    BuildEngine(&img, cg);
    PutForwarder(&img, cg, 0x5000u, kReadEntry);
    assert(Resolve(img, &sites) == R::kBigReadMissing);
  }
  {  // an unreadable executable section could hide a second forwarder
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.image.section_count = 2u;
    img.image.sections[1] = {nullptr, 0x1000u, 0x10000u,
                             IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE};
    assert(Resolve(img, &sites) == R::kBigReadMissing);
  }
  {  // the forwarder calls outside the image
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.Rel32(kBigRead + cg.read_entry_call, SyntheticImage::kSize + 0x1000u);
    assert(Resolve(img, &sites) == R::kReadEntryInvalid);
  }
  {  // ReadEntry's window runs past the end of the code
    SyntheticImage img;
    PutForwarder(&img, cg, kBigRead, SyntheticImage::kSize - 0x100u);
    assert(Resolve(img, &sites) == R::kReadEntryInvalid);
  }
  {  // the flag is not the archive's encrypted flag (+0x120)
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.base[BlockByte(cg, cg.cmp + 2u)] = 0x20u;
    assert(Resolve(img, &sites) == R::kPlainBlockMissing);
  }
  {  // no clamp by the entry's size before the flag test
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.base[BlockByte(cg, cg.clamp_size_disp)] = 0x18u;
    assert(Resolve(img, &sites) == R::kPlainBlockMissing);
  }
  {  // the block lies past the scanned head of ReadEntry
    SyntheticImage img;
    BuildEngine(&img, cg);
    std::memset(img.base + BlockByte(cg, 0u), 0xcc, cg.block_bytes);
    PutPlainBlock(&img, cg, kReadEntry + voice::kReadEntryScanBytes);
    assert(Resolve(img, &sites) == R::kPlainBlockMissing);
  }
  {  // two blocks in the head: ambiguous
    SyntheticImage img;
    BuildEngine(&img, cg);
    PutPlainBlock(&img, cg, kReadEntry + cg.block_at + 0x80u);
    assert(Resolve(img, &sites) == R::kPlainBlockMissing);
  }
  {  // ReadFile goes through another import
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.Slot(BlockByte(cg, cg.read_file + 2u), 0xf008u);
    assert(Resolve(img, &sites) == R::kPlainBlockCallsInvalid);
  }
  {  // SetFilePointer goes through another import
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.Slot(BlockByte(cg, cg.set_file_pointer + 2u), 0xf008u);
    assert(Resolve(img, &sites) == R::kPlainBlockCallsInvalid);
  }
  {  // the logged name is not at +0x14
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.base[BlockByte(cg, cg.name_disp)] = 0x18u;
    assert(Resolve(img, &sites) == R::kPlainBlockCallsInvalid);
  }
  {  // the name comes from another register than the clamped entry
    SyntheticImage img;
    BuildEngine(&img, cg);
    img.base[BlockByte(cg, cg.name_modrm)] =
        static_cast<uint8_t>((img.base[BlockByte(cg, cg.name_modrm)] & 0xf8u) |
                             0x03u);  // [ebx+0x14]
    assert(Resolve(img, &sites) == R::kPlainBlockCallsInvalid);
  }
}

void TestFailsClosed() {
  for (const Codegen* cg : kCodegens) TestFailsClosed(*cg);
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

// The measured 2016 sequence (BUG-2896), replayed through the same
// generation bookkeeping the adapter does: publish bumps, reject records.
void TestSettledMemberKey() {
  uint64_t generation = 0;
  // E_00_01_004 read whole at the line start and published.
  const uint64_t e004 = ++generation;
  // Its companion member in the same archive fails verification.
  const uint64_t companion = generation;
  assert(!voice::SettledMemberKeyEnded(companion, generation));
  // 5.06 s later, no click: E_00_01_004 is read again.  Same playback.
  assert(!voice::SettledMemberKeyEnded(e004, generation));
  // Still the same playback however long the line stays on screen.
  assert(!voice::SettledMemberKeyEnded(e004, generation));
  // The next message's voice is published: both keys end.
  const uint64_t e005 = ++generation;
  assert(voice::SettledMemberKeyEnded(e004, generation));
  assert(voice::SettledMemberKeyEnded(companion, generation));
  assert(!voice::SettledMemberKeyEnded(e005, generation));
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
  TestResolvesBothCodegens();
  TestFailsClosed();
  TestEntryPlausibility();
  TestRangeSet();
  TestCrcKnownAnswer();
  TestScanOggPages();
  TestDecideMember();
  TestSelectedLineOrder();
  TestSettledMemberKey();
  TestStorageName();
  std::puts("catsystem2_voice_test: all passed");
  return 0;
}
