// CI builds Release with NDEBUG. Keep every assertion in this regression test
// live; tests/assert_liveness_guard_test.py enforces this ordering.
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "leaf_aquaplus_voice_archive.h"

namespace {

using fushi_voice_hook::leaf_aquaplus::kLacEntryBytes;
using fushi_voice_hook::leaf_aquaplus::kLacHeaderBytes;
using fushi_voice_hook::leaf_aquaplus::kLacStoredNameBytes;

void PutLe32(std::vector<uint8_t> *bytes, size_t at, uint32_t value) {
  assert(bytes != nullptr && at + sizeof(value) <= bytes->size());
  std::memcpy(bytes->data() + at, &value, sizeof(value));
}

std::vector<uint8_t> OggPage(uint8_t flags, uint32_t serial, uint32_t sequence,
                             const std::vector<uint8_t> &payload) {
  assert(payload.size() <= 255u);
  std::vector<uint8_t> page(28u + payload.size(), 0u);
  std::memcpy(page.data(), "OggS", 4u);
  page[4] = 0u;
  page[5] = flags;
  PutLe32(&page, 14u, serial);
  PutLe32(&page, 18u, sequence);
  page[26] = 1u;
  page[27] = static_cast<uint8_t>(payload.size());
  std::memcpy(page.data() + 28u, payload.data(), payload.size());
  return page;
}

std::vector<uint8_t> SyntheticOgg(uint32_t serial,
                                  const std::vector<uint8_t> &first_payload,
                                  const std::vector<uint8_t> &last_payload,
                                  size_t *first_page_bytes = nullptr) {
  std::vector<uint8_t> first = OggPage(0x02u, serial, 0u, first_payload);
  std::vector<uint8_t> last = OggPage(0x04u, serial, 1u, last_payload);
  if (first_page_bytes != nullptr)
    *first_page_bytes = first.size();
  first.insert(first.end(), last.begin(), last.end());
  return first;
}

void WriteStoredName(std::vector<uint8_t> *bytes, size_t at, const char *name) {
  assert(bytes != nullptr && name != nullptr);
  const size_t chars = std::strlen(name);
  assert(chars > 0u && chars <= kLacStoredNameBytes);
  assert(at + kLacStoredNameBytes <= bytes->size());
  std::memset(bytes->data() + at, 0, kLacStoredNameBytes);
  for (size_t i = 0; i < chars; ++i) {
    (*bytes)[at + i] = static_cast<uint8_t>(~static_cast<uint8_t>(name[i]));
  }
}

void WriteEntry(std::vector<uint8_t> *bytes, uint32_t id, const char *name,
                uint32_t byte_len, uint32_t offset) {
  const size_t at = static_cast<size_t>(kLacHeaderBytes) +
                    static_cast<size_t>(id) * kLacEntryBytes;
  WriteStoredName(bytes, at, name);
  PutLe32(bytes, at + kLacStoredNameBytes, byte_len);
  PutLe32(bytes, at + kLacStoredNameBytes + sizeof(uint32_t), offset);
}

struct SyntheticArchive {
  std::vector<uint8_t> bytes;
  std::vector<uint8_t> first_ogg;
  std::vector<uint8_t> second_ogg;
  size_t index_bytes = 0u;
  size_t first_page_bytes = 0u;
  uint32_t first_offset = 0u;
  uint32_t second_offset = 0u;
};

SyntheticArchive MakeSyntheticArchive() {
  SyntheticArchive archive;
  archive.first_ogg = SyntheticOgg(0x11223344u, {1u, 2u, 3u}, {4u, 5u},
                                   &archive.first_page_bytes);
  archive.second_ogg = SyntheticOgg(0x55667788u, {9u, 8u}, {7u, 6u, 5u});
  archive.index_bytes = kLacHeaderBytes + 2u * kLacEntryBytes;
  archive.first_offset = static_cast<uint32_t>(archive.index_bytes);
  // A legal gap proves that validation rejects overlap rather than requiring
  // a made-up contiguous-members invariant.
  archive.second_offset = archive.first_offset +
                          static_cast<uint32_t>(archive.first_ogg.size()) + 7u;
  archive.bytes.resize(archive.second_offset + archive.second_ogg.size(), 0u);
  std::memcpy(archive.bytes.data(), "LAC\0", 4u);
  PutLe32(&archive.bytes, 4u, 2u);
  WriteEntry(&archive.bytes, 0u, "unit_voice_a.OGG",
             static_cast<uint32_t>(archive.first_ogg.size()),
             archive.first_offset);
  WriteEntry(&archive.bytes, 1u, "unit_voice_b.ogg",
             static_cast<uint32_t>(archive.second_ogg.size()),
             archive.second_offset);
  std::memcpy(archive.bytes.data() + archive.first_offset,
              archive.first_ogg.data(), archive.first_ogg.size());
  std::memcpy(archive.bytes.data() + archive.second_offset,
              archive.second_ogg.data(), archive.second_ogg.size());
  return archive;
}

} // namespace

int main() {
  namespace leaf = fushi_voice_hook::leaf_aquaplus;
  static_assert(leaf::kLacEntryBytes == 0x28u);
  const SyntheticArchive archive = MakeSyntheticArchive();
  assert(archive.bytes[kLacHeaderBytes] ==
         static_cast<uint8_t>(~static_cast<uint8_t>('u')));
  assert(archive.bytes[kLacHeaderBytes + std::strlen("unit_voice_a.OGG")] ==
         0u);

  leaf::LacArchiveInfo info;
  assert(leaf::ParseVoiceArchiveIndex(archive.bytes.data(), archive.index_bytes,
                                      archive.bytes.size(), &info));
  assert(info.count == 2u);
  assert(info.index_bytes == archive.index_bytes);

  // O(1) row access is the runtime cursor API after the one full-table parse.
  leaf::LacEntry first;
  leaf::LacEntry second;
  assert(leaf::ReadVoiceEntryAtIndex(archive.bytes.data(), archive.index_bytes,
                                     archive.bytes.size(), 0u, &first));
  assert(leaf::ReadVoiceEntryAtIndex(archive.bytes.data(), archive.index_bytes,
                                     archive.bytes.size(), 1u, &second));
  assert(!leaf::ReadVoiceEntryAtIndex(archive.bytes.data(), archive.index_bytes,
                                      archive.bytes.size(), 2u, &second));
  assert(first.id == 0u && first.offset == archive.first_offset &&
         first.byte_len == archive.first_ogg.size());
  assert(second.id == 1u && second.offset == archive.second_offset &&
         second.byte_len == archive.second_ogg.size());
  assert(std::strcmp(first.storage_name, "unit_voice_a.OGG") == 0);
  assert(std::strcmp(second.storage_name, "unit_voice_b.ogg") == 0);

  leaf::LacEntry found;
  assert(leaf::FindVoiceEntryAtOffset(archive.bytes.data(), archive.index_bytes,
                                      archive.bytes.size(),
                                      archive.first_offset, &found));
  assert(found.id == 0u);
  assert(leaf::FindVoiceEntryAtOffset(archive.bytes.data(), archive.index_bytes,
                                      archive.bytes.size(),
                                      archive.second_offset, &found));
  assert(found.id == 1u);
  assert(!leaf::FindVoiceEntryAtOffset(
      archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
      archive.first_offset + 1u, &found));
  assert(!leaf::FindVoiceEntryAtOffset(
      archive.bytes.data(), archive.index_bytes, archive.bytes.size(),
      archive.second_offset - 1u, &found));
  assert(!leaf::FindVoiceEntryAtOffset(archive.bytes.data(),
                                       archive.index_bytes,
                                       archive.bytes.size(), 0u, &found));

  assert(leaf::CompleteOggBytes(archive.bytes.data() + first.offset,
                                first.byte_len) == first.byte_len);
  assert(leaf::CompleteOggBytes(archive.bytes.data() + second.offset,
                                second.byte_len) == second.byte_len);
  // The publication input is an exact archive slice: no PCM reinterpretation,
  // header rewrite or transcoding is involved.
  std::vector<uint8_t> published(first.byte_len);
  std::memcpy(published.data(), archive.bytes.data() + first.offset,
              first.byte_len);
  assert(published == archive.first_ogg);

  std::vector<uint8_t> missing_eos(archive.first_ogg.begin(),
                                   archive.first_ogg.begin() +
                                       archive.first_page_bytes);
  assert(leaf::CompleteOggBytes(missing_eos.data(),
                                static_cast<uint32_t>(missing_eos.size())) ==
         0u);
  std::vector<uint8_t> mixed_serial = archive.first_ogg;
  PutLe32(&mixed_serial, archive.first_page_bytes + 14u, 0x11223345u);
  assert(leaf::CompleteOggBytes(mixed_serial.data(),
                                static_cast<uint32_t>(mixed_serial.size())) ==
         0u);
  std::vector<uint8_t> truncated = archive.first_ogg;
  truncated.pop_back();
  assert(leaf::CompleteOggBytes(truncated.data(),
                                static_cast<uint32_t>(truncated.size())) == 0u);
  std::vector<uint8_t> bad_capture = archive.first_ogg;
  bad_capture[0] = 'X';
  assert(leaf::CompleteOggBytes(bad_capture.data(),
                                static_cast<uint32_t>(bad_capture.size())) ==
         0u);
  std::vector<uint8_t> trailing = archive.first_ogg;
  trailing.push_back(0x7fu);
  assert(leaf::CompleteOggBytes(trailing.data(),
                                static_cast<uint32_t>(trailing.size())) ==
         archive.first_ogg.size());
  assert(leaf::CompleteOggBytes(trailing.data(),
                                static_cast<uint32_t>(trailing.size())) !=
         trailing.size());

  std::vector<uint8_t> invalid = archive.bytes;
  invalid[0] = 'X';
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));

  invalid = archive.bytes;
  PutLe32(&invalid, 4u, 0u);
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));
  invalid = archive.bytes;
  PutLe32(&invalid, 4u, leaf::kMaxEntryCount + 1u);
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));
  assert(!leaf::ParseVoiceArchiveIndex(archive.bytes.data(),
                                       archive.index_bytes - 1u,
                                       archive.bytes.size(), &info));
  assert(!leaf::ParseVoiceArchiveIndex(archive.bytes.data(),
                                       archive.index_bytes + 1u,
                                       archive.bytes.size(), &info));

  invalid = archive.bytes;
  WriteStoredName(&invalid, kLacHeaderBytes, "unit_voice_a.wav");
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));
  invalid = archive.bytes;
  std::memset(invalid.data() + kLacHeaderBytes, 0, kLacStoredNameBytes);
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));

  invalid = archive.bytes;
  PutLe32(&invalid, kLacHeaderBytes + kLacStoredNameBytes, 0u);
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));
  invalid = archive.bytes;
  PutLe32(&invalid, kLacHeaderBytes + kLacStoredNameBytes,
          leaf::kMaxEntryBytes + 1u);
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));
  invalid = archive.bytes;
  PutLe32(&invalid, kLacHeaderBytes + kLacStoredNameBytes + sizeof(uint32_t),
          archive.first_offset + 1u);
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));

  invalid = archive.bytes;
  const size_t second_row = kLacHeaderBytes + kLacEntryBytes;
  PutLe32(&invalid, second_row + kLacStoredNameBytes + sizeof(uint32_t),
          archive.first_offset + first.byte_len - 1u);
  assert(!leaf::ParseVoiceArchiveIndex(invalid.data(), archive.index_bytes,
                                       invalid.size(), &info));

  // These three members occupy disjoint ranges, but the directory order is
  // 128, 200, 160. This reaches the ordering guard independently of overlap.
  const size_t unordered_index_bytes = kLacHeaderBytes + 3u * kLacEntryBytes;
  std::vector<uint8_t> unordered(216u, 0u);
  std::memcpy(unordered.data(), "LAC\0", 4u);
  PutLe32(&unordered, 4u, 3u);
  WriteEntry(&unordered, 0u, "order_a.ogg", 16u,
             static_cast<uint32_t>(unordered_index_bytes));
  WriteEntry(&unordered, 1u, "order_b.ogg", 16u, 200u);
  WriteEntry(&unordered, 2u, "order_c.ogg", 20u, 160u);
  assert(!leaf::ParseVoiceArchiveIndex(unordered.data(), unordered_index_bytes,
                                       unordered.size(), &info));

  assert(!leaf::ParseVoiceArchiveIndex(archive.bytes.data(),
                                       archive.index_bytes,
                                       archive.bytes.size() - 1u, &info));
  assert(!leaf::ParseVoiceArchiveIndex(archive.bytes.data(),
                                       archive.index_bytes,
                                       archive.bytes.size() + 1u, &info));
  return 0;
}
