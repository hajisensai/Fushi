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
  void load(uint8_t* ptr);
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
