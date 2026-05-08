#include "hash.hpp"

#include <xxh3.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>

#include "../memory/memory.hpp"

namespace hash {
linear::linear() : ptr_(std::make_unique<table>()) {};
linear::~linear() = default;

uint64_t linear::operator()(std::string_view key) const {
  uint64_t h = XXH3_64bits(key.data(), key.size());
  if (!bloom_->contains(h)) {
    return 0;
  }
  uint64_t pos = h % ptr_->capacity;
  while (true) {
    if (ptr_->table[pos].hash == 0) {
      return 0;
    }
    if (ptr_->table[pos].hash == h) {
      return ptr_->table[pos].offset;
    }
    pos = (pos + 1) % ptr_->capacity;
  }
}

void linear::build_to_file(const std::vector<std::pair<uint64_t, uint64_t>>& hash_entries, const std::string& path) {
  ptr_->capacity = std::max<uint64_t>(hash_entries.size() * 10 / 7, 16);
  size_t file_size = sizeof(uint32_t) + ptr_->capacity * sizeof(slot);

  auto out = memory::map_rw(path, file_size);
  if (!out) {
    throw std::runtime_error("failed to create hash table");
  }
 
  std::memcpy(out.data, &ptr_->capacity, sizeof(uint32_t));
  ptr_->table = reinterpret_cast<slot*>(out.data + sizeof(uint32_t));
  std::memset(ptr_->table, 0, ptr_->capacity * sizeof(slot));
  for (const auto& he : hash_entries) {
    uint64_t h = he.first;
    uint64_t pos = h % ptr_->capacity;
    while (true) {
      if (ptr_->table[pos].hash == 0) {
        ptr_->table[pos] = {.hash = h, .offset = he.second};
        break;
      }
      pos = (pos + 1) % ptr_->capacity;
    }
  }
  memory::unmap(out);
  ptr_->table = nullptr;
  ptr_->capacity = 0;
}

std::vector<uint64_t> linear::populated() const {
  std::vector<uint64_t> result;
  if (!ptr_->table) {
    return result;
  }
  result.reserve(static_cast<size_t>(ptr_->capacity) * 7 / 10);
  for (uint32_t i = 0; i < ptr_->capacity; i++) {
    if (ptr_->table[i].hash != 0) {
      result.push_back(ptr_->table[i].hash);
    }
  }
  return result;
}

void linear::load(uint8_t* ptr) {
  ptr_->capacity = *reinterpret_cast<uint32_t*>(ptr);
  ptr_->table = reinterpret_cast<slot*>(ptr + sizeof(uint32_t));
}
}
