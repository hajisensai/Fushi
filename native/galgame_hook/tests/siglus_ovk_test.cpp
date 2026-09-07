// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "siglus_ovk.h"

namespace {

void PutLe32(std::vector<uint8_t>& bytes, size_t at, uint32_t value) {
  std::memcpy(bytes.data() + at, &value, sizeof(value));
}

std::vector<uint8_t> OggPage(uint8_t flags, uint32_t serial,
                             const std::vector<uint8_t>& payload) {
  std::vector<uint8_t> page(28 + payload.size(), 0);
  std::memcpy(page.data(), "OggS", 4);
  page[4] = 0;
  page[5] = flags;
  PutLe32(page, 14, serial);
  page[26] = 1;
  page[27] = static_cast<uint8_t>(payload.size());
  std::memcpy(page.data() + 28, payload.data(), payload.size());
  return page;
}

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
  }
  return condition;
}

bool TestUniqueVoiceMemberIndex() {
  using namespace fushi_voice_hook::siglus;
  bool ok = true;
  std::vector<uint8_t> index(36, 0);
  PutLe32(index, 0, 2);
  PutLe32(index, 4, 100);
  PutLe32(index, 8, 36);
  PutLe32(index, 12, 0);
  PutLe32(index, 16, 48000);
  PutLe32(index, 20, 100);
  PutLe32(index, 24, 136);
  PutLe32(index, 28, 99999);
  PutLe32(index, 32, 48000);
  std::vector<uint8_t> scratch(kVoiceMemberIndexScratchBytes, 0xff);
  const auto validate = [&](const std::vector<uint8_t>& bytes,
                            uint64_t file_bytes = 236) {
    return ValidateUniqueVoiceMemberIndex(bytes.data(), bytes.size(), file_bytes,
                                         scratch.data(), scratch.size());
  };
  ok &= Expect(validate(index), "unique zero/max member and equal sample counts are legal");
  ok &= Expect(validate(index), "scratch is reset for independent validations");
  for (int same_offset = 0; same_offset < 2; ++same_offset) {
    auto duplicate = index;
    PutLe32(duplicate, 28, 0);
    if (same_offset != 0) PutLe32(duplicate, 24, 36);
    ok &= Expect(!validate(duplicate), "duplicate member is rejected even at identical offset");
  }
  // Check every row, including an invalid row unrelated to offset lookup.
  for (size_t row : {size_t{4}, size_t{20}}) {
    for (int malformed = 0; malformed < 6; ++malformed) {
      auto invalid = index;
      if (malformed == 0) PutLe32(invalid, row, 0);
      if (malformed == 1) PutLe32(invalid, row, kMaxEntryBytes + 1);
      if (malformed == 2) PutLe32(invalid, row + 4, 35);
      if (malformed == 3) PutLe32(invalid, row + 4, 200);
      if (malformed == 4) PutLe32(invalid, row + 8, 100000);
      if (malformed == 5) PutLe32(invalid, row + 4, UINT32_MAX);
      ok &= Expect(!validate(invalid), "all entries must satisfy strict member and byte bounds");
    }
  }
  auto invalid_other_row = index;
  PutLe32(invalid_other_row, 12, 100000);
  OvkEntry legacy;
  ok &= Expect(FindEntryAtOffset(invalid_other_row.data(), invalid_other_row.size(),
                                236, 136, &legacy),
               "legacy exact-offset interface keeps its original local validation");
  ok &= Expect(!validate(index, 35), "file must contain complete table");
  auto truncated = index;
  truncated.pop_back();
  ok &= Expect(!validate(truncated), "partial table must not be read");
  for (uint32_t count : {0u, kVoiceMemberIndexDomain + 1u,
                         kMaxEntryCount + 1u, UINT32_MAX}) {
    std::vector<uint8_t> header(4, 0);
    PutLe32(header, 0, count);
    ok &= Expect(!validate(header, UINT64_MAX), "malicious count rejected before row reads");
  }
  ok &= Expect(!ValidateUniqueVoiceMemberIndex(nullptr, 36, 236, scratch.data(),
                                              scratch.size()), "null index rejected");
  ok &= Expect(!ValidateUniqueVoiceMemberIndex(index.data(), 3, 236, scratch.data(),
                                              scratch.size()), "short count rejected");
  ok &= Expect(!ValidateUniqueVoiceMemberIndex(index.data(), index.size(), 236,
                                              nullptr, scratch.size()), "null scratch rejected");
  ok &= Expect(!ValidateUniqueVoiceMemberIndex(index.data(), index.size(), 236,
                                              scratch.data(), scratch.size() - 1),
               "undersized scratch rejected");
  std::vector<uint8_t> shared(kVoiceMemberIndexScratchBytes + index.size(), 0);
  std::memcpy(shared.data(), index.data(), index.size());
  ok &= Expect(!ValidateUniqueVoiceMemberIndex(shared.data(), index.size(), 236,
                                              shared.data(), kVoiceMemberIndexScratchBytes),
               "scratch may not alias input");
  ok &= Expect(validate(index), "failed validations cannot poison next valid index");
  std::vector<uint8_t> maximum(4 + kVoiceMemberIndexDomain * kOvkEntryBytes, 0);
  PutLe32(maximum, 0, kVoiceMemberIndexDomain);
  for (uint32_t member = 0; member < kVoiceMemberIndexDomain; ++member) {
    const size_t row = 4 + static_cast<size_t>(member) * kOvkEntryBytes;
    PutLe32(maximum, row, 1);
    PutLe32(maximum, row + 4, static_cast<uint32_t>(maximum.size()) + member);
    PutLe32(maximum, row + 8, member);
  }
  ok &= Expect(validate(maximum, maximum.size() + kVoiceMemberIndexDomain),
               "entire bounded member domain fits scratch without stack allocation");
  return ok;
}

}  // namespace

int main() {
  bool ok = TestUniqueVoiceMemberIndex();

  std::vector<uint8_t> archive(4 + 2 * 16, 0);
  PutLe32(archive, 0, 2);
  PutLe32(archive, 4, 1234);
  PutLe32(archive, 8, 36);
  PutLe32(archive, 12, 9001);
  PutLe32(archive, 16, 48000);
  PutLe32(archive, 20, 4321);
  PutLe32(archive, 24, 1270);
  PutLe32(archive, 28, 9002);
  PutLe32(archive, 32, 48000);

  fushi_voice_hook::siglus::OvkEntry entry;
  ok &= Expect(fushi_voice_hook::siglus::FindEntryAtOffset(
                   archive.data(), archive.size(), 6000, 36, &entry),
               "valid OVK entry should be found");
  ok &= Expect(entry.byte_len == 1234 && entry.offset == 36 &&
                   entry.member_id == 9001 && entry.sample_count == 48000,
                "OVK fields must preserve member ID separately from sample count");
  const std::wstring first_name =
      fushi_voice_hook::siglus::BuildOvkVoiceStorageName(L"z0001.ovk", entry);
  fushi_voice_hook::siglus::OvkEntry second;
  ok &= Expect(fushi_voice_hook::siglus::FindEntryAtOffset(
                   archive.data(), archive.size(), 6000, 1270, &second),
                "second equal-duration member should be found");
  const std::wstring second_name =
      fushi_voice_hook::siglus::BuildOvkVoiceStorageName(L"z0001.ovk", second);
  ok &= Expect(second.member_id == 9002 &&
                   second.sample_count == entry.sample_count &&
                   first_name == L"z0001.ovk_9001.ogg" &&
                   second_name == L"z0001.ovk_9002.ogg" &&
                   first_name != second_name,
                "different members with equal sample counts must not share an export name");
  ok &= Expect(!fushi_voice_hook::siglus::FindEntryAtOffset(
                   archive.data(), archive.size(), 6000, 37, &entry),
               "non-entry offset must be rejected");
  ok &= Expect(!fushi_voice_hook::siglus::FindEntryAtOffset(
                   archive.data(), archive.size(), 1000, 1270, &entry),
               "entry extending beyond file must be rejected");

  const std::vector<uint8_t> first = OggPage(0x02, 77, {1, 2, 3});
  const std::vector<uint8_t> last = OggPage(0x04, 77, {4, 5});
  std::vector<uint8_t> ogg = first;
  ogg.insert(ogg.end(), last.begin(), last.end());
  ok &= Expect(fushi_voice_hook::siglus::CompleteOggBytes(
                   ogg.data(), static_cast<uint32_t>(ogg.size())) == ogg.size(),
               "complete two-page Ogg should end at EOS page");
  ok &= Expect(fushi_voice_hook::siglus::CompleteOggBytes(
                   ogg.data(), static_cast<uint32_t>(first.size())) == 0,
               "Ogg without EOS must be rejected");
  ogg[14] ^= 1;
  ok &= Expect(fushi_voice_hook::siglus::CompleteOggBytes(
                   ogg.data(), static_cast<uint32_t>(ogg.size())) == 0,
               "mixed logical stream serials must be rejected");

  if (ok) {
    std::puts("siglus_ovk_test: PASS");
    return 0;
  }
  return 1;
}
