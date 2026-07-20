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

}  // namespace

int main() {
  bool ok = true;

  std::vector<uint8_t> archive(4 + 2 * 16, 0);
  PutLe32(archive, 0, 2);
  PutLe32(archive, 4, 1234);
  PutLe32(archive, 8, 36);
  PutLe32(archive, 12, 80);
  PutLe32(archive, 16, 9001);
  PutLe32(archive, 20, 4321);
  PutLe32(archive, 24, 1270);
  PutLe32(archive, 28, 120);
  PutLe32(archive, 32, 9002);

  hibiki_voice_hook::siglus::OvkEntry entry;
  ok &= Expect(hibiki_voice_hook::siglus::FindEntryAtOffset(
                   archive.data(), archive.size(), 6000, 36, &entry),
               "valid OVK entry should be found");
  ok &= Expect(entry.byte_len == 1234 && entry.id == 9001,
               "OVK fields should decode as little endian");
  ok &= Expect(!hibiki_voice_hook::siglus::FindEntryAtOffset(
                   archive.data(), archive.size(), 6000, 37, &entry),
               "non-entry offset must be rejected");
  ok &= Expect(!hibiki_voice_hook::siglus::FindEntryAtOffset(
                   archive.data(), archive.size(), 1000, 1270, &entry),
               "entry extending beyond file must be rejected");

  const std::vector<uint8_t> first = OggPage(0x02, 77, {1, 2, 3});
  const std::vector<uint8_t> last = OggPage(0x04, 77, {4, 5});
  std::vector<uint8_t> ogg = first;
  ogg.insert(ogg.end(), last.begin(), last.end());
  ok &= Expect(hibiki_voice_hook::siglus::CompleteOggBytes(
                   ogg.data(), static_cast<uint32_t>(ogg.size())) == ogg.size(),
               "complete two-page Ogg should end at EOS page");
  ok &= Expect(hibiki_voice_hook::siglus::CompleteOggBytes(
                   ogg.data(), static_cast<uint32_t>(first.size())) == 0,
               "Ogg without EOS must be rejected");
  ogg[14] ^= 1;
  ok &= Expect(hibiki_voice_hook::siglus::CompleteOggBytes(
                   ogg.data(), static_cast<uint32_t>(ogg.size())) == 0,
               "mixed logical stream serials must be rejected");

  if (ok) {
    std::puts("siglus_ovk_test: PASS");
    return 0;
  }
  return 1;
}
