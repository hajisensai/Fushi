#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "bloom.hpp"

namespace hash {
class linear {
 public:
  linear();
  ~linear();
  uint64_t operator()(std::string_view key) const;

  void build_to_file(const std::vector<std::pair<uint64_t, uint64_t>>& hash_entries, const std::string& path);

  // BUG-1285: [size] is the mapped size of hash.table in bytes. The stored
  // capacity is a bare uint32 read straight out of the file; a truncated or
  // corrupt table would otherwise make the probe walk off the end of the
  // mapping. Callers must pass the real mapping size -- probe_dict_content()
  // in query.cpp already clamped the same way, this makes the query path
  // (the one that runs on every lookup) do it too.
  void load(uint8_t* ptr, size_t size);
  void set_bloom(const bloom* b) { bloom_ = b; }
  std::vector<uint64_t> populated() const;

 private:
  struct slot {
    uint64_t hash;
    uint64_t offset;
  };

  struct table {
    uint32_t capacity = 0;
    slot* table;
  };
  std::unique_ptr<table> ptr_;
  const bloom* bloom_ = nullptr;
};
}
