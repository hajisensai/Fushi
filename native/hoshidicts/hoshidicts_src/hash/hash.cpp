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
  // BUG-1303: a table with no free slot (corrupt/truncated capacity, or a
  // bloom false positive on a full table) used to spin here forever with the
  // FFI call still on the stack -- the UI isolate calls lookup() synchronously,
  // so that is a hard app hang, not a slow lookup. Bound the probe by the
  // capacity: linear probing can never legitimately need more steps than that.
  if (!ptr_->table || ptr_->capacity == 0 || !bloom_) {
    return 0;
  }
  uint64_t h = XXH3_64bits(key.data(), key.size());
  if (!bloom_->contains(h)) {
    return 0;
  }
  uint64_t pos = h % ptr_->capacity;
  for (uint32_t probes = 0; probes < ptr_->capacity; probes++) {
    if (ptr_->table[pos].hash == 0) {
      return 0;
    }
    if (ptr_->table[pos].hash == h) {
      return ptr_->table[pos].offset;
    }
    pos = (pos + 1) % ptr_->capacity;
  }
  return 0;
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

void linear::load(uint8_t* ptr, size_t size) {
  // BUG-1303: the capacity is a bare uint32 read straight out of the mapped
  // file. Trusting it unconditionally means a truncated / partially written /
  // corrupt hash.table makes every probe walk past the end of the mapping
  // (EXCEPTION_IN_PAGE_ERROR on Windows, SIGSEGV elsewhere) -- and a capacity
  // of 0 turns the `h % capacity` below into an integer division by zero.
  // probe_dict_content() in query.cpp already clamped against the real file
  // size; the query path -- the one that runs on *every* lookup -- did not.
  if (!ptr || size < sizeof(uint32_t)) {
    ptr_->capacity = 0;
    ptr_->table = nullptr;
    return;
  }
  uint32_t stored = 0;
  std::memcpy(&stored, ptr, sizeof(uint32_t));
  const size_t max_slots = (size - sizeof(uint32_t)) / sizeof(slot);
  if (stored > max_slots) {
    stored = static_cast<uint32_t>(max_slots);
  }
  ptr_->capacity = stored;
  ptr_->table = stored == 0 ? nullptr : reinterpret_cast<slot*>(ptr + sizeof(uint32_t));
}
}
