#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "../hook/elf_ai6_arc.h"

namespace ai6 = hibiki_voice_hook::elf_ai6;

void WriteLe32(uint8_t* out, uint32_t value) {
  out[0] = static_cast<uint8_t>(value);
  out[1] = static_cast<uint8_t>(value >> 8);
  out[2] = static_cast<uint8_t>(value >> 16);
  out[3] = static_cast<uint8_t>(value >> 24);
}

void WriteBe32(uint8_t* out, uint32_t value) {
  out[0] = static_cast<uint8_t>(value >> 24);
  out[1] = static_cast<uint8_t>(value >> 16);
  out[2] = static_cast<uint8_t>(value >> 8);
  out[3] = static_cast<uint8_t>(value);
}

void WriteEntry(std::vector<uint8_t>* index, uint32_t number,
                const char* name, uint32_t size, uint32_t offset) {
  uint8_t* record = index->data() + ai6::kHeaderBytes +
      static_cast<size_t>(number) * ai6::kEntryBytes;
  std::memcpy(record, name, std::strlen(name));
  WriteBe32(record + ai6::kNameBytes + 4, size);
  WriteBe32(record + ai6::kNameBytes + 8, size);
  WriteBe32(record + ai6::kNameBytes + 12, offset);
}

int main() {
  constexpr uint32_t count = 2;
  const uint32_t index_bytes = static_cast<uint32_t>(
      ai6::kHeaderBytes + count * ai6::kEntryBytes);
  std::vector<uint8_t> index(index_bytes, 0);
  WriteLe32(index.data(), count);
  WriteEntry(&index, 0, "voice_a", 32, index_bytes);
  WriteEntry(&index, 1, "voice_b", 48, index_bytes + 32);
  const uint64_t file_size = index_bytes + 80;

  ai6::ArcEntry entry;
  assert(ai6::FindEntryForRead(index.data(), index.size(), file_size,
                               index_bytes, &entry));
  assert(std::strcmp(entry.name, "voice_a") == 0);
  assert(entry.offset == index_bytes);
  assert(entry.size == 32);
  assert(ai6::FindEntryForRead(index.data(), index.size(), file_size,
                               index_bytes + 40, &entry));
  assert(std::strcmp(entry.name, "voice_b") == 0);
  assert(!ai6::FindEntryForRead(index.data(), index.size(), file_size,
                                index_bytes - 1, &entry));
  assert(!ai6::FindEntryForRead(index.data(), index.size(), file_size,
                                file_size, &entry));

  std::vector<uint8_t> malformed = index;
  WriteBe32(malformed.data() + ai6::kHeaderBytes + ai6::kNameBytes + 8, 31);
  assert(!ai6::FindEntryForRead(malformed.data(), malformed.size(), file_size,
                                index_bytes, &entry));
  malformed = index;
  WriteBe32(malformed.data() + ai6::kHeaderBytes + ai6::kNameBytes + 12,
            static_cast<uint32_t>(file_size - 8));
  assert(!ai6::FindEntryForRead(malformed.data(), malformed.size(), file_size,
                                file_size - 8, &entry));
  uint8_t bad_count[4] = {0xff, 0xff, 0xff, 0xff};
  assert(!ai6::IndexSize(bad_count, sizeof(bad_count), nullptr, nullptr));
  return 0;
}
