// Release builds define NDEBUG. Undefine it before every include so these
// assertions remain executable test code (guarded by assert_liveness_guard).
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "../hook/hunex_hfa.h"

namespace hunex = fushi_voice_hook::hunex;

namespace {

void WriteLe32(uint8_t* out, uint32_t value) {
  out[0] = static_cast<uint8_t>(value);
  out[1] = static_cast<uint8_t>(value >> 8u);
  out[2] = static_cast<uint8_t>(value >> 16u);
  out[3] = static_cast<uint8_t>(value >> 24u);
}

void WriteLe64(uint8_t* out, uint64_t value) {
  for (uint32_t index = 0u; index < 8u; ++index) {
    out[index] = static_cast<uint8_t>(value >> (index * 8u));
  }
}

std::vector<uint8_t> MakeOggPage(uint8_t flags, uint64_t granule,
                                 uint32_t serial, uint32_t sequence,
                                 const std::vector<uint8_t>& payload) {
  assert(payload.size() <= 255u);
  std::vector<uint8_t> page(28u + payload.size(), 0u);
  std::memcpy(page.data(), "OggS", 4u);
  page[4u] = 0u;
  page[5u] = flags;
  WriteLe64(page.data() + 6u, granule);
  WriteLe32(page.data() + 14u, serial);
  WriteLe32(page.data() + 18u, sequence);
  page[26u] = 1u;
  page[27u] = static_cast<uint8_t>(payload.size());
  std::memcpy(page.data() + 28u, payload.data(), payload.size());
  return page;
}

std::vector<uint8_t> MakeOgg(uint32_t sample_count) {
  return MakeOggPage(0x06u, sample_count, 0x31415926u, 0u,
                     {1u, 0x76u, 0x6fu, 0x72u, 0x62u, 0x69u, 0x73u});
}

std::vector<uint8_t> MakeTwoPageOgg(uint32_t sample_count) {
  std::vector<uint8_t> ogg =
      MakeOggPage(0x02u, std::numeric_limits<uint64_t>::max(), 7u, 0u,
                  {1u, 2u, 3u});
  std::vector<uint8_t> eos =
      MakeOggPage(0x04u, sample_count, 7u, 1u, {4u, 5u});
  ogg.insert(ogg.end(), eos.begin(), eos.end());
  return ogg;
}

std::vector<uint8_t> MakeHw(uint32_t sample_count, uint32_t sample_rate,
                            uint32_t channels,
                            std::vector<uint8_t> ogg = {}) {
  if (ogg.empty()) {
    ogg = MakeOgg(sample_count);
  }
  std::vector<uint8_t> member(hunex::kHunexHwHeaderBytes + ogg.size(), 0u);
  WriteLe32(member.data(), hunex::kHunexHwHeaderBytes);
  std::memcpy(member.data() + 4u, "hw  ", 4u);
  WriteLe32(member.data() + 8u, static_cast<uint32_t>(ogg.size()));
  WriteLe32(member.data() + 12u, sample_count);
  WriteLe32(member.data() + 16u, sample_rate);
  WriteLe32(member.data() + 20u, channels);
  // 0x18..0x3f is opaque in measured files; non-zero bytes must stay valid.
  for (size_t at = 0x18u; at < hunex::kHunexHwHeaderBytes; ++at) {
    member[at] = static_cast<uint8_t>(0x80u + (at & 0x1fu));
  }
  std::memcpy(member.data() + hunex::kHunexHwHeaderBytes, ogg.data(),
              ogg.size());
  return member;
}

struct SyntheticHfa {
  size_t index_bytes = 0u;
  std::vector<uint8_t> bytes;
};

void WriteHfaEntry(std::vector<uint8_t>* archive, uint32_t id,
                   const std::string& name, uint32_t relative_offset,
                   uint32_t size) {
  assert(name.size() < hunex::kHunexHfaNameBytes);
  uint8_t* record = archive->data() + hunex::kHunexHfaHeaderBytes +
                    static_cast<size_t>(id) * hunex::kHunexHfaRecordBytes;
  std::memcpy(record, name.data(), name.size());
  record[name.size()] = 0u;
  WriteLe32(record + hunex::kHunexHfaNameBytes, relative_offset);
  WriteLe32(record + hunex::kHunexHfaNameBytes + 4u, size);
  // The final 24 record bytes are opaque and are not zero-padding evidence.
  for (size_t at = 0x68u; at < hunex::kHunexHfaRecordBytes; ++at) {
    record[at] = static_cast<uint8_t>(0x40u + at);
  }
}

SyntheticHfa MakeHfa() {
  const std::vector<uint8_t> mono = MakeHw(48000u, 48000u, 1u);
  const std::vector<uint8_t> stereo = MakeHw(96000u, 48000u, 2u);
  const std::vector<uint8_t> not_audio = {0x40u, 0u, 0u, 0u, 1u, 2u, 3u,
                                          4u, 5u, 6u, 7u, 8u};
  constexpr uint32_t count = 3u;
  const size_t index_bytes = hunex::kHunexHfaHeaderBytes +
                             count * hunex::kHunexHfaRecordBytes;
  const uint32_t mono_offset = 168u;
  const uint32_t stereo_offset = 8u;
  const uint32_t note_offset = 304u;
  const size_t file_bytes = index_bytes + note_offset + not_audio.size() + 9u;
  SyntheticHfa archive{index_bytes, std::vector<uint8_t>(file_bytes, 0xccu)};
  std::memcpy(archive.bytes.data(), hunex::kHunexHfaMagic,
              sizeof(hunex::kHunexHfaMagic) - 1u);
  WriteLe32(archive.bytes.data() + 12u, count);

  // Records are deliberately offset-unsorted and separated by gaps.
  WriteHfaEntry(&archive.bytes, 0u,
                "\xe9\x9f\xb3\xe5\xa3\xb0_a.HW", mono_offset,
                static_cast<uint32_t>(mono.size()));
  WriteHfaEntry(&archive.bytes, 1u, "voice_b.hw", stereo_offset,
                static_cast<uint32_t>(stereo.size()));
  WriteHfaEntry(&archive.bytes, 2u, "metadata.bin", note_offset,
                static_cast<uint32_t>(not_audio.size()));
  std::memcpy(archive.bytes.data() + index_bytes + mono_offset, mono.data(),
              mono.size());
  std::memcpy(archive.bytes.data() + index_bytes + stereo_offset,
              stereo.data(), stereo.size());
  std::memcpy(archive.bytes.data() + index_bytes + note_offset,
              not_audio.data(), not_audio.size());
  return archive;
}

void TestHfaIndexAndReadClassification() {
  const SyntheticHfa archive = MakeHfa();
  hunex::HunexHfaArchiveInfo info;
  assert(hunex::ParseHunexHfaIndex(archive.bytes.data(), archive.index_bytes,
                                  archive.bytes.size(), &info));
  assert(info.count == 3u);
  assert(info.data_base == archive.index_bytes);

  hunex::HunexHfaEntry mono;
  assert(hunex::ReadHunexHfaEntryAtIndex(
      archive.bytes.data(), archive.index_bytes, archive.bytes.size(), 0u,
      &mono));
  assert(std::strcmp(mono.name,
                     "\xe9\x9f\xb3\xe5\xa3\xb0_a.HW") == 0);
  assert(mono.absolute_offset == archive.index_bytes + 168u);

  hunex::HunexHfaEntry matched;
  const uint8_t* member = archive.bytes.data() + mono.absolute_offset;
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset, 4u, member, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kMemberStart);
  assert(matched.id == mono.id);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset + hunex::kHunexHwHeaderBytes, 4u,
             member + hunex::kHunexHwHeaderBytes, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kOggPayloadStart);

  // Interior, preload, cross-member, overflow, false prefix and non-HW starts
  // must never be promoted to a voice resource.
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset + 1u, 4u, member, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset + 63u, 4u, member + 63u, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset + 65u, 4u, member + 65u, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset - 1u, 4u, member, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset, 0u, member, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             0u, 4u, archive.bytes.data(), 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset, mono.size + 1u, member, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset + hunex::kHunexHwHeaderBytes,
             mono.size - hunex::kHunexHwHeaderBytes + 1u,
             member + hunex::kHunexHwHeaderBytes, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             std::numeric_limits<uint64_t>::max() - 1u, 4u, member, 4u,
             &matched) == hunex::HunexVoiceReadKind::kNone);
  const uint8_t wrong_prefix[4] = {64u, 0u, 0u, 1u};
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             mono.absolute_offset, 4u, wrong_prefix, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
  hunex::HunexHfaEntry metadata;
  assert(hunex::ReadHunexHfaEntryAtIndex(
      archive.bytes.data(), archive.index_bytes, archive.bytes.size(), 2u,
      &metadata));
  assert(hunex::ClassifyHunexVoiceRead(
             archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
             metadata.absolute_offset, 4u,
             archive.bytes.data() + metadata.absolute_offset, 4u, &matched) ==
         hunex::HunexVoiceReadKind::kNone);
}

void TestHfaIndexRejectsMalformedInput() {
  const SyntheticHfa archive = MakeHfa();
  hunex::HunexHfaArchiveInfo info;

  std::vector<uint8_t> malformed = archive.bytes;
  malformed[0u] = 'X';
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));

  malformed = archive.bytes;
  WriteLe32(malformed.data() + 12u, 0u);
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));
  assert(!hunex::ParseHunexHfaIndex(archive.bytes.data(),
                                    archive.index_bytes - 1u,
                                    archive.bytes.size(), &info));
  assert(!hunex::ParseHunexHfaIndex(archive.bytes.data(), archive.index_bytes,
                                    archive.bytes.size(), nullptr));
  hunex::HunexHfaEntry entry;
  assert(!hunex::ReadHunexHfaEntryAtIndex(
      archive.bytes.data(), archive.index_bytes, archive.bytes.size(), 3u,
      &entry));

  malformed = archive.bytes;
  std::memset(malformed.data() + hunex::kHunexHfaHeaderBytes, 'x',
              hunex::kHunexHfaNameBytes);
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));

  malformed = archive.bytes;
  uint8_t* first_name = malformed.data() + hunex::kHunexHfaHeaderBytes;
  first_name[0u] = 0xc0u;
  first_name[1u] = 0x80u;
  first_name[2u] = 0u;
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));

  malformed = archive.bytes;
  uint8_t* first_record = malformed.data() + hunex::kHunexHfaHeaderBytes;
  WriteLe32(first_record + hunex::kHunexHfaNameBytes + 4u, 0u);
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));

  malformed = archive.bytes;
  first_record = malformed.data() + hunex::kHunexHfaHeaderBytes;
  WriteLe32(first_record + hunex::kHunexHfaNameBytes + 4u,
            hunex::kMaxHunexHwBytes + 1u);
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));

  malformed = archive.bytes;
  uint8_t* second_offset = malformed.data() + hunex::kHunexHfaHeaderBytes +
                           hunex::kHunexHfaRecordBytes +
                           hunex::kHunexHfaNameBytes;
  WriteLe32(second_offset, 160u);
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));

  malformed = archive.bytes;
  first_record = malformed.data() + hunex::kHunexHfaHeaderBytes;
  WriteLe32(first_record + hunex::kHunexHfaNameBytes,
            static_cast<uint32_t>(archive.bytes.size()));
  assert(!hunex::ParseHunexHfaIndex(malformed.data(), archive.index_bytes,
                                    malformed.size(), &info));
}

void TestHwWrapperAndOggContract() {
  const std::vector<uint8_t> mono = MakeHw(48000u, 48000u, 1u);
  const std::vector<uint8_t> stereo = MakeHw(96000u, 48000u, 2u);
  hunex::HunexHwOggInfo parsed;
  assert(hunex::ParseHunexHwOgg(mono.data(), mono.size(), &parsed));
  assert(parsed.payload_offset == 64u);
  assert(parsed.sample_count == 48000u);
  assert(parsed.sample_rate == 48000u);
  assert(parsed.channels == 1u);
  assert(parsed.final_granule == parsed.sample_count);
  const std::vector<uint8_t> expected_ogg = MakeOgg(48000u);
  assert(parsed.payload_bytes == expected_ogg.size());
  assert(std::memcmp(mono.data() + parsed.payload_offset,
                     expected_ogg.data(), expected_ogg.size()) == 0);
  assert(hunex::ParseHunexHwOgg(stereo.data(), stereo.size(), &parsed));
  assert(parsed.channels == 2u);

  std::vector<uint8_t> malformed = mono;
  WriteLe32(malformed.data(), 63u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  WriteLe32(malformed.data(), 65u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed[4u] = 'H';
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed[hunex::kHunexHwHeaderBytes] = 'X';
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed[hunex::kHunexHwHeaderBytes + 4u] = 1u;
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  WriteLe32(malformed.data() + 8u,
            static_cast<uint32_t>(malformed.size() - 63u));
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  WriteLe32(malformed.data() + 12u, 0u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  WriteLe32(malformed.data() + 16u, 0u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  WriteLe32(malformed.data() + 20u, 0u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed[hunex::kHunexHwHeaderBytes + 5u] = 0x02u;
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed[hunex::kHunexHwHeaderBytes + 5u] = 0x04u;
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed[hunex::kHunexHwHeaderBytes + 26u] = 0xffu;
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed[hunex::kHunexHwHeaderBytes + 27u] = 0xffu;
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = mono;
  malformed.push_back(0u);
  WriteLe32(malformed.data() + 8u,
            static_cast<uint32_t>(malformed.size() - 64u));
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  assert(!hunex::ParseHunexHwOgg(mono.data(), mono.size() - 1u, &parsed));

  const uint32_t sample_count = 12345u;
  std::vector<uint8_t> two_pages =
      MakeHw(sample_count, 44100u, 1u, MakeTwoPageOgg(sample_count));
  assert(hunex::ParseHunexHwOgg(two_pages.data(), two_pages.size(), &parsed));
  const size_t second_page =
      hunex::kHunexHwHeaderBytes +
      MakeOggPage(0x02u, std::numeric_limits<uint64_t>::max(), 7u, 0u,
                  {1u, 2u, 3u})
          .size();
  malformed = two_pages;
  WriteLe32(malformed.data() + second_page + 14u, 8u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = two_pages;
  WriteLe32(malformed.data() + second_page + 18u, 2u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
  malformed = two_pages;
  WriteLe32(malformed.data() + 12u, sample_count + 1u);
  assert(!hunex::ParseHunexHwOgg(malformed.data(), malformed.size(), &parsed));
}

}  // namespace

int main() {
  TestHfaIndexAndReadClassification();
  TestHfaIndexRejectsMalformedInput();
  TestHwWrapperAndOggContract();
  return 0;
}
