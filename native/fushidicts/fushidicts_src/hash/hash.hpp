#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "bloom.hpp"

namespace hash {

// hash.table 的每个非空槽位：visit(hash, offset) 返回 false = 提前停止。
// hash.table : [u32 capacity][ slot{u64 hash, u64 offset} x capacity ]，hash 0 = 空槽；
// capacity 按文件实际能容纳的槽数截断（BUG-1303，与 linear::load 同一口径）。
// 整本扫描（词性探测 / 内容探测）与联合过滤器构建共用这一份遍历。
template <typename Visit>
void for_each_slot(const uint8_t* data, size_t size, Visit&& visit) {
  if (!data || size < sizeof(uint32_t)) {
    return;
  }
  uint32_t capacity = 0;
  std::memcpy(&capacity, data, sizeof(uint32_t));
  const size_t slot_size = sizeof(uint64_t) * 2;
  const size_t max_slots = (size - sizeof(uint32_t)) / slot_size;
  if (capacity > max_slots) {
    capacity = static_cast<uint32_t>(max_slots);
  }
  const uint8_t* slots = data + sizeof(uint32_t);
  for (uint32_t i = 0; i < capacity; i++) {
    const uint8_t* slot = slots + static_cast<size_t>(i) * slot_size;
    uint64_t slot_hash = 0;
    std::memcpy(&slot_hash, slot, sizeof(uint64_t));
    if (slot_hash == 0) {
      continue;
    }
    uint64_t offset = 0;
    std::memcpy(&offset, slot + sizeof(uint64_t), sizeof(uint64_t));
    if (!visit(slot_hash, offset)) {
      return;
    }
  }
}

// hash.table 按文件大小截断后的槽数（联合过滤器据此估键数，见 union_filter.cpp）。
uint32_t slot_capacity(const uint8_t* data, size_t size);

class linear {
 public:
  linear();
  ~linear();
  // 键的 XXH3 → bloom → 线性探测。0 = 未命中。
  uint64_t operator()(std::string_view key) const;
  // 已有键哈希时的两段：调用方（query.cpp）一次查库只算一次 XXH3，再逐词典复用。
  // [bloom_rejects] 为真即肯定不在；[find] 不查 bloom，只做线性探测（联合过滤器已经
  // 判过「可能在」时直接走这里）。
  bool bloom_rejects(uint64_t h) const { return !bloom_ || !bloom_->contains(h); }
  uint64_t find(uint64_t h) const;
  // 把 [find] 起手要读的槽位预取进缓存（纯提示）。
  void prefetch(uint64_t h) const;

  void build_to_file(const std::vector<std::pair<uint64_t, uint64_t>>& hash_entries, const std::string& path);

  // BUG-1303: [size] is the mapped size of hash.table in bytes. The stored
  // capacity is a bare uint32 read straight out of the file; a truncated or
  // corrupt table would otherwise make the probe walk off the end of the
  // mapping. Callers must pass the real mapping size -- probe_dict_content()
  // in query.cpp already clamped the same way, this makes the query path
  // (the one that runs on every lookup) do it too.
  void load(uint8_t* ptr, size_t size);
  void set_bloom(const bloom* b) { bloom_ = b; }

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
